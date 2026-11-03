#!/usr/bin/env python3
"""Measure DNS query latency against the running lab container.

Uses A queries for domains that the app blocks, so the answer comes from the
blocking app and does not wait on upstream recursion; the lab blocks as
NXDOMAIN, so any other rcode fails the query. Run it once per variant and
compare. Any failed query exits nonzero and leaves
`results/<variant><tag>.latency.json` untouched, so a broken run cannot replace
a good measurement.

    python3 lab/latency.py <variant> [queries_per_domain] [tag]

Set `LATENCY_OUT` to write the JSON somewhere other than
`results/<variant><tag>.latency.json` (used by `lab/latency-rounds.sh`).
"""
import hashlib
import json
import os
import random
import socket
import statistics
import struct
import sys
import time
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("DNS_PORT", "15353"))
TIMEOUT = 1.0


def build_query(domain: str, qid: int) -> bytes:
    header = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    qname = bytearray()
    for label in domain.split("."):
        qname.append(len(label))
        qname.extend(label.encode("ascii", "ignore"))
    qname.append(0)
    return header + bytes(qname) + struct.pack("!HH", 1, 1)


def main() -> int:
    variant = sys.argv[1] if len(sys.argv) > 1 else "original"
    repeat = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    tag = sys.argv[3] if len(sys.argv) > 3 else ""
    out = os.environ.get("LATENCY_OUT") or f"results/{variant}{tag}.latency.json"

    domains = []
    with open(f"results/{variant}{tag}.reports.txt") as f:
        for line in f:
            domain, _, report = line.rstrip("\n").partition("\t")
            if "source=advanced-blocking-app" in report:
                domains.append(domain)
    if not domains:
        print("no blocked domains in the reports file", file=sys.stderr)
        return 1

    app = Path(__file__).resolve().parent / ".work" / f"out-{variant}" / "AdvancedBlockingApp.dll"
    if not app.exists():
        print(f"app assembly not found: {app}", file=sys.stderr)
        return 2
    app_sha = hashlib.sha256(app.read_bytes()).hexdigest()
    companion = Path(f"results/{variant}{tag}.json")
    if not companion.exists():
        print(f"missing {companion}; run lab/run-lab.sh {variant} first", file=sys.stderr)
        return 2
    try:
        run_sha = json.loads(companion.read_text())["app_sha256"]
    except (OSError, ValueError, KeyError):
        run_sha = None
    if run_sha != app_sha:
        print(
            f"the run in {companion} used {run_sha}, not the local build {app_sha}",
            file=sys.stderr,
        )
        return 2

    random.seed(1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)

    samples = []
    errors = 0
    fail_streak = 0

    def failed() -> None:
        nonlocal errors, fail_streak
        errors += 1
        fail_streak += 1
        if fail_streak >= 20:
            raise SystemExit("server stopped answering (20 consecutive failures)")

    def exchange(domain: str) -> None:
        nonlocal fail_streak
        qid = random.getrandbits(16)
        packet = build_query(domain, qid)
        started = time.perf_counter_ns()
        deadline = time.monotonic() + TIMEOUT
        try:
            sock.sendto(packet, (HOST, PORT))
        except OSError:
            failed()
            return
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failed()
                return
            sock.settimeout(remaining)
            try:
                response, _ = sock.recvfrom(4096)
            except OSError:
                failed()
                return
            if (
                len(response) < 12
                or struct.unpack("!H", response[:2])[0] != qid
                or not (response[2] & 0x80)
            ):
                # A late answer to an earlier query, or not a response at all;
                # discard it and keep waiting.
                continue
            rcode = response[3] & 0x0F
            if rcode != 3:
                failed()
                return
            samples.append(time.perf_counter_ns() - started)
            fail_streak = 0
            return

    # warm up for two seconds so the JIT tier-up covers the measured loop
    warmup_started = time.monotonic()
    index = 0
    while time.monotonic() - warmup_started < 2.0:
        exchange(domains[index % len(domains)])
        index += 1
    samples.clear()
    warmup_errors = errors
    errors = 0
    fail_streak = 0

    started = time.perf_counter()
    for _ in range(repeat):
        for domain in domains:
            exchange(domain)
    elapsed = time.perf_counter() - started

    samples.sort()
    total = len(samples)

    def pct(p: float) -> float:
        return samples[min(total - 1, int(total * p))] / 1000.0 if total else 0.0

    result = {
        "variant": variant,
        "run_tag": tag,
        "app_sha256": app_sha,
        "queries": total,
        "errors": errors,
        "warmup_errors": warmup_errors,
        "elapsed_s": round(elapsed, 3),
        "qps": round(total / elapsed, 1),
        "p50_us": round(statistics.median(samples) / 1000.0, 1) if total else 0.0,
        "p95_us": round(pct(0.95), 1),
        "p99_us": round(pct(0.99), 1),
        "mean_us": round(statistics.fmean(samples) / 1000.0, 1) if total else 0.0,
    }
    print(json.dumps(result))
    if errors:
        print(
            f"{errors} of {errors + total} queries failed; "
            f"{out} left as it was",
            file=sys.stderr,
        )
        return 1
    with open(out, "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
