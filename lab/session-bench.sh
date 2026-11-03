#!/usr/bin/env bash
# Compare candidates against the original in ONE session on one machine, so that the
# session-to-session drift (about 7% in this lab) does not enter the comparison.
#
#   lab/session-bench.sh start                        # the original: 3 startups, reports, reload
#   lab/session-bench.sh cand <name> <patch-dir>      # one candidate, same battery plus 3 paired latency rounds
#   lab/session-bench.sh end                          # the original again, to show the drift over the session
#   lab/session-table.py results/session-local        # the table
#
# Run it with nothing else on the machine: the latency rounds are sensitive to load. Requires
# lab/fetch-lists.sh to have run. Results go to $OUT (default results/session-local).
set -u
cd "$(dirname "$0")/.." || exit 1
OUT=${OUT:-$PWD/results/session-local}
mkdir -p "$OUT"
mode=${1:-}

original_block() { # $1 = tag prefix, $2 = 1 to also write the reports the paired latency rounds need
	for i in 1 2 3; do RUN_TAG=-$1run$i lab/run-lab.sh original >/dev/null 2>&1 || echo "FAIL original run $i"; done
	if [ "$2" = 1 ]; then RUN_TAG=-$1run3 lab/check-function.sh original >/dev/null 2>&1 || echo "FAIL original check"; fi
	RUN_TAG=-$1reload lab/run-reload.sh original >/dev/null 2>&1 || echo "FAIL original reload"
}

case "$mode" in
start)
	rm -rf results/*.json "${OUT:?}/orig-start"
	mkdir -p "$OUT/orig-start"
	[ "${PREBUILT:-0}" = 1 ] || lab/build-app.sh original >/dev/null 2>&1
	[ "${ORIGINAL_CHECK:-1}" = 1 ] || rm -f results/original-run3.reports.txt results/original-run3.reports.source
	original_block "" "${ORIGINAL_CHECK:-1}"
	cp results/original-run?.json "$OUT/orig-start/"
	cp results/reload-original-reload.json "$OUT/orig-start/original-reload.json"
	;;
cand)
	name=${2:?candidate name}
	dir=${3:?patch directory}
	[ -d "$dir" ] || { echo "no such patch directory: $dir" >&2; exit 2; }
	mkdir -p "$OUT/$name"
	echo "== $name ($dir)"
	if [ "${PREBUILT:-0}" = 1 ]; then
		mkdir -p lab/.work/out-patched && cp "$dir"/* lab/.work/out-patched/
	else
		PATCH_DIR=$dir lab/build-app.sh patched 2>&1 | tail -1
	fi
	sha256sum lab/.work/out-patched/AdvancedBlockingApp.dll | cut -c1-16
	for i in 1 2; do RUN_TAG=-run$i lab/run-lab.sh patched >/dev/null 2>&1 || echo "FAIL run $i"; done
	RUN_TAG=-run3 lab/run-lab.sh patched >/dev/null 2>&1 && RUN_TAG=-run3 lab/check-function.sh patched >/dev/null 2>&1 || echo "FAIL run 3"
	src=results/original-run3.reports.source
	if [ ! -f results/original-run3.reports.txt ]; then
		# ORIGINAL_CHECK=0: the original is not queried for reports, the latency client takes the first candidate's
		cp results/patched-run3.reports.txt results/original-run3.reports.txt
		echo "$name" >$src
	fi
	ref=original
	[ ! -f $src ] || ref="$(cat $src) (the original was not queried)"
	if cmp -s results/original-run3.reports.txt results/patched-run3.reports.txt; then
		echo "identical to $ref" >"$OUT/$name/reports.txt"
	else
		echo "differ from $ref" >"$OUT/$name/reports.txt"
	fi
	echo "reports: $(cat "$OUT/$name/reports.txt")"
	LATENCY_TAG=-run3 lab/latency-rounds.sh 3 >/dev/null 2>&1 || echo "FAIL latency"
	RUN_TAG=-reload lab/run-reload.sh patched >/dev/null 2>&1 || echo "FAIL reload"
	cp results/patched-run?.json results/lat-original-?.latency.json results/lat-patched-?.latency.json \
		results/reload-patched-reload.json "$OUT/$name/"
	[ "${PREBUILT:-0}" = 1 ] || git apply --numstat "$dir"/*.patch >"$OUT/$name/numstat.txt"
	;;
end)
	mkdir -p "$OUT/orig-end"
	original_block "e-" 0
	cp results/original-e-run?.json "$OUT/orig-end/"
	cp results/reload-original-e-reload.json "$OUT/orig-end/original-e-reload.json"
	;;
*)
	echo "usage: $0 start | cand <name> <patch-dir> | end" >&2
	exit 2
	;;
esac
echo "done $mode"
