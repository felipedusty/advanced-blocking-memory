#!/usr/bin/env python3
"""Near-miss differential: names next to real list entries must be decided alike.

exhaustive.py asks about names that ARE in the lists, so it cannot see a set
that answers "yes" for something it should not. This script derives names that
are not list entries from a deterministic sample of real ones, one family per
kind in KINDS: a character added in front, a character added to the first
label, the first character dropped, the last character dropped or added (names
that are a prefix of an entry, or that have an entry as a prefix), the parent
of a listed name, a changed top level domain, two swapped letters, and an
upper-case copy. It asks the app for each name and records how the name was
decided. The original and the candidate must record the same thing for every
name, which compare-ci.py checks through an order-independent digest of the
full responses and the per-kind counts.

The lab server forwards to lab/null-upstream.py. That upstream answers NXDOMAIN
with RA set and no authority record, while the blocking app answers NXDOMAIN
with RA clear and a SOA authority record; that difference is how a decision is
read. One control query each way runs before the pass, so a missing or dead
upstream stops the run instead of producing a meaningless record.

    python3 lab/near-miss.py <variant> [tag] [workers]

Run it inside a python container sharing the lab container's network namespace
(see .github/workflows/lab.yml). NEAR_MISS_SEEDS sets how many listed names are
sampled (default 30000, about nine near-miss names each).
"""
from __future__ import annotations

import hashlib
import json
import multiprocessing as mp
import os
import random
import secrets
import socket
import struct
import sys
import time

import exhaustive as ex

HOST = os.environ.get("DNS_HOST", "127.0.0.1")
PORT = int(os.environ.get("DNS_PORT", "53"))
SEEDS = int(os.environ.get("NEAR_MISS_SEEDS", "30000"))
SEED_VALUE = 20261101
CHUNK = 4000
TIMEOUTS = (0.5, 1.0, 2.0, 4.0)
RETRY_WAIT_S = int(os.environ.get("NEAR_MISS_RETRY_WAIT", "15"))
KINDS = (
    "prefix",
    "label-suffix",
    "drop-first",
    "truncate",
    "append",
    "parent",
    "tld-change",
    "swap",
    "upper",
)
RA = 0x0080


def derive_names() -> tuple[dict[str, str], set[str]]:
    """Near-miss names (mapped to their kind) and the effective block domains."""
    per_list, _covered = ex.extract_block_domains()
    union: set[str] = set()
    for domains in per_list.values():
        union |= domains
    seeds = random.Random(SEED_VALUE).sample(sorted(union), min(SEEDS, len(union)))
    names: dict[str, str] = {}

    def add(kind: str, name: str) -> None:
        if name and name not in names and ex.is_valid_domain(name):
            names[name] = kind

    for domain in seeds:
        labels = domain.split(".")
        if len(labels) < 2:
            continue
        first = labels[0]
        add("prefix", "x" + domain)
        add("label-suffix", ".".join([first + "x"] + labels[1:]))
        if len(first) > 1:
            add("drop-first", domain[1:])
        add("truncate", domain[:-1])
        add("append", domain + "x")
        if len(labels) >= 3:
            add("parent", ".".join(labels[1:]))
        add("tld-change", domain[:-1] + ("z" if domain[-1] != "z" else "y"))
        if len(first) >= 3 and first[0] != first[1]:
            add("swap", ".".join([first[1] + first[0] + first[2:]] + labels[1:]))
        add("upper", domain.upper())
    for name in list(names):
        if name in union:
            del names[name]
    return names, union


def decision(response: bytes) -> str:
    """blocked, forwarded or other, read from the response header."""
    flags, _qd, _an, ns, _ar = struct.unpack("!HHHHH", response[2:12])
    if flags & 0x0F != 3:
        return "other"
    if ns >= 1 and not flags & RA:
        return "blocked"
    if ns == 0 and flags & RA:
        return "forwarded"
    return "other"


def ask(sock: socket.socket, name: str) -> bytes | None:
    for timeout in TIMEOUTS:
        qid = secrets.randbelow(0x10000)
        sock.sendto(ex.build_query(name, qid, 1), (HOST, PORT))
        response = ex.receive(sock, qid, timeout)
        if response is not None and len(response) >= 12:
            return response
    return None


def query_chunk(chunk: list[str]) -> list[tuple[str, str, int, str]]:
    """Per name: outcome, signature and, for an undecided answer, the flags of that first answer."""
    out = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for name in chunk:
            response = ask(sock, name)
            if response is None:
                out.append((name, "error", 0, ""))
                continue
            outcome = decision(response)
            first = f"{struct.unpack('!H', response[2:4])[0]:04x}" if outcome == "other" else ""
            sig = hashlib.sha256(name.encode() + response[2:]).digest()[:8]
            out.append((name, outcome, int.from_bytes(sig, "big"), first))
    return out


def controls(union: set[str]) -> str | None:
    """An error string unless a listed name is blocked and an unlisted one forwarded."""
    listed = min(union)
    unlisted = f"near-miss-control-{secrets.token_hex(4)}.example.org"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for name, want in ((listed, "blocked"), (unlisted, "forwarded")):
            response = ask(sock, name)
            got = "no answer" if response is None else decision(response)
            if got != want:
                return f"control {name}: expected {want}, got {got}"
    return None


def suffixes(name: str) -> list[str]:
    parts = name.split(".")
    return [".".join(parts[i:]) for i in range(len(parts))]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: near-miss.py <variant> [tag] [workers]", file=sys.stderr)
        return 2
    variant = sys.argv[1]
    tag = sys.argv[2] if len(sys.argv) > 2 else ""
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else min(8, os.cpu_count() or 1)

    names, union = derive_names()
    if not names:
        print("no near-miss names derived from lab/lists", file=sys.stderr)
        return 1
    error = controls(union)
    if error:
        print(error, file=sys.stderr)
        return 1

    items = sorted(names)
    chunks = [items[i : i + CHUNK] for i in range(0, len(items), CHUNK)]
    started = time.perf_counter()
    decided: dict[str, str] = {}
    retried: dict[str, str] = {}
    pending: dict[str, int] = {}
    digest = 0
    with mp.Pool(workers) as pool:
        for done, part in enumerate(pool.imap_unordered(query_chunk, chunks), 1):
            for name, outcome, sig, first in part:
                decided[name] = outcome
                digest = (digest + sig) & 0xFFFFFFFFFFFFFFFF
                if first:
                    retried[name] = first
                    pending[name] = sig
            if done % max(1, len(chunks) // 10) == 0:
                print(
                    f"near-miss: {len(decided)}/{len(items)} names",
                    file=sys.stderr,
                    flush=True,
                )

    # A SERVFAIL (a forwarded query lost) is cached by the server, so asking again at once
    # returns the cached failure. Ask the undecided names again after the failure cache expires.
    if pending:
        print(f"near-miss: {len(pending)} undecided names, asking again in {RETRY_WAIT_S} s", file=sys.stderr, flush=True)
        time.sleep(RETRY_WAIT_S)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            for name, old_sig in pending.items():
                response = ask(sock, name)
                if response is None:
                    decided[name] = "error"
                    digest = (digest - old_sig) & 0xFFFFFFFFFFFFFFFF
                    continue

                sig = int.from_bytes(hashlib.sha256(name.encode() + response[2:]).digest()[:8], "big")
                decided[name] = decision(response)
                digest = (digest - old_sig + sig) & 0xFFFFFFFFFFFFFFFF

    elapsed = time.perf_counter() - started

    per_kind = {
        kind: {"names": 0, "blocked": 0, "forwarded": 0, "other": 0, "error": 0}
        for kind in KINDS
    }
    mismatches = 0
    for name, outcome in decided.items():
        per_kind[names[name]]["names"] += 1
        per_kind[names[name]][outcome] += 1
        if names[name] != "upper":
            expected = "blocked" if any(s in union for s in suffixes(name)) else "forwarded"
            mismatches += outcome != expected
    totals = {
        key: sum(row[key] for row in per_kind.values())
        for key in ("blocked", "forwarded", "other", "error")
    }

    data = {
        "variant": variant,
        "run_tag": tag,
        "seeds": SEEDS,
        "names": len(items),
        "answers": len(items) - totals["error"],
        "errors": totals["error"],
        "blocked": totals["blocked"],
        "forwarded": totals["forwarded"],
        "other": totals["other"],
        "retried": len(retried),
        "retried_first_flags": dict(sorted(retried.items())[:20]),
        "model_mismatches": mismatches,
        "digest": f"{digest:016x}",
        "per_kind": per_kind,
        "workers": workers,
        "elapsed_s": round(elapsed, 3),
    }
    os.makedirs("results", exist_ok=True)
    with open(f"results/{variant}{tag}.near-miss.json", "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(json.dumps({key: data[key] for key in data if key != "per_kind"}))
    return 0 if totals["error"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
