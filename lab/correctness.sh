#!/usr/bin/env bash
# The CI correctness steps for one candidate, locally: the original and the candidate answer the same A and TXT
# query for every listed name, the allow-covered names, the near-miss names and the edge cases. No container
# memory limit. Takes tens of minutes (about 2.3 M names per build and query type).
#
#   lab/correctness.sh <patch-dir> <out-dir>        patch-dir is relative to the repository root
#   HOSTS=1 lab/correctness.sh <patch-dir> <out-dir>    also the A+TXT differential on hosts-format lists
#
# Needs lab/fetch-lists.sh and, for HOSTS=1, lab/make-hosts-lists.py to have run. The records of both builds
# (exhaustive, near-miss, edge, and hosts) are copied to <out-dir>; the exit status is 1 on any difference.
set -euo pipefail
cd "$(dirname "$0")/.."
patch_dir=${1:?patch directory}
out_dir=${2:?output directory}
client=python:3.13-slim
mkdir -p "$out_dir"
PATCH_DIR=$patch_dir lab/build-app.sh patched >/dev/null
lab/build-app.sh original >/dev/null
trap 'docker rm -f dns-lab null-upstream >/dev/null 2>&1 || true' EXIT

in_lab() { # in_lab [docker options] -- command: run a client script inside the lab container's network namespace
	local opts=()
	while [ "$1" != -- ]; do opts+=("$1"); shift; done
	shift
	docker run --rm --network container:dns-lab -e DNS_PORT=53 ${LIMIT:+-e LIMIT="$LIMIT"} ${opts[@]+"${opts[@]}"} \
		--user "$(id -u):$(id -g)" -v "$PWD":/work -w /work "$client" "$@"
}

for variant in original patched; do
	RUN_TAG=-exhaustive FORWARDERS=127.0.0.1:5353 GRACE_S=5 lab/run-lab.sh "$variant" >/dev/null 2>&1
	in_lab -e WORKERS=8 -- python3 lab/exhaustive.py "$variant" -exhaustive 8 >/dev/null
	echo "exhaustive $variant done"
done

for variant in original patched; do
	RUN_TAG=-near-miss FORWARDERS=127.0.0.1:5353 GRACE_S=5 lab/run-lab.sh "$variant" >/dev/null 2>&1
	docker run -d --rm --name null-upstream --network container:dns-lab --user "$(id -u):$(id -g)" \
		-v "$PWD":/work -w /work "$client" python3 lab/null-upstream.py >/dev/null
	sleep 1
	in_lab -- python3 lab/near-miss.py "$variant" -near-miss 8 >/dev/null
	docker rm -f null-upstream >/dev/null
	echo "near-miss $variant done"
done

for variant in original patched; do
	RUN_TAG=-edge APP_CONFIG=lab/config/dnsApp.edge.config EDGE=1 FORWARDERS=127.0.0.1:5353 lab/run-lab.sh "$variant" >/dev/null 2>&1
	docker run -d --rm --name null-upstream --network container:dns-lab --user "$(id -u):$(id -g)" \
		-v "$PWD":/work -w /work "$client" python3 lab/null-upstream.py >/dev/null
	sleep 1
	RUN_TAG=-edge lab/check-edge.sh "$variant" >/dev/null 2>&1
	docker rm -f null-upstream >/dev/null
	echo "edge $variant done"
done

if [ "${HOSTS:-0}" = 1 ]; then
	cfg=lab/config/dnsApp.hosts.config
	for variant in original patched; do
		RUN_TAG=-hx APP_CONFIG=$cfg FORWARDERS=127.0.0.1:5353 GRACE_S=5 lab/run-lab.sh "$variant" >/dev/null 2>&1
		in_lab -e WORKERS=8 -e APP_CONFIG=$cfg -- python3 lab/exhaustive.py "$variant" -hx 8 >/dev/null
		echo "hosts differential $variant done"
	done
fi
docker rm -f dns-lab >/dev/null 2>&1 || true

for variant in original patched; do
	cp "results/$variant-exhaustive.exhaustive.json" "results/$variant-near-miss.near-miss.json" \
		"results/$variant-edge.edge.txt" "$out_dir/"
	[ "${HOSTS:-0}" != 1 ] || cp "results/$variant-hx.exhaustive.json" "$out_dir/"
done

OUT_DIR=$out_dir HOSTS=${HOSTS:-0} python3 - <<'PY'
import json
import os
import sys

out = os.environ["OUT_DIR"]
passes = [
    (
        "exhaustive",
        "exhaustive.exhaustive",
        ["domains", "answers", "blocked", "errors", "digest", "txt_blocked", "txt_errors", "txt_digest",
         "allow_answers", "allow_reported", "allow_errors", "allow_digest"],
    ),
    (
        "near-miss",
        "near-miss.near-miss",
        ["names", "answers", "errors", "blocked", "forwarded", "other", "digest", "model_mismatches"],
    ),
]
if os.environ["HOSTS"] == "1":
    passes.append(("hosts-format", "hx.exhaustive", passes[0][2]))
ok = True
for label, kind, keys in passes:
    o = json.load(open(f"{out}/original-{kind}.json"))
    p = json.load(open(f"{out}/patched-{kind}.json"))
    same = all(o.get(k) == p.get(k) for k in keys)
    ok &= same
    print(label, "IDENTICAL" if same else "DIFFERENT")
    for k in keys:
        if k in o or k in p:
            print(f"  {k:18s} original={o.get(k)} patched={p.get(k)}")
edge_same = open(f"{out}/original-edge.edge.txt").read() == open(f"{out}/patched-edge.edge.txt").read()
ok &= edge_same
print("edge", "IDENTICAL" if edge_same else "DIFFERENT")
sys.exit(0 if ok else 1)
PY
