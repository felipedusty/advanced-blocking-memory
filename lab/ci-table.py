#!/usr/bin/env python3
"""Markdown comparison of every candidate against its own original, from the lab records of one CI run.

    lab/ci-table.py results/ci-compare/run-41392206669

Each CI leg measures its own original next to its candidate, so every ratio is paired within a leg.
Lines are the added and removed lines of the candidate's patch (git apply --numstat). The candidate
list and patch directories come from .github/candidates.json.
"""
import json
import os
import statistics as st
import subprocess
import sys

MIB = 2**20
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def patch_lines(patch_dir):
    directory = os.path.join(REPO, patch_dir)
    patch = next(name for name in sorted(os.listdir(directory)) if name.endswith(".patch"))
    out = subprocess.run(
        ["git", "apply", "--numstat", os.path.join(directory, patch)],
        capture_output=True, text=True, cwd=REPO, check=True,
    ).stdout
    added = removed = 0
    for line in out.splitlines():
        a, r, _ = line.split("\t")
        added += int(a)
        removed += int(r)
    return added, removed


def leg(d):
    originals = [load(f"{d}/original-run{i}.json") for i in (1, 2, 3)]
    patched = [load(f"{d}/patched-run{i}.json") for i in (1, 2, 3)]
    lat_o = [load(f"{d}/lat-original-{i}.latency.json") for i in (1, 2, 3)]
    lat_p = [load(f"{d}/lat-patched-{i}.latency.json") for i in (1, 2, 3)]
    reload_o = load(f"{d}/reload-original-reload.json")
    reload_p = load(f"{d}/reload-patched-reload.json")
    near_o = load(f"{d}/original-near-miss.near-miss.json")
    near_p = load(f"{d}/patched-near-miss.near-miss.json")
    exh_o = load(f"{d}/original-exhaustive.exhaustive.json")
    exh_p = load(f"{d}/patched-exhaustive.exhaustive.json")

    def median(rows, key):
        return st.median(row[key] for row in rows) / MIB

    def peak(row):
        return max(row["peak_bytes"], row["cgroup_memory_peak_bytes"]) / MIB

    digests = ("digest", "txt_digest", "allow_digest")
    return {
        "start_o": median(originals, "cgroup_memory_peak_bytes"),
        "start_p": median(patched, "cgroup_memory_peak_bytes"),
        "anon_o": median(originals, "anon_bytes"),
        "anon_p": median(patched, "anon_bytes"),
        "reload_o": peak(reload_o),
        "reload_p": peak(reload_p),
        "p50_o": st.median(r["p50_us"] for r in lat_o),
        "p50_p": st.median(r["p50_us"] for r in lat_p),
        "qps_o": st.median(r["qps"] for r in lat_o),
        "qps_p": st.median(r["qps"] for r in lat_p),
        "qps_overlap": min(r["qps"] for r in lat_p) <= max(r["qps"] for r in lat_o)
        and min(r["qps"] for r in lat_o) <= max(r["qps"] for r in lat_p),
        "digests_equal": all(exh_o.get(k) is not None and exh_o.get(k) == exh_p.get(k) for k in digests),
        "near_equal": near_o["digest"] == near_p["digest"] and near_p["model_mismatches"] == 0,
    }


def find_leg(root, tag, name):
    for prefix in ("", "results-"):
        d = os.path.join(root, f"{prefix}{tag}-{name}")
        if os.path.isdir(d):
            return d
    return None


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = sys.argv[1]
    with open(os.path.join(REPO, ".github/candidates.json"), encoding="utf-8") as f:
        candidates = json.load(f)

    platforms = ("amd64", "arm64")
    results = {}
    for c in candidates:
        for tag in platforms:
            d = find_leg(root, tag, c["candidate"])
            if d is None:
                continue
            try:
                results[(tag, c["candidate"])] = leg(d)
            except (OSError, KeyError, ValueError) as exc:
                print(f"{tag}-{c['candidate']}: incomplete records ({exc}); the leg failed before it finished", file=sys.stderr)

    def anon_ratio(c):
        rows = [results[(t, c["candidate"])] for t in platforms if (t, c["candidate"]) in results]
        return sum(r["anon_o"] / r["anon_p"] for r in rows) / len(rows) if rows else 0

    ranked = sorted((c for c in candidates if anon_ratio(c) > 0), key=anon_ratio, reverse=True)

    print("| candidate | exact | lines + / - | anon amd64 | anon arm64 | reload peak amd64 | reload peak arm64 | p50 amd64 | p50 arm64 | same responses |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for c in ranked:
        name = c["candidate"]
        added, removed = patch_lines(c["patch_dir"])
        cells = []
        for key in ("anon", "reload"):
            for tag in platforms:
                r = results.get((tag, name))
                cells.append(f"{r[key + '_o'] / r[key + '_p']:.2f}x" if r else "-")
        for tag in platforms:
            r = results.get((tag, name))
            cells.append(f"{(r['p50_p'] / r['p50_o'] - 1) * 100:+.1f}%" if r else "-")
        rows = [results[(t, name)] for t in platforms if (t, name) in results]
        same = "yes" if rows and all(r["digests_equal"] and r["near_equal"] for r in rows) else "NO"
        print(f"| {name} | {c.get('exact', '?')} | +{added} / -{removed} | " + " | ".join(cells) + f" | {same} |")
    print("\nRatios are original over candidate (higher is better); p50 is the candidate against its own original.")

    for tag in platforms:
        print(f"\n### {tag}\n")
        print("| candidate | lines + / - | startup peak | steady anon | reload peak | anon ratio | reload ratio | p50 | qps | digests | near-miss |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        for c in candidates:
            name = c["candidate"]
            r = results.get((tag, name))
            if r is None:
                continue
            added, removed = patch_lines(c["patch_dir"])
            print(
                f"| {name} | +{added} / -{removed} | {r['start_p']:.1f} (orig {r['start_o']:.1f}) | {r['anon_p']:.1f} (orig {r['anon_o']:.1f}) | "
                f"{r['reload_p']:.1f} (orig {r['reload_o']:.1f}) | {r['anon_o'] / r['anon_p']:.2f}x | {r['reload_o'] / r['reload_p']:.2f}x | "
                f"{r['p50_p']:.1f} vs {r['p50_o']:.1f} µs ({(r['p50_p'] / r['p50_o'] - 1) * 100:+.1f}%) | "
                f"{(r['qps_p'] / r['qps_o'] - 1) * 100:+.1f}%{' (overlap)' if r['qps_overlap'] else ' (no overlap)'} | "
                f"{'equal' if r['digests_equal'] else 'DIFFER'} | {'equal' if r['near_equal'] else 'DIFFER'} |"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
