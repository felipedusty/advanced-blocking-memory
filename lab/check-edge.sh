#!/usr/bin/env bash
# Edge-case behaviour check for the synthetic edge config.
#
# Covers hosts format, plain allow list, adblock ^$all vs ^$third-party,
# @@ allow rules, allow-list precedence over an adblock block, a subdomain of a
# listed name, the case behaviour of both parsers, and regex.
#
#   RUN_TAG=-edge APP_CONFIG=lab/config/dnsApp.edge.config EDGE=1 \
#     FORWARDERS=127.0.0.1:5353 lab/run-lab.sh original
#   docker run -d --rm --name null-upstream --network container:dns-lab \
#     --user "$(id -u):$(id -g)" -v "$PWD":/work -w /work \
#     python:3.13-slim python3 lab/null-upstream.py
#   RUN_TAG=-edge lab/check-edge.sh original
#   docker rm -f null-upstream
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:?usage: check-edge.sh <variant>}
tag=${RUN_TAG:-}

domains=(
	edge-hosts.example.com
	edge-hosts2.example.com
	edge-adblock.example.com
	edge-all.example.com
	edge-third.example.com
	edge-adblock-allowed.example.com
	edge-allowed.example.com
	edge-both.example.com
	edge-regex.example.com
	edge-unknown.example.com
	edge-static.example.com
	edge-static-allowed.example.com
	sub.edge-hosts.example.com
	edge-upper-hosts.example.com
	edge-upper-adblock.example.com
	a.bc
	m.nz
	z.zz
	sub.m.nz
	0.zz
	a.bcd
)

docker inspect dns-lab >/dev/null 2>&1 || {
	echo "dns-lab is not running" >&2
	exit 1
}

have_variant=$(docker inspect -f '{{index .Config.Labels "technitiumfix.variant"}}' dns-lab)
have_tag=$(docker inspect -f '{{index .Config.Labels "technitiumfix.tag"}}' dns-lab)
have_edge=$(docker inspect -f '{{index .Config.Labels "technitiumfix.edge"}}' dns-lab)
[ "$have_variant" = "$variant" ] || {
	echo "dns-lab serves variant $have_variant, not $variant" >&2
	exit 1
}
[ "$have_tag" = "$tag" ] || {
	echo "dns-lab was started with RUN_TAG $have_tag, not $tag" >&2
	exit 1
}
[ "$have_edge" = "1" ] || {
	echo "dns-lab was not started with EDGE=1" >&2
	exit 1
}

mkdir -p results
out="results/$variant$tag.edge.txt"
rm -f "$out"
tmp_out=$(mktemp)
trap 'rm -f "$tmp_out"' EXIT
for domain in "${domains[@]}"; do
	report=$(docker exec dns-lab dig +short @127.0.0.1 TXT "$domain" 2>/dev/null | tr '\n' ' ' || true)
	printf '%s\t%s\n' "$domain" "$report" >>"$tmp_out"
done

blocked=$(awk -F'\t' '$2 ~ /source=advanced-blocking-app/ { n++ } END { print n + 0 }' "$tmp_out")
group=$(awk -F'\t' '$2 ~ /group=edge/ { n++ } END { print n + 0 }' "$tmp_out")

printf 'edge blocked=%s group=%s\n' "$blocked" "$group"

blocked_names="edge-hosts.example.com edge-hosts2.example.com edge-adblock.example.com edge-all.example.com edge-regex.example.com edge-static.example.com sub.edge-hosts.example.com edge-upper-hosts.example.com a.bc m.nz z.zz sub.m.nz"
allowed_names="edge-third.example.com edge-adblock-allowed.example.com edge-allowed.example.com edge-both.example.com edge-unknown.example.com edge-static-allowed.example.com edge-upper-adblock.example.com 0.zz a.bcd"
fail=0
while IFS=$'\t' read -r domain report; do
	case " $blocked_names " in
	*" $domain "*)
		[ -n "$report" ] || {
			echo "expected a blocked report for $domain" >&2
			fail=1
		}
		;;
	esac
	case " $allowed_names " in
	*" $domain "*)
		[ -z "$report" ] || {
			echo "expected no report for $domain, got: $report" >&2
			fail=1
		}
		;;
	esac
done <"$tmp_out"
[ "$fail" -eq 0 ] || exit 1

# The uppercase adblock entry can only be checked positively through the
# parser's count: the app read the fixture as 6 domains (5 blocked + 1 allow).
parsed=$(docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log 2>/dev/null' | grep -c 'read adblock list file (6 domains) from: file:///etc/dns/edge/adblock.txt' || true)
[ "$parsed" -eq 1 ] || {
	echo "the app did not read the adblock fixture as 6 domains (got $parsed)" >&2
	exit 1
}

# Same idea for the hosts list: the duplicate line and the uppercase entry are
# only visible in the raw count (6 lines, 2 of them duplicates or case-folded). A candidate that fills a set while
# parsing (hash64-set) logs the number of distinct names, 5.
hosts_parsed=$(docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log 2>/dev/null' | grep -c -E 'read block list file \((5|6) domains\) from: file:///etc/dns/edge/block-hosts.txt' || true)
[ "$hosts_parsed" -eq 1 ] || {
	echo "the app did not read the hosts fixture as 6 domains (got $hosts_parsed)" >&2
	exit 1
}

# The dense list has 17,576 names of 4 characters: its file size over 8 is below the number of
# names, so a candidate that sizes a list from the file size must still grow it when the guess
# is short, and keep every name.
dense_parsed=$(docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log 2>/dev/null' | grep -c 'read block list file (17576 domains) from: file:///etc/dns/edge/dense-short.txt' || true)
[ "$dense_parsed" -eq 1 ] || {
	echo "the app did not read the dense fixture as 17576 domains (got $dense_parsed)" >&2
	exit 1
}

[ "$blocked" -eq 12 ] || {
	echo "expected 12 blocked edge domains, got $blocked" >&2
	exit 1
}
[ "$group" -eq 12 ] || {
	echo "expected 12 reports from group=edge, got $group" >&2
	exit 1
}

# The allowed names only mean "allowed" while the app forwards to the null
# upstream: an unlisted name must end in NXDOMAIN from it, not SERVFAIL or a
# timeout. A missing upstream would make every unlisted name SERVFAIL, hiding
# a forwarding break.
unlisted_rcode=$(docker exec dns-lab dig +noall +comments +time=2 +tries=2 @127.0.0.1 TXT edge-unlisted.example.com 2>/dev/null | awk '/status:/ { print $6 }' | tr -d ',')
[ "$unlisted_rcode" = "NXDOMAIN" ] || {
	echo "unlisted name status ${unlisted_rcode:-none}, not NXDOMAIN: is null-upstream answering?" >&2
	exit 1
}

mv "$tmp_out" "$out"
echo "ok: $out"
