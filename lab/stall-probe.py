#!/usr/bin/env python3
"""Send one A query at a time at a fixed rate and record every reply slower than a threshold.

    lab/stall-probe.py HOST PORT NAME SECONDS RATE THRESHOLD_MS OUT.json

The probe is what upstream issue #2174 used to show the pauses of a forced collection: a
single UDP query at a time, the round trip timed, every slow one logged with its time. Use a
name the server answers without forwarding (a blocked name in the lab). A reply that does not
arrive in two seconds counts as a timeout with a 2000 ms round trip.
"""

import json
import secrets
import socket
import struct
import sys
import time


def build_query(name: str, qid: int) -> bytes:
    header = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    labels = b"".join(
        bytes([len(part)]) + part.encode("ascii")
        for part in name.rstrip(".").split(".")
    )
    return header + labels + b"\x00" + struct.pack("!HH", 1, 1)


def main() -> int:
    if len(sys.argv) != 8:
        print(__doc__, file=sys.stderr)
        return 2
    host, port, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    seconds, rate, threshold_ms, out = (
        float(sys.argv[4]),
        float(sys.argv[5]),
        float(sys.argv[6]),
        sys.argv[7],
    )

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)
    interval = 1.0 / rate
    rtts: list[float] = []
    stalls: list[list[float]] = []
    per_second: dict[int, tuple[int, float]] = {}
    timeouts = 0
    started = time.time()
    next_slot = time.perf_counter()
    end = next_slot + seconds

    while next_slot < end:
        remaining = next_slot - time.perf_counter()
        if remaining > 0.002:
            time.sleep(remaining - 0.001)
        while time.perf_counter() < next_slot:
            pass  # the last millisecond is spun: sleep() granularity is too coarse to hold the rate

        qid = secrets.randbelow(0x10000)
        sent_wall = time.time()
        t0 = time.perf_counter()
        sock.sendto(build_query(name, qid), (host, port))
        rtt_ms = 2000.0
        while True:
            try:
                data = sock.recv(2048)
            except TimeoutError:
                timeouts += 1
                break
            if len(data) >= 2 and struct.unpack("!H", data[:2])[0] == qid:
                rtt_ms = (time.perf_counter() - t0) * 1000.0
                break

        rtts.append(rtt_ms)
        second = int(sent_wall)
        count, worst = per_second.get(second, (0, 0.0))
        per_second[second] = (count + 1, max(worst, round(rtt_ms, 1)))
        if rtt_ms >= threshold_ms and len(stalls) < 2000:
            stalls.append([round(sent_wall, 3), round(rtt_ms, 1)])

        next_slot += interval
        if time.perf_counter() > next_slot + 1.0:
            next_slot = time.perf_counter()  # never burst after a long stall

    ordered = sorted(rtts)

    def pct(p: float) -> float:
        return (
            round(ordered[min(len(ordered) - 1, int(p * len(ordered)))], 3)
            if ordered
            else 0.0
        )

    data = {
        "name": name,
        "rate": rate,
        "threshold_ms": threshold_ms,
        "started_epoch": round(started, 3),
        "queries": len(rtts),
        "timeouts": timeouts,
        "p50_ms": pct(0.5),
        "p99_ms": pct(0.99),
        "p999_ms": pct(0.999),
        "max_ms": round(max(rtts), 1) if rtts else 0.0,
        "per_second": [per_second[s] for s in sorted(per_second)],
        "first_second": min(per_second) if per_second else 0,
        "stalls": stalls,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f)
    print(
        f"{len(rtts)} queries, p50 {data['p50_ms']} ms, p99 {data['p99_ms']} ms, max {data['max_ms']} ms, "
        f"{len(stalls)} replies >= {threshold_ms} ms, {timeouts} timeouts"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
