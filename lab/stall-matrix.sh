#!/usr/bin/env bash
# Query stalls while the lists load and reload, for the original, the original with the 4-line GC step, a candidate
# that has the GC step on a compact structure, and the three finalists. No container memory limit.
#
#   lab/stall-matrix.sh [rounds]       results go to results/stall/<build>-<round>.json and results/stall/table.md
#
# Each round is lab/stall-reload.sh: 200 queries per second for a blocked name from inside the container's network
# namespace, a forced reload, replies slower than 10 ms counted per window. Run it with nothing else on the machine.
set -euo pipefail
cd "$(dirname "$0")/.."
rounds=${1:-2}
out=results/stall
mkdir -p "$out"

builds=(
	original
	original-gc:patch/experiments/original-gc
	exact-frontcoded-gc:patch/experiments/exact-frontcoded-gc
	hash64-set:patch/experiments/hash64-set
	hash64-index2:patch/experiments/hash64-index2
	exact-tags:patch/experiments/exact-tags
)

for b in "${builds[@]}"; do
	name=${b%%:*}
	if [ "$name" = original ]; then
		variant=original
		lab/build-app.sh original >/dev/null 2>&1
	else
		variant=patched
		PATCH_DIR=${b#*:} lab/build-app.sh patched >/dev/null 2>&1
	fi
	for n in $(seq "$rounds"); do
		RUN_TAG="-stall$n" lab/stall-reload.sh "$variant" >/dev/null 2>&1 || echo "FAIL $name round $n" >&2
		cp "results/stall-$variant-stall$n.json" "$out/$name-$n.json"
		docker rm -f dns-lab >/dev/null 2>&1 || true
	done
done

python3 - "$out" "$rounds" "${builds[@]}" <<'PY' | tee "$out/table.md"
import json
import sys

out, rounds = sys.argv[1], int(sys.argv[2])
print("| build | round | queries in the reload window | replies >= 10 ms in it | >= 50 ms | worst reply in it (ms) | worst reply in the settle window (ms) | >= 100 ms anywhere |")
print("|---|---|---|---|---|---|---|---|")
for b in sys.argv[3:]:
    name = b.split(":")[0]
    for n in range(1, rounds + 1):
        d = json.load(open(f"{out}/{name}-{n}.json"))
        s = d["slow_replies"]
        over100 = sum(s[k]["over_100_ms"] for k in s)
        print(
            f"| `{name}` | {n} | {d['queries']['reload']} | {s['reload']['count']} | {s['reload']['over_50_ms']} "
            f"| {d['worst_reply_ms']['reload']:.1f} | {d['worst_reply_ms']['settle']:.1f} | {over100} |"
        )
PY
