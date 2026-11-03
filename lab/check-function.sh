#!/usr/bin/env bash
# Functional check against the running lab container.
#
# For 500 domains evenly spaced across the sorted union of the list files,
# record the full TXT blocking report and whether the app answered. The report
# comes from the app itself (it names the matched list), so the check is
# deterministic and does not depend on upstream DNS. Compare
# results/<variant>.reports.txt between builds: identical files mean the parser
# kept the same decision and the same source list for every sampled domain.
#
# dig runs inside the container (the official image ships dnsutils) and must
# point at 127.0.0.1; without @ it uses the container's resolv.conf, which is
# Docker's embedded DNS and would reach the production resolver instead.
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:-}
if [ -z "$variant" ]; then
	echo "usage: $0 <variant>" >&2
	exit 2
fi

sample=${SAMPLE:-500}
case "$sample" in
'' | 0* | *[!0-9]*)
	echo "SAMPLE must be a positive integer" >&2
	exit 2
	;;
esac
tag=${RUN_TAG:-}
if [ -z "$tag" ] && [ -n "${SAMPLE:-}" ]; then
	echo "SAMPLE needs a RUN_TAG: a different run must not overwrite results/<variant>.reports.txt" >&2
	exit 2
fi

docker inspect dns-lab >/dev/null 2>&1 || {
	echo "dns-lab is not running; run lab/run-lab.sh first" >&2
	exit 1
}

have_variant=$(docker inspect -f '{{index .Config.Labels "technitiumfix.variant"}}' dns-lab)
have_tag=$(docker inspect -f '{{index .Config.Labels "technitiumfix.tag"}}' dns-lab)
[ "$have_variant" = "$variant" ] || {
	echo "dns-lab serves variant $have_variant, not $variant" >&2
	exit 1
}
[ "$have_tag" = "$tag" ] || {
	echo "dns-lab was started with RUN_TAG $have_tag, not $tag" >&2
	exit 1
}

# determinism: the same evenly spaced sample for every variant. The union comes
# from the exhaustive harness parser, so allow-covered names are excluded and a
# sampled domain is always blocked by the app.
extract_domains() {
	python3 - <<'PY'
import sys

sys.path.insert(0, "lab")
import exhaustive

per_list, _covered = exhaustive.extract_block_domains()
union = set()
for domains in per_list.values():
    union |= domains
for domain in sorted(union):
    print(domain)
PY
}

tmp=$(mktemp)
tmp_out=$(mktemp)
trap 'rm -f "$tmp" "$tmp_out"' EXIT
# A failed run must not leave the previous report behind for the latency and
# comparison steps to read.
rm -f "results/$variant$tag.reports.txt"
extract_domains >"$tmp"
total=$(wc -l <"$tmp")
[ "$total" -ge "$sample" ] || {
	echo "the union has $total domains, fewer than the $sample sample" >&2
	exit 1
}
mapfile -t domains < <(awk -v t="$total" -v n="$sample" 'BEGIN { k = 0 } NR - 1 == int(k * t / n) { print; k++ }' "$tmp")
[ "${#domains[@]}" -eq "$sample" ] || {
	echo "sampled ${#domains[@]} of $sample domains from $total" >&2
	exit 1
}

mkdir -p results
docker exec -i dns-lab bash -c '
	while read -r d; do
		r=$(dig +short +time=2 +tries=2 @127.0.0.1 TXT "$d" 2>/dev/null | tr "\n" " ")
		if [ -z "$r" ]; then
			printf "%s\t\n" "$d"
		else
			printf "%s\t%s\n" "$d" "$r"
		fi
	done
' < <(printf '%s\n' "${domains[@]}") >"$tmp_out"

blocked=$(awk -F'\t' '$2 ~ /source=advanced-blocking-app/ { n++ } END { print n + 0 }' "$tmp_out")
lab_group=$(awk -F'\t' '$2 ~ /group=lab/ { n++ } END { print n + 0 }' "$tmp_out")

printf 'sampled=%s blocked=%s lab_group=%s\n' "${#domains[@]}" "$blocked" "$lab_group"

empty=$(awk -F'\t' '$2 == "" { n++ } END { print n + 0 }' "$tmp_out")
[ "$empty" -eq 0 ] || {
	echo "$empty of ${#domains[@]} sampled domains got no report; first: $(awk -F'\t' '$2 == "" { print $1; exit }' "$tmp_out")" >&2
	exit 1
}

[ "$blocked" -eq "$sample" ] || {
	echo "expected $sample blocked reports, got $blocked; wrong server or sample?" >&2
	exit 1
}
[ "$lab_group" -gt 0 ] || {
	echo "no report came from the lab server (group=lab); wrong server?" >&2
	exit 1
}

mv "$tmp_out" "results/$variant$tag.reports.txt"
echo "ok: results/$variant$tag.reports.txt"
