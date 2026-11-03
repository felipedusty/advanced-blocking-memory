#!/usr/bin/env bash
# Measure latency in interleaved rounds and keep the median run per variant.
#
#   lab/latency-rounds.sh [rounds] [variants...]
#     default 3 rounds and the variants original patched.
#     LATENCY_REPEATS overrides the repeats per domain (100).
#
# Every round restarts every variant back to back in alternating order, so a
# position effect on the host lands on all of them, then measures latency
# inside the lab container's network namespace because the host UDP port
# mapping does not deliver replies in this WSL setup. Round n writes its JSON to
# lab/.run/latency-rounds/lat-<variant>-<n>.latency.json. After every round
# passes its checks, the final block copies the rounds to
# results/lat-<variant>-<n>.latency.json and writes results/<variant>.latency.json,
# the run whose p50 is the median of an odd number of rounds. The p50/qps cells
# come from that round; the tail cells are per-metric medians of the rounds.
#
# Each round also re-runs run-lab.sh, which rewrites the untagged startup
# artifacts for that variant (results/<variant>.json and its .csv/.log/.stat/
# .applog); the startup headline comes from the three -run<n> startup runs, not
# those files.
#
# Needs lab/build-app.sh and lab/check-function.sh to have run, because the
# client reads the blocked domains from
# results/<variant>${LATENCY_TAG}.reports.txt (LATENCY_TAG is empty by default,
# so the untagged report).
# LATENCY_REPEATS differs from prod-load.py's QUERIES, which counts total
# queries; an exported QUERIES must not make this script send millions of
# queries per variant.
set -euo pipefail
cd "$(dirname "$0")/.."

rounds=${1:-3}
case "$rounds" in
'' | *[!0-9]*)
	echo "usage: $0 [rounds] [variants...]" >&2
	exit 2
	;;
esac
rounds=$((10#$rounds))

[ "$rounds" -ge 1 ] || {
	echo "rounds must be at least 1" >&2
	exit 2
}
[ $((rounds % 2)) -eq 1 ] || {
	echo "rounds must be odd so the median is one run" >&2
	exit 2
}
if [ $# -gt 1 ]; then
	shift
	variants=("$@")
else
	variants=(original patched)
fi
[ ${#variants[@]} -ge 2 ] || {
	echo "at least two variants are required" >&2
	exit 2
}

repeats=${LATENCY_REPEATS:-100}
case "$repeats" in
'' | 0* | *[!0-9]*)
	echo "LATENCY_REPEATS must be a positive integer" >&2
	exit 2
	;;
esac
repeats=$((10#$repeats))
[ "$repeats" -ge 1 ] || {
	echo "LATENCY_REPEATS must be at least 1" >&2
	exit 2
}
client_image=python:3.13-slim
round_dir=lab/.run/latency-rounds
rm -rf "$round_dir"
mkdir -p "$round_dir"

for n in $(seq 1 "$rounds"); do
	if [ $((n % 2)) -eq 1 ]; then
		order=("${variants[@]}")
	else
		order=()
		for ((i = ${#variants[@]} - 1; i >= 0; i--)); do
			order+=("${variants[i]}")
		done
	fi
	for variant in "${order[@]}"; do
		printf 'round %s/%s %s\n' "$n" "$rounds" "$variant" >&2
		lab/run-lab.sh "$variant"
		out=lab/.work/out-$variant
		want_sha=$(sha256sum "$out/AdvancedBlockingApp.dll" | cut -d' ' -f1)
		have_sha=$(docker inspect -f '{{index .Config.Labels "technitiumfix.app_sha256"}}' dns-lab)
		have_limit=$(docker inspect -f '{{index .Config.Labels "technitiumfix.memory_limit"}}' dns-lab)
		[ "$have_sha" = "$want_sha" ] || {
			echo "dns-lab runs $have_sha, not the local build $want_sha" >&2
			exit 1
		}
		[ "$have_limit" = "${MEM:-none}" ] || {
			echo "dns-lab limit $have_limit is not the expected ${MEM:-none}" >&2
			exit 1
		}
		docker run --rm --network container:dns-lab -e DNS_PORT=53 \
			-e "LATENCY_OUT=$round_dir/lat-$variant-$n.latency.json" \
			-v "$PWD":/work -w /work --user "$(id -u):$(id -g)" \
			"$client_image" python3 lab/latency.py "$variant" "$repeats" "${LATENCY_TAG:-}"
	done
done

python3 - "$rounds" "${variants[@]}" <<'PY'
import json
import shutil
import statistics
import sys

rounds = int(sys.argv[1])
variants = sys.argv[2:]
rows_by_variant = {}
shas = {}
for variant in variants:
    rows = []
    for n in range(1, rounds + 1):
        with open(f"lab/.run/latency-rounds/lat-{variant}-{n}.latency.json") as f:
            rows.append(json.load(f))
    rows_by_variant[variant] = rows
    shas[variant] = {row["app_sha256"] for row in rows}
    if len(shas[variant]) != 1:
        sys.exit(f"{variant} rounds mix app assemblies: {sorted(shas[variant])}")
seen = {}
for variant in variants:
    sha = next(iter(shas[variant]))
    if sha in seen:
        sys.exit(f"{variant} and {seen[sha]} ran the same app assembly")
    seen[sha] = variant

for variant in variants:
    rows = rows_by_variant[variant]
    p50s = [row["p50_us"] for row in rows]
    qps = [row["qps"] for row in rows]
    median = statistics.median(p50s)
    chosen = min(range(len(rows)), key=lambda index: abs(p50s[index] - median))
    with open(f"results/{variant}.latency.json", "w") as f:
        json.dump(rows[chosen], f, indent=2)
        f.write("\n")
    for n, row in enumerate(rows, 1):
        print(f"{variant} round {n}: p50 {row['p50_us']} us p99 {row['p99_us']} us qps {row['qps']}")
        shutil.copyfile(
            f"lab/.run/latency-rounds/lat-{variant}-{n}.latency.json",
            f"results/lat-{variant}-{n}.latency.json",
        )
    print(
        f"{variant} median of {rounds}: p50 {statistics.median(p50s):.1f} us "
        f"p95 {statistics.median(row['p95_us'] for row in rows):.1f} us "
        f"p99 {statistics.median(row['p99_us'] for row in rows):.1f} us "
        f"qps {statistics.median(qps):.1f}; canonical from round {chosen + 1}"
    )
PY
