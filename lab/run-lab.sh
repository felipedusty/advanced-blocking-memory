#!/usr/bin/env bash
# Run one variant in a fresh container and record the memory curve.
#
#   lab/run-lab.sh original
#   lab/run-lab.sh patched
#
# The container has no memory limit by default, so the figures describe the software and not one deployment.
# The same server image, the same public lists and the same app config. MEM and MEMSWAP set a limit (for
# example MEM=320m for the small-container checks) and GRACE_S the settle time for the correctness-only
# pass. The only difference between runs is the Advanced
# Blocking assembly. Leaves the container running for lab/check-function.sh;
# remove it with:
#   docker rm -f dns-lab
# EXTRA_DOCKER_ARGS adds docker run arguments (for example -e DOTNET_GCConserveMemory=7).
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:-original}
PLATFORM=${PLATFORM:-}
case "$variant" in
original | patched) ;;
*)
	echo "usage: $0 [original|patched]" >&2
	exit 2
	;;
esac

tag=${RUN_TAG:-}
grace_s=${GRACE_S:-20}
case "$grace_s" in
'' | *[!0-9]*)
	echo "GRACE_S must be a non-negative integer" >&2
	exit 2
	;;
esac
grace_s=$((10#$grace_s))
app_config=${APP_CONFIG:-lab/config/dnsApp.config}
recursion=${RECURSION:-AllowOnlyForPrivateNetworks}
forwarders=${FORWARDERS:-1.1.1.1}
edge=${EDGE:-0}
case "$edge" in
0 | 1) ;;
*)
	echo "EDGE must be 0 or 1" >&2
	exit 2
	;;
esac
if [ -n "${MEM:-}" ]; then
	memory=$MEM
	memory_swap=${MEMSWAP:-$MEM}
	limit_args=(--memory "$memory" --memory-swap "$memory_swap")
else
	memory=none
	memory_swap=none
	limit_args=()
fi

if [ -z "$tag" ] && {
	[ -n "${MEM:-}" ] || [ -n "${MEMSWAP:-}" ] || [ -n "${GRACE_S:-}" ] ||
		[ -n "${APP_CONFIG:-}" ] || [ -n "${FORWARDERS:-}" ] ||
		[ -n "${RECURSION:-}" ] || [ -n "${EXTRA_DOCKER_ARGS:-}" ] || [ "$edge" != "0" ]
}; then
	echo "MEM, MEMSWAP, GRACE_S, APP_CONFIG, FORWARDERS, RECURSION, EXTRA_DOCKER_ARGS and EDGE need a RUN_TAG: a different run must not overwrite results/<variant>.json" >&2
	exit 2
fi

out=lab/.work/out-$variant
image=technitium/dns-server:15.6.2

[ -d "$out" ] || {
	echo "run lab/build-app.sh $variant first" >&2
	exit 1
}
[ -n "$(ls -A lab/lists 2>/dev/null)" ] || {
	echo "run lab/fetch-lists.sh first" >&2
	exit 1
}

# The lab container costs several hundred MiB, and on a small host running a resolver that pressure can take
# the resolver down. Refuse to start next to a host resolver unless the operator says otherwise.
if [ "${LAB_ALLOW_HOST_DNS:-0}" != "1" ]; then
	command -v ss >/dev/null 2>&1 || {
		echo "ss (iproute2) is needed to check for a host resolver; set LAB_ALLOW_HOST_DNS=1 to skip the check" >&2
		exit 1
	}
	# Only the wildcard and loopback binds are conflicts: that is what a
	# published container port and a local resolver use. WSL's proxy on a
	# specific address and the 127.0.0.53 stub are not.
	if ! ss_out=$(ss -lunH 'sport = :53'); then
		echo "ss failed to list UDP/53 listeners" >&2
		exit 1
	fi
	host_dns=$(printf '%s\n' "$ss_out" | awk '$4 == "*:53" || $4 == "0.0.0.0:53" || $4 == "[::]:53" || $4 == "127.0.0.1:53" || $4 == "[::1]:53"')
	if [ -n "$host_dns" ]; then
		echo "UDP port 53 is already in use on this host:" >&2
		echo "$host_dns" >&2
		echo "set LAB_ALLOW_HOST_DNS=1 only if the lab may run next to that resolver" >&2
		exit 1
	fi
fi
docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image"

expected=$(python3 - "$app_config" "$edge" <<'PY'
import hashlib, json, os, sys

cfg = json.load(open(sys.argv[1]))
edge = sys.argv[2] == "1"
seen = set()
for group in cfg["groups"]:
    for key in ("adblockListUrls", "allowListUrls", "blockListUrls", "regexAllowListUrls", "regexBlockListUrls"):
        for url in group.get(key, []):
            if isinstance(url, dict):
                url = url.get("url")
            if url:
                seen.add(url)

if not edge:
    missing = [
        url
        for url in sorted(seen)
        if url.startswith("http")
        and not os.path.exists(os.path.join("lab/lists", hashlib.sha256(url.encode()).hexdigest()))
    ]
    if missing:
        print("missing list files; run lab/fetch-lists.sh:", *missing[:3], file=sys.stderr)
        sys.exit(1)

print(len(seen))
PY
)

seed=$PWD/lab/.run/$variant$tag/etc
if [ -d "$seed" ]; then
	# the server runs as root in the container, so its files are root-owned
	docker run --rm ${PLATFORM:+--platform "$PLATFORM"} --entrypoint sh -v "$seed":/x "$image" -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 || true
fi
rm -rf "$seed"
mkdir -p "$seed/apps/Advanced Blocking/blocklists"
cp "$out"/AdvancedBlockingApp.dll "$out"/AdvancedBlockingApp.deps.json "$out"/TechnitiumLibrary.IO.dll "$seed/apps/Advanced Blocking/"
cp "$app_config" "$seed/apps/Advanced Blocking/dnsApp.config"
if [ "$edge" = 1 ]; then
	mkdir -p "$seed/edge"
	cp lab/edge/* "$seed/edge/"
else
	cp lab/lists/* "$seed/apps/Advanced Blocking/blocklists/"
fi

if docker inspect dns-lab >/dev/null 2>&1; then
	[ "$(docker inspect -f '{{index .Config.Labels "technitiumfix.lab"}}' dns-lab)" = "1" ] || {
		echo "a container named dns-lab exists without the lab label; refusing to remove it" >&2
		exit 1
	}
	docker rm -f dns-lab >/dev/null
fi
docker run -d ${PLATFORM:+--platform "$PLATFORM"} --name dns-lab \
	"${limit_args[@]}" \
	--label technitiumfix.lab=1 \
	--label "technitiumfix.variant=$variant" \
	--label "technitiumfix.tag=$tag" \
	--label "technitiumfix.app_sha256=$(sha256sum "$out/AdvancedBlockingApp.dll" | cut -d' ' -f1)" \
	--label "technitiumfix.memory_limit=$memory" \
	--label "technitiumfix.memory_swap=$memory_swap" \
	--label "technitiumfix.app_config=$app_config" \
	--label "technitiumfix.edge=$edge" \
	-p 127.0.0.1:15353:53/udp \
	-p 127.0.0.1:15353:53/tcp \
	-p 127.0.0.1:15380:5380/tcp \
	-e DNS_SERVER_DOMAIN=lab.test \
	-e DNS_SERVER_ADMIN_PASSWORD=lab-only-password \
	-e DNS_SERVER_RECURSION="$recursion" \
	-e DNS_SERVER_FORWARDERS="$forwarders" \
	-v "$seed":/etc/dns \
	${EXTRA_DOCKER_ARGS:-} \
	"$image" >/dev/null

pid=$(docker inspect -f '{{.State.Pid}}' dns-lab)
cg=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")
root="/sys/fs/cgroup$cg"
if [ ! -r "$root/memory.current" ]; then
	echo "cannot read cgroup memory for dns-lab (pid $pid, $root)" >&2
	exit 1
fi

mkdir -p results
rm -f "results/$variant$tag".{json,csv,log,stat,applog,state.txt}
csv=results/$variant$tag.csv
: >"$csv"

start_ns=$(date +%s%N)
now_ms() { echo $((($(date +%s%N) - start_ns) / 1000000)); }

ready_ms=""
last_check=0
max_s=${LISTS_TIMEOUT:-180}
while :; do
	now=$(now_ms)
	[ "$now" -lt $((max_s * 1000)) ] || break
	echo "$now,$(cat "$root/memory.current")" >>"$csv"

	if [ "$now" -ge $((last_check + 1000)) ]; then
		last_check=$now
		if [ "$(docker inspect -f '{{.State.Running}}' dns-lab 2>/dev/null || true)" != "true" ]; then
			docker inspect -f 'oom_killed={{.State.OOMKilled}} exit_code={{.State.ExitCode}}' dns-lab >"results/$variant$tag.state.txt" 2>/dev/null || true
			echo "the container exited before the window ended (state in results/$variant$tag.state.txt)" >&2
			exit 1
		fi
		loaded=$(docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log 2>/dev/null' 2>/dev/null | grep -c "list file (" || true)
		if [ "$loaded" -ge "$expected" ] && [ -z "$ready_ms" ]; then
			ready_ms=$now
			echo "all $expected lists parsed at ${now} ms" >&2
		fi
	fi

	if [ -n "$ready_ms" ] && [ "$now" -ge $((ready_ms + grace_s * 1000)) ]; then
		break
	fi
	sleep 0.05
done

if [ -z "$ready_ms" ]; then
	echo "lists not parsed within ${max_s}s" >&2
	exit 1
fi

docker logs dns-lab >"results/$variant$tag.log" 2>&1 || true
rm -f "results/$variant$tag.stat"
cat "$root/memory.stat" >"results/$variant$tag.stat"
peak_cgroup=$(cat "$root/memory.peak")

read -r peak_bytes peak_ms <<EOF
$(awk -F, 'BEGIN{p=0; t=0} $2 > p {p=$2; t=$1} END{print p, t}' "$csv")
EOF
read -r med_last <<EOF
$(tail -20 "$csv" | cut -d, -f2 | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
EOF
final=$(tail -1 "$csv" | cut -d, -f2)
duration=$(tail -1 "$csv" | cut -d, -f1)
if [ "$duration" -lt $((ready_ms + grace_s * 1000)) ]; then
	echo "window ended at ${duration} ms, before ready (${ready_ms} ms) + ${grace_s}s settle; not recording a truncated run" >&2
	exit 1
fi
anon=$(awk '$1 == "anon" { print $2 }' "results/$variant$tag.stat")
file=$(awk '$1 == "file" { print $2 }' "results/$variant$tag.stat")
loaded=$(docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log 2>/dev/null' 2>/dev/null | grep -c "list file (" || true)
docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log 2>/dev/null' >"results/$variant$tag.applog" 2>/dev/null || true
dll_sha=$(sha256sum "$out/AdvancedBlockingApp.dll" | cut -d' ' -f1)

python3 - "$variant" "$tag" "$image" "$dll_sha" "$expected" "$loaded" \
	"$peak_bytes" "$peak_ms" "$peak_cgroup" "$med_last" "$final" \
	"$anon" "$file" "${ready_ms:-0}" "$duration" "$memory" "$memory_swap" \
	"$grace_s" <<'PY'
import json, sys

(variant, tag, image, dll_sha, expected, loaded, peak_bytes, peak_ms,
 cgroup_peak, steady_median, final_bytes, anon, file_bytes, ready_ms,
 duration, memory_limit, memory_swap, grace_s) = sys.argv[1:]

data = {
    "variant": variant,
    "run_tag": tag,
    "image": image,
    "memory_limit": memory_limit,
    "memory_swap": memory_swap,
    "grace_s": int(grace_s),
    "app_sha256": dll_sha,
    "lists_expected": int(expected),
    "lists_parsed": int(loaded),
    "peak_bytes": int(peak_bytes),
    "peak_at_ms": int(peak_ms),
    "cgroup_memory_peak_bytes": int(cgroup_peak),
    "steady_median_bytes": int(steady_median),
    "final_bytes": int(final_bytes),
    "anon_bytes": int(anon),
    "file_bytes": int(file_bytes),
    "all_lists_parsed_at_ms": int(ready_ms),
    "window_ms": int(duration),
}
with open(f"results/{variant}{tag}.json", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

printf '\nresults/%s%s.json\n' "$variant" "$tag"
cat "results/$variant$tag.json"
printf 'container left running: dns-lab (DNS on 127.0.0.1:15353)\n'
