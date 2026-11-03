#!/usr/bin/env python3
"""Markdown table of the candidates measured by lab/session-bench.sh, against the original of the same session.

    lab/session-table.py results/session-local
"""
import json
import os
import statistics as st
import sys

MIB = 2**20


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def memory(directory, prefix, reload_name):
    rows = [load(f"{directory}/{prefix}{i}.json") for i in (1, 2, 3)]
    return (
        st.median(r["cgroup_memory_peak_bytes"] for r in rows) / MIB,
        st.median(r["anon_bytes"] for r in rows) / MIB,
        load(f"{directory}/{reload_name}")["cgroup_memory_peak_bytes"] / MIB,
    )


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = sys.argv[1]
    start = memory(f"{out}/orig-start", "original-run", "original-reload.json")
    end = None
    if os.path.isdir(f"{out}/orig-end"):
        end = memory(f"{out}/orig-end", "original-e-run", "original-e-reload.json")

    print(f"original, start of session : startup {start[0]:.1f}  anon {start[1]:.1f}  reload {start[2]:.1f} MiB")
    if end:
        print(f"original, end of session   : startup {end[0]:.1f}  anon {end[1]:.1f}  reload {end[2]:.1f} MiB")
    ref = tuple((a + b) / 2 for a, b in zip(start, end)) if end else start
    print(f"reference original         : startup {ref[0]:.1f}  anon {ref[1]:.1f}  reload {ref[2]:.1f} MiB\n")

    print("| candidate | lines + / - | startup peak | steady anon | reload peak | anon ratio | startup ratio | reload ratio | p50 (paired) | qps (paired) | 500 reports |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for name in sorted(os.listdir(out)):
        d = f"{out}/{name}"
        if name in ("orig-start", "orig-end") or not os.path.isfile(f"{d}/reload-patched-reload.json"):
            continue
        s, a, r = memory(d, "patched-run", "reload-patched-reload.json")
        added = removed = 0
        if os.path.isfile(f"{d}/numstat.txt"):
            with open(f"{d}/numstat.txt", encoding="utf-8") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2 and parts[0].isdigit():
                        added += int(parts[0])
                        removed += int(parts[1])
        lat_o = [load(f"{d}/lat-original-{i}.latency.json") for i in (1, 2, 3)]
        lat_p = [load(f"{d}/lat-patched-{i}.latency.json") for i in (1, 2, 3)]
        p50_o, p50_p = st.median(x["p50_us"] for x in lat_o), st.median(x["p50_us"] for x in lat_p)
        q_o, q_p = st.median(x["qps"] for x in lat_o), st.median(x["qps"] for x in lat_p)
        overlap = min(x["qps"] for x in lat_p) <= max(x["qps"] for x in lat_o) and min(x["qps"] for x in lat_o) <= max(x["qps"] for x in lat_p)
        reports = "?"
        if os.path.isfile(f"{d}/reports.txt"):
            with open(f"{d}/reports.txt", encoding="utf-8") as f:
                reports = f.read().strip()
        print(
            f"| {name} | +{added} / -{removed} | {s:.1f} | {a:.1f} | {r:.1f} | {ref[1] / a:.2f}x | {ref[0] / s:.2f}x | {ref[2] / r:.2f}x | "
            f"{p50_p:.1f} vs {p50_o:.1f} µs ({(p50_p / p50_o - 1) * 100:+.1f}%) | "
            f"{q_p:.0f} vs {q_o:.0f} ({(q_p / q_o - 1) * 100:+.1f}%, {'overlap' if overlap else 'no overlap'}) | {reports} |"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
