#!/usr/bin/env python3
"""Exhaustive differential check over every blocked domain in the lists.

The bulk runs an A query for every block-list domain that is not covered by an
allow entry. A preflight query for a name in no list must stay unresolved; if it
answers with NXDOMAIN or NOERROR, the A assertion would prove nothing. A
positive control then requires one listed domain to answer NXDOMAIN, which a
dead forwarder cannot produce, so the pass never starts before the lists are
loaded. Every A answer must be NXDOMAIN (the lab config blocks as NXDOMAIN), and
the run records an error otherwise. All responses (minus the random DNS ID) are
folded into an order-independent digest; the original and the candidate must
produce the same digest for every domain.

A second pass asks TXT for the same domains. The TXT report names the matched
list URL, so that pass proves the parser kept the same decision and the same
source list. A third pass asks TXT for the block-list domains that an allow
entry covers: the app must not answer them with its report, and their responses
must match between builds. It covers the full union; the measured cost is in
`lab/README.md`.

The lab config has one blocking group and no static or regex lists, so this
models the allow files, `@@` rules and adblock options it does use.

    python3 lab/exhaustive.py <variant> [tag] [workers]

Run it inside a python container sharing the lab container's network namespace
(see .github/workflows/lab.yml). LIMIT=N restricts the A and TXT passes to
the first N domains; the allow pass always runs its full covered set.
"""
from __future__ import annotations

import glob
import hashlib
import ipaddress
import json
import multiprocessing as mp
import os
import re
import secrets
import socket
import struct
import sys
import time
from functools import partial

HOST = os.environ.get("DNS_HOST", "127.0.0.1")
PORT = int(os.environ.get("DNS_PORT", "53"))
WORKERS = int(os.environ.get("WORKERS", "0")) or min(8, os.cpu_count() or 1)
LIMIT = int(os.environ.get("LIMIT", "0"))
CONFIG = os.environ.get("APP_CONFIG") or "lab/config/dnsApp.config"
TIMEOUT_S = 0.5
ATTEMPTS = 5
MAX_CONSECUTIVE = 25
MAX_RETRY_CONSECUTIVE = 5
PREFLIGHT_ATTEMPTS = 3
PREFLIGHT_TIMEOUT_S = 2.0
CONTROL_DEADLINE_S = 30.0
UNBLOCKED_RECORDED = 20
MAX_RETRY_DOMAINS = 1000

SKIP_HOSTNAMES = {
    "",
    "localhost",
    "localhost.localdomain",
    "local",
    "broadcasthost",
    "ip6-localhost",
    "ip6-loopback",
    "ip6-localnet",
    "ip6-mcastprefix",
    "ip6-allnodes",
    "ip6-allrouters",
    "ip6-allhosts",
}


def is_valid_domain(domain: str) -> bool:
    """Mirror DnsClient.IsDomainNameValid for the characters lists can carry."""
    if not domain or len(domain) > 255:
        return False
    for label in domain.split("."):
        if not label or len(label) > 63:
            return False
        if label == "*":
            continue
        for char in label:
            if char in "-_/" or ("0" <= char <= "9") or ("a" <= char <= "z") or ("A" <= char <= "Z"):
                continue
            return False
    return True


def is_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return False
    return True


def list_sources() -> dict[str, str]:
    """File names (sha256 of the URL) mapped to how the app parses each list."""
    with open(CONFIG, encoding="utf-8") as f:
        config = json.load(f)
    kinds: dict[str, str] = {}
    for group in config.get("groups", []):
        for key, kind in (
            ("adblockListUrls", "adblock"),
            ("allowListUrls", "allow"),
            ("blockListUrls", "block"),
        ):
            for url in group.get(key, []):
                if isinstance(url, dict):
                    url = url.get("url")
                if url:
                    kinds[hashlib.sha256(url.encode()).hexdigest()] = kind
    return kinds


def parse_adblock(path: str) -> tuple[set[str], set[str]]:
    """Domains from an AdBlock list, following ReadAdblockListFile."""
    allowed: set[str] = set()
    blocked: set[str] = set()
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n").lstrip(" \t")
            if not line or line.startswith("!"):
                continue
            is_allow = line.startswith("@@||")
            if not is_allow and not line.startswith("||"):
                continue
            start = 4 if is_allow else 2
            caret = line.find("^", start)
            if caret > -1:
                domain = line[start:caret]
                options = line[caret + 1:]
                # The app accepts an empty remainder, or one that starts with
                # '$' and contains "doc" or "all" (substring match, so
                # "$document" counts too).
                if options and not (options.startswith("$") and ("doc" in options or "all" in options)):
                    continue
            else:
                domain = line[start:]
            # The adblock parser stores the name as written; the lookup
            # lowercases the query, so an upper-case entry can never match.
            if domain != domain.lower() or not is_valid_domain(domain):
                continue
            (allowed if is_allow else blocked).add(domain)
    return allowed, blocked


def split_words(line: str) -> list[str]:
    """Split on space and tab only, like the app's PopWord."""
    return [word for word in line.strip(" \t").replace("\t", " ").split(" ") if word]


def parse_wildcard(path: str) -> set[str]:
    """Domains from a hosts/wildcard list, following ReadListFile."""
    domains: set[str] = set()
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n").lstrip(" \t*.")
            if not line or line.startswith("#"):
                continue
            words = split_words(line)
            if not words:
                continue
            if len(words) == 1:
                hostname = words[0]
            else:
                first, second = words[0], words[1]
                if second.startswith("#"):
                    hostname = first
                elif is_ip(first):
                    hostname = second
                else:
                    continue
            hostname = hostname.strip(".").lower()
            if hostname in SKIP_HOSTNAMES or not is_valid_domain(hostname) or is_ip(hostname):
                continue
            domains.add(hostname)
    return domains


def is_allowed(domain: str, allow: set[str]) -> bool:
    """True when the domain or one of its parents is allowed (matches the app)."""
    probe = domain
    while True:
        if probe in allow:
            return True
        _, separator, parent = probe.partition(".")
        if not separator:
            return False
        probe = parent


def extract_block_domains() -> tuple[dict[str, set[str]], list[str]]:
    """Block domains per list file, plus the block domains an allow entry covers."""
    kinds = list_sources()
    allow: set[str] = set()
    per_list: dict[str, set[str]] = {}
    for path in sorted(glob.glob("lab/lists/*")):
        kind = kinds.get(os.path.basename(path))
        if kind is None:
            print(f"skipping {path}: not listed in {CONFIG}", file=sys.stderr)
            continue
        if kind == "allow":
            allow |= parse_wildcard(path)
        elif kind == "adblock":
            allowed, blocked = parse_adblock(path)
            allow |= allowed
            per_list[path] = blocked
        else:
            per_list[path] = parse_wildcard(path)
    covered = sorted(
        {
            domain
            for domains in per_list.values()
            for domain in domains
            if is_allowed(domain, allow)
        }
    )
    for path, domains in per_list.items():
        per_list[path] = {domain for domain in domains if not is_allowed(domain, allow)}
    return per_list, covered


def build_query(domain: str, qid: int, qtype: int) -> bytes:
    packet = bytearray(struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0))
    for label in domain.split("."):
        packet.append(len(label))
        packet.extend(label.encode("ascii"))
    packet.append(0)
    packet.extend(struct.pack("!HH", qtype, 1))  # qtype, IN
    return bytes(packet)


def receive(sock: socket.socket, qid: int, timeout: float = TIMEOUT_S) -> bytes | None:
    """Wait for this query's answer, discarding late answers to older queries."""
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            candidate, _ = sock.recvfrom(4096)
        except OSError:
            return None
        if (
            len(candidate) >= 12
            and struct.unpack("!H", candidate[:2])[0] == qid
            and candidate[2] & 0x80
        ):
            return candidate
        # Anything else is a late answer to an earlier query.


def ask(domain: str, qtype: int, timeout: float) -> int | None:
    """Send one query and return its rcode, or None when no answer arrived."""
    qid = secrets.randbelow(0x10000)
    packet = build_query(domain, qid, qtype)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.sendto(packet, (HOST, PORT))
        except OSError:
            return None
        response = receive(sock, qid, timeout)
    if response is None:
        return None
    return response[3] & 0x0F


def query_shard(
    shard: list[str], qtype: int
) -> tuple[int, int, int, int, list[str], list[tuple[str, int]], dict[int, int]]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    count = 0
    blocked = 0
    errors = 0
    digest = 0
    consecutive = 0
    failures: list[str] = []
    unblocked: list[tuple[str, int]] = []
    rcodes: dict[int, int] = {}
    for index, domain in enumerate(shard):
        qid = (index * 2654435761 + 1) & 0xFFFF
        packet = build_query(domain, qid, qtype)
        response = None
        for attempt in range(ATTEMPTS):
            if attempt:
                # A dropped datagram means the server queue was full; give it
                # a moment before the resend instead of bursting again.
                time.sleep(0.01 * attempt)
            try:
                sock.sendto(packet, (HOST, PORT))
            except OSError:
                continue
            response = receive(sock, qid)
            if response is not None:
                break
        if response is None:
            errors += 1
            failures.append(domain)
            consecutive += 1
            if consecutive >= MAX_CONSECUTIVE:
                raise RuntimeError(f"{MAX_CONSECUTIVE} consecutive query failures")
            continue
        consecutive = 0
        count += 1
        rcode = response[3] & 0x0F
        rcodes[rcode] = rcodes.get(rcode, 0) + 1
        if qtype == 16:
            if b"source=advanced-blocking-app" in response:
                blocked += 1
            elif len(unblocked) < UNBLOCKED_RECORDED:
                unblocked.append((domain, rcode))
        else:
            # The lab config blocks as NXDOMAIN; any other answer is not a
            # blocking answer, so it stays unblocked and the gate catches it.
            if rcode == 3:
                blocked += 1
            elif len(unblocked) < UNBLOCKED_RECORDED:
                unblocked.append((domain, rcode))
        digest = (
            digest
            + int.from_bytes(hashlib.blake2b(response[2:], digest_size=8).digest(), "little")
        ) & 0xFFFFFFFFFFFFFFFF
    sock.close()
    return count, blocked, errors, digest, failures, unblocked, rcodes


def shards(items: list[str], workers: int) -> list[list[str]]:
    return [items[i::workers] for i in range(workers)]


def run_pass(
    items: list[str], qtype: int, workers: int, label: str
) -> tuple[int, int, int, int, float, list[str], list[tuple[str, int]], dict[int, int]]:
    started = time.perf_counter()
    totals = [0, 0, 0, 0]
    failures: list[str] = []
    unblocked: list[tuple[str, int]] = []
    rcodes: dict[int, int] = {}
    with mp.Pool(workers) as pool:
        for done, result in enumerate(
            pool.imap_unordered(partial(query_shard, qtype=qtype), shards(items, workers)), 1
        ):
            for index in range(4):
                totals[index] += result[index]
            failures.extend(result[4])
            unblocked.extend(result[5])
            for rcode, count in result[6].items():
                rcodes[rcode] = rcodes.get(rcode, 0) + count
            print(
                f"{label}: {done}/{workers} shards, {totals[0]} answered, {totals[2]} errors",
                file=sys.stderr,
                flush=True,
            )
    totals[3] &= 0xFFFFFFFFFFFFFFFF
    return (
        totals[0],
        totals[1],
        totals[2],
        totals[3],
        time.perf_counter() - started,
        failures,
        unblocked,
        rcodes,
    )


def retry_once(
    domains: list[str], qtype: int
) -> tuple[int, int, int, int, list[str], list[tuple[str, int]], dict[int, int]]:
    """Retry failed domains sequentially with a long timeout.

    A full GC in the server can pause it for seconds; the in-shard retries use
    short timeouts so they fit the pass, and this pass catches that pause.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    count = 0
    blocked = 0
    digest = 0
    consecutive = 0
    failed: list[str] = []
    unblocked: list[tuple[str, int]] = []
    rcodes: dict[int, int] = {}
    for index, domain in enumerate(domains):
        qid = (index * 40503 + 7) & 0xFFFF
        packet = build_query(domain, qid, qtype)
        response = None
        for attempt in range(3):
            if attempt:
                time.sleep(0.5 * attempt)
            try:
                sock.sendto(packet, (HOST, PORT))
            except OSError:
                continue
            response = receive(sock, qid, timeout=5.0)
            if response is not None:
                break
        if response is None:
            failed.append(domain)
            consecutive += 1
            if consecutive >= MAX_RETRY_CONSECUTIVE:
                raise RuntimeError(f"{MAX_RETRY_CONSECUTIVE} consecutive retry failures")
            continue
        consecutive = 0
        count += 1
        rcode = response[3] & 0x0F
        rcodes[rcode] = rcodes.get(rcode, 0) + 1
        if qtype == 16:
            if b"source=advanced-blocking-app" in response:
                blocked += 1
            elif len(unblocked) < UNBLOCKED_RECORDED:
                unblocked.append((domain, rcode))
        else:
            if rcode == 3:
                blocked += 1
            elif len(unblocked) < UNBLOCKED_RECORDED:
                unblocked.append((domain, rcode))
        digest = (
            digest
            + int.from_bytes(hashlib.blake2b(response[2:], digest_size=8).digest(), "little")
        ) & 0xFFFFFFFFFFFFFFFF
    sock.close()
    return count, blocked, len(failed), digest, failed, unblocked, rcodes


def preflight() -> str | None:
    """Return an error string when a name in no list gets a real answer.

    The A assertion only means something while the forwarder is dead. A random
    name under .com is in no list; SERVFAIL or a timeout means the server did
    not resolve it, while NXDOMAIN or NOERROR means an upstream answered. A
    timeout is retried because a lost datagram proves nothing; when every
    attempt times out the check is inconclusive and the pass continues.
    """
    domain = f"preflight-{secrets.token_hex(4)}.com"
    for attempt in range(PREFLIGHT_ATTEMPTS):
        if attempt:
            time.sleep(0.2 * attempt)
        rcode = ask(domain, 1, PREFLIGHT_TIMEOUT_S)
        if rcode is None:
            continue
        if rcode in (0, 3):
            return f"{domain} answered rcode {rcode}; the A pass needs a dead forwarder"
        return None
    print(f"preflight inconclusive: no answer for {domain}", file=sys.stderr)
    return None


def positive_control(control: list[tuple[str, str]]) -> str | None:
    """Return an error string unless one listed domain per list answers NXDOMAIN.

    With the forwarder dead an unlisted name ends in SERVFAIL, so NXDOMAIN can
    only come from the app's block list. One domain per list is checked, so a
    list that is still loading fails the gate instead of producing false
    unblocked answers. run-lab.sh holds the run until every list line is logged,
    and GRACE_S covers the rest; this is the second guard.
    """
    deadline = time.monotonic() + CONTROL_DEADLINE_S
    pending = list(control)
    last: dict[str, int | None] = {}
    while pending:
        for label, domain in list(pending):
            rcode = ask(domain, 1, TIMEOUT_S)
            last[label] = rcode
            if rcode == 3:
                pending.remove((label, domain))
        if not pending:
            return None
        if time.monotonic() >= deadline:
            label, domain = pending[0]
            return (
                f"{label} ({domain}) did not answer NXDOMAIN within "
                f"{CONTROL_DEADLINE_S:.0f}s (last rcode {last.get(label)}); "
                "the server is not blocking"
            )
        time.sleep(0.5)
    return None


def parse_list_counts(path: str) -> list[list[object]]:
    pattern = re.compile(r"Advanced Blocking app read .*? list file \((\d+) domains\) from: (.+)$")
    counts: list[list[object]] = []
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            for line in f:
                match = pattern.search(line.rstrip("\n"))
                if match:
                    counts.append([int(match.group(1)), match.group(2)])
    except FileNotFoundError:
        pass
    counts.sort(key=lambda entry: entry[1])
    return counts


def companion(path: str) -> dict[str, object]:
    """The run-lab.sh artifact of the same run, when it was written."""
    try:
        with open(path, encoding="utf-8") as f:
            run = json.load(f)
    except (OSError, ValueError):
        return {}
    return {
        key: run[key]
        for key in ("app_sha256", "image", "memory_limit", "memory_swap")
        if key in run
    }


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: exhaustive.py <variant> [tag] [workers]", file=sys.stderr)
        return 2
    variant = sys.argv[1]
    tag = sys.argv[2] if len(sys.argv) > 2 else ""
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else WORKERS
    workers = min(max(workers, 1), 8)

    out_path = f"results/{variant}{tag}.exhaustive.json"
    try:
        os.remove(out_path)
    except FileNotFoundError:
        pass

    try:
        loopback = ipaddress.IPv4Address(HOST).is_loopback
    except ValueError:
        loopback = False
    if not loopback:
        print(
            f"DNS_HOST={HOST} is not loopback; exhaustive.py drives the lab "
            "container only (use prod-load.py for a live host)",
            file=sys.stderr,
        )
        return 2

    per_list, allow_covered = extract_block_domains()
    domains = sorted(set().union(*per_list.values())) if per_list else []
    if LIMIT > 0:
        domains = domains[:LIMIT]
    if not domains:
        print("no block-list domains extracted from lab/lists", file=sys.stderr)
        return 1

    error = preflight()
    if error:
        print(f"preflight failed: {error}", file=sys.stderr)
        return 1
    control = []
    seen_control: set[str] = set()
    for path, listed in per_list.items():
        if not listed:
            continue
        domain = min(listed)
        if domain in seen_control:
            continue
        seen_control.add(domain)
        control.append((os.path.basename(path), domain))
    # per_list holds one Python string per parsed domain; control and domains
    # are all that the passes need.
    del per_list
    error = positive_control(control)
    if error:
        print(f"positive control failed: {error}", file=sys.stderr)
        return 1

    try:
        (
            answers,
            blocked,
            errors,
            digest,
            elapsed,
            failures,
            unblocked,
            _a_rcodes,
        ) = run_pass(domains, 1, workers, "A")
        retried = 0
        retried_domains: list[str] = []
        if failures:
            if len(failures) > MAX_RETRY_DOMAINS:
                print(
                    f"{len(failures)} A failures, more than the {MAX_RETRY_DOMAINS} retry limit",
                    file=sys.stderr,
                )
                return 1
            retried = len(failures)
            retried_domains = sorted(failures)[:UNBLOCKED_RECORDED]
            (
                extra_answers,
                extra_blocked,
                errors,
                extra_digest,
                failures,
                extra_unblocked,
                _extra_rcodes,
            ) = retry_once(failures, 1)
            answers += extra_answers
            blocked += extra_blocked
            digest = (digest + extra_digest) & 0xFFFFFFFFFFFFFFFF
            unblocked.extend(extra_unblocked)

        (
            txt_answers,
            txt_blocked,
            txt_errors,
            txt_digest,
            txt_elapsed,
            txt_failures,
            txt_unblocked,
            _txt_rcodes,
        ) = run_pass(domains, 16, workers, "TXT")
        txt_retried = 0
        txt_retried_domains: list[str] = []
        if txt_failures:
            if len(txt_failures) > MAX_RETRY_DOMAINS:
                print(
                    f"{len(txt_failures)} TXT failures, more than the {MAX_RETRY_DOMAINS} retry limit",
                    file=sys.stderr,
                )
                return 1
            txt_retried = len(txt_failures)
            txt_retried_domains = sorted(txt_failures)[:UNBLOCKED_RECORDED]
            (
                extra_answers,
                extra_blocked,
                txt_errors,
                extra_digest,
                txt_failures,
                extra_unblocked,
                _extra_rcodes,
            ) = retry_once(txt_failures, 16)
            txt_answers += extra_answers
            txt_blocked += extra_blocked
            txt_digest = (txt_digest + extra_digest) & 0xFFFFFFFFFFFFFFFF
            txt_unblocked.extend(extra_unblocked)

        allow_answers = allow_reported = allow_errors = 0
        allow_digest = 0
        allow_elapsed = 0.0
        allow_retried = 0
        allow_rcodes: dict[int, int] = {}
        if allow_covered:
            (
                allow_answers,
                allow_reported,
                allow_errors,
                allow_digest,
                allow_elapsed,
                allow_failures,
                _allow_unblocked,
                allow_rcodes,
            ) = run_pass(allow_covered, 16, workers, "ALLOW")
            if allow_failures:
                if len(allow_failures) > MAX_RETRY_DOMAINS:
                    print(
                        f"{len(allow_failures)} allow failures, more than the {MAX_RETRY_DOMAINS} retry limit",
                        file=sys.stderr,
                    )
                    return 1
                allow_retried = len(allow_failures)
                (
                    extra_answers,
                    extra_reported,
                    allow_errors,
                    extra_digest,
                    _allow_failures,
                    _allow_unblocked,
                    extra_allow_rcodes,
                ) = retry_once(allow_failures, 16)
                allow_answers += extra_answers
                allow_reported += extra_reported
                allow_digest = (allow_digest + extra_digest) & 0xFFFFFFFFFFFFFFFF
                for rcode, count in extra_allow_rcodes.items():
                    allow_rcodes[rcode] = allow_rcodes.get(rcode, 0) + count
    except RuntimeError as exc:
        print(f"exhaustive pass aborted: {exc}", file=sys.stderr)
        return 1

    data = {
        "variant": variant,
        "run_tag": tag,
        "limit": LIMIT,
        "domains": len(domains),
        "answers": answers,
        "blocked": blocked,
        "unblocked": answers - blocked,
        "unblocked_answers": [
            [domain, rcode] for domain, rcode in sorted(unblocked)[:UNBLOCKED_RECORDED]
        ],
        "errors": errors,
        "retried": retried,
        "retried_domains": retried_domains,
        "failures": sorted(failures)[:20],
        "digest": f"{digest:016x}",
        "txt_mode": "full",
        "txt_answers": txt_answers,
        "txt_blocked": txt_blocked,
        "txt_unblocked": txt_answers - txt_blocked,
        "txt_unblocked_answers": [
            [domain, rcode] for domain, rcode in sorted(txt_unblocked)[:UNBLOCKED_RECORDED]
        ],
        "txt_errors": txt_errors,
        "txt_retried": txt_retried,
        "txt_retried_domains": txt_retried_domains,
        "txt_failures": sorted(txt_failures)[:20],
        "txt_digest": f"{txt_digest:016x}",
        "workers": workers,
        "elapsed_s": round(elapsed, 3),
        "txt_elapsed_s": round(txt_elapsed, 3),
        "allow_covered": len(allow_covered),
        "allow_answers": allow_answers,
        "allow_reported": allow_reported,
        "allow_errors": allow_errors,
        "allow_retried": allow_retried,
        "allow_digest": f"{allow_digest:016x}",
        "allow_rcodes": {
            str(rcode): count for rcode, count in sorted(allow_rcodes.items())
        },
        "allow_elapsed_s": round(allow_elapsed, 3),
        "list_counts": parse_list_counts(f"results/{variant}{tag}.applog"),
    }
    data.update(companion(f"results/{variant}{tag}.json"))
    with open(out_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(json.dumps(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
