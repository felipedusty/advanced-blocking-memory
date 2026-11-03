#!/usr/bin/env bash
# Small containers: does the app still load the biggest list at start, and does a forced reload still complete?
# The container limit is the variable here (docker --memory, no extra swap); every other lab run has none.
#
#   lab/small-limits.sh start  <original|patch-dir> <limit>...    e.g. start patch/experiments/hash64-set 160m 128m
#   lab/small-limits.sh reload <original|patch-dir> <limit>...
#
# start:  starts the server, samples 150 names of the biggest list (the 1.85 M-name list, one name in 10,000) and asks
#         for their TXT report; a name another list also holds counts as blocked, so a missing list is understated.
#         Counts the OutOfMemoryException lines of the application log.
# reload: lab/run-reload.sh under the same limit; reports completed (with the cgroup peak) or did not complete.
# The result lines are appended to results/small-limits-amd64/<label>.txt (label: original or the patch name).
set -uo pipefail
cd "$(dirname "$0")/.."
mode=${1:?start|reload}
target=${2:?original or a patch directory (relative to the repository root)}
shift 2
[ $# -ge 1 ] || { echo "usage: $0 start|reload <original|patch-dir> <limit>..." >&2; exit 2; }
out=results/small-limits-amd64
mkdir -p "$out"
if [ "$target" = original ]; then
	variant=original
	label=original
	lab/build-app.sh original >/dev/null 2>&1
else
	variant=patched
	label=$(basename "$target")
	PATCH_DIR=$target lab/build-app.sh patched >/dev/null 2>&1
fi
biggest=lab/lists/baf6a05493786970f318ab55bb54534ca8d5f4e0319ab774d4d50108c6be9f3e
names=$(awk 'index($0,"||")==1 && index($0,"^")>0 { n++; if (n % 10000 == 0) { s=substr($0,3); sub(/\^.*/,"",s); print s } }' "$biggest" | awk 'NR<=150')

for mem in "$@"; do
	case "$mode" in
	start)
		MEM=$mem RUN_TAG="-sl$mem" lab/run-lab.sh "$variant" >/dev/null 2>&1 || echo "run-lab failed at $mem" >&2
		oom=$(docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log' 2>/dev/null | awk '/OutOfMemoryException/ { n++ } END { print n + 0 }')
		blocked=0
		total=0
		for n in $names; do
			total=$((total + 1))
			r=$(docker exec dns-lab dig +short +time=1 +tries=1 @127.0.0.1 TXT "$n" 2>/dev/null | awk '/source=advanced-blocking-app/ { print "b" }')
			[ -z "$r" ] || blocked=$((blocked + 1))
		done
		line="$label MEM=$mem start: names of the biggest list blocked $blocked of $total, OutOfMemoryException lines in the app log $oom"
		docker rm -f dns-lab >/dev/null 2>&1
		;;
	reload)
		if msg=$(MEM=$mem RUN_TAG="-sl$mem" lab/run-reload.sh "$variant" 2>&1); then
			peak=$(python3 -c "import json; print(round(json.load(open('results/reload-$variant-sl$mem.json'))['cgroup_memory_peak_bytes'] / 1048576, 1))")
			line="$label MEM=$mem reload: completed, cgroup peak $peak MiB"
		else
			line="$label MEM=$mem reload: did not complete ($(printf '%s' "$msg" | awk 'END { print }'))"
		fi
		docker rm -f dns-lab >/dev/null 2>&1
		;;
	*)
		echo "mode must be start or reload" >&2
		exit 2
		;;
	esac
	echo "$line" | tee -a "$out/$label.txt"
done
