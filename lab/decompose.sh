#!/usr/bin/env bash
# Where the memory goes: cgroup `anon` after the last list is parsed, for a set of builds, with no container
# memory limit. Each build is started RUNS times (default 2) in a fresh container.
#
#   lab/decompose.sh [runs]            results go to results/decomposition-amd64/<build>-<n>.json
#
# `no-lists` is the original with lab/config/dnsApp.empty.config (the floor of the server), `original` the
# unpatched app, the others patches under patch/. Needs lab/fetch-lists.sh to have run.
set -euo pipefail
cd "$(dirname "$0")/.."
runs=${1:-2}
out=${OUT:-results/decomposition-amd64}
mkdir -p "$out"

builds=(
	no-lists
	original
	original-presize:patch/experiments/original-presize
	parse-only:patch/experiments/parse-only
	hash64-sorted:patch/experiments/hash64-sorted
	hash64-sorted-gc:patch/experiments/hash64-sorted-gc
	hash64-buckets:patch/experiments/hash64-buckets
	hash64-list:patch/experiments/hash64-list
	hash64-presize:patch/experiments/hash64-presize
	hash64-set-nocap:patch/experiments/hash64-set-nocap
	hash64-set:patch/experiments/hash64-set
	hash64-index2:patch/experiments/hash64-index2
	hash96-list:patch/experiments/hash96-list
	hash128-list:patch/experiments/hash128-list
	exact:patch/exact
	exact-csr:patch/experiments/exact-csr
	exact-tags:patch/experiments/exact-tags
	exact-csr-gc:patch/experiments/exact-csr-gc
	exact-hashset-int:patch/experiments/exact-hashset-int
	hash96-tuple3:patch/experiments/hash96-tuple3
)

lab/build-app.sh original >/dev/null
for b in "${builds[@]}"; do
	name=${b%%:*}
	[ -z "${ONLY:-}" ] || case " $ONLY " in *" $name "*) ;; *) continue ;; esac
	dir=${b#*:}
	config=lab/config/dnsApp.config
	case "$name" in
	no-lists)
		variant=original
		config=lab/config/dnsApp.empty.config
		;;
	original) variant=original ;;
	*)
		variant=patched
		PATCH_DIR=$dir lab/build-app.sh patched >/dev/null
		;;
	esac
	for i in $(seq "$runs"); do
		RUN_TAG="-d$name$i" APP_CONFIG=$config lab/run-lab.sh "$variant" >/dev/null 2>&1 || echo "FAIL $name run $i"
		cp "results/$variant-d$name$i.json" "$out/$name-$i.json"
	done
	docker rm -f dns-lab >/dev/null 2>&1 || true
done

python3 - "$out" "$runs" "${builds[@]}" <<'PY'
import json
import sys

out, runs = sys.argv[1], int(sys.argv[2])
print("| build | anon MiB (runs) |")
print("|---|---|")
for b in sys.argv[3:]:
    name = b.split(":")[0]
    try:
        vals = [json.load(open(f"{out}/{name}-{i}.json"))["anon_bytes"] / 1048576 for i in range(1, runs + 1)]
    except FileNotFoundError:
        continue
    print(f"| `{name}` | {', '.join(f'{v:.1f}' for v in vals)} |")
PY
