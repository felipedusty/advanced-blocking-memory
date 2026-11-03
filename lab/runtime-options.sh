#!/usr/bin/env bash
# Do .NET runtime settings change the memory of the original, or of a candidate? No container memory limit.
#
#   lab/runtime-options.sh        results go to results/runtime-options-amd64/ and its table.md
#
# Each setting is passed to the container as an environment variable (EXTRA_DOCKER_ARGS of lab/run-lab.sh), one
# startup per setting for GCConserveMemory (original and hash64-set), two for the others (original only).
set -euo pipefail
cd "$(dirname "$0")/.."
out=results/runtime-options-amd64
mkdir -p "$out"
rows=()

run() { # run <variant> <label> <tag> <env assignment or empty>
	local variant=$1 label=$2 tag=$3 env=$4
	EXTRA_DOCKER_ARGS=${env:+-e $env} RUN_TAG="-ro$tag" lab/run-lab.sh "$variant" >/dev/null 2>&1 || echo "FAIL $label" >&2
	cp "results/$variant-ro$tag.json" "$out/$label.json"
	rows+=("$label")
	docker rm -f dns-lab >/dev/null 2>&1 || true
}

lab/build-app.sh original >/dev/null 2>&1
for v in 0 3 5 7 9; do run original "original-conserve$v" "orig$v" "DOTNET_GCConserveMemory=$v"; done
for i in 1 2; do run original "original-gen0budget-$i" "gen0$i" "DOTNET_GCgen0MaxBudget=0x600000"; done
for i in 1 2; do run original "original-nonconcurrent-$i" "nc$i" "DOTNET_gcConcurrent=0"; done
PATCH_DIR=patch/experiments/hash64-set lab/build-app.sh patched >/dev/null 2>&1
for v in 0 3 5 7 9; do run patched "hash64-set-conserve$v" "set$v" "DOTNET_GCConserveMemory=$v"; done

python3 - "$out" "${rows[@]}" <<'PY' | tee "$out/table.md"
import json
import sys

out = sys.argv[1]
print("| run | anon MiB |")
print("|---|---|")
for label in sys.argv[2:]:
    print(f"| `{label}` | {json.load(open(f'{out}/{label}.json'))['anon_bytes'] / 1048576:.1f} |")
PY
