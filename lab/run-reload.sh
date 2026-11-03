#!/usr/bin/env bash
# Measure the peak memory of a scheduled block list reload.
#
# Production never reloads (update interval 9999h), but the app default is 24h
# and an app update or a config save also rebuilds every list. During a rebuild
# the old set and the new set are both alive. This script forces that path with
# local file:// URLs (no network) and an update interval of one minute.
#
#   lab/run-reload.sh original
#   lab/run-reload.sh patched
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:-original}
PLATFORM=${PLATFORM:-}
tag=${RUN_TAG:-}
settle_s=${RELOAD_SETTLE_S:-10}
case "$settle_s" in
'' | *[!0-9]*)
	echo "RELOAD_SETTLE_S must be a non-negative integer" >&2
	exit 2
	;;
esac
settle_s=$((10#$settle_s))
if [ -z "$tag" ] && [ -n "${RELOAD_SETTLE_S:-}" ]; then
	echo "RELOAD_SETTLE_S needs a RUN_TAG: a different run must not overwrite results/reload-<variant>.json" >&2
	exit 2
fi
out=lab/.work/out-$variant
image=technitium/dns-server:15.6.2
[ -d "$out" ] || {
	echo "run lab/build-app.sh $variant first" >&2
	exit 1
}

# Same host-resolver refusal as run-lab.sh: the reload container is a second
# full copy of the lists.
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

# Build the reload config: same lists, file:// URLs, 1-minute update interval.
python3 - <<'PY'
import hashlib, json, os

cfg = json.load(open(f"lab/config/{os.environ.get('LAB_CONFIG', 'dnsApp.config')}"))
urls = sorted({u for g in cfg["groups"] for u in g.get("adblockListUrls", [])} |
              {u for g in cfg["groups"] for u in g.get("allowListUrls", [])})

lines = []
for i, url in enumerate(urls, 1):
    lines.append(f"{i:02d}\t{url}\t{hashlib.sha256(url.encode()).hexdigest()}")

open("lab/config/reload-map.tsv", "w").write("\n".join(lines) + "\n")

by_url = {url: f"file:///etc/dns/lists/{i:02d}.txt" for i, url in enumerate(urls, 1)}

for group in cfg["groups"]:
    group["adblockListUrls"] = [by_url[u] for u in group.get("adblockListUrls", [])]
    group["allowListUrls"] = [by_url[u] for u in group.get("allowListUrls", [])]

cfg["blockListUrlUpdateIntervalHours"] = 0
cfg["blockListUrlUpdateIntervalMinutes"] = 1

with open("lab/config/dnsApp.reload.config", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

expected=$(wc -l <lab/config/reload-map.tsv)

seed=$PWD/lab/.run/reload-$variant$tag/etc
if [ -d "$seed" ]; then
	docker run --rm ${PLATFORM:+--platform "$PLATFORM"} --entrypoint sh -v "$seed":/x "$image" -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 || true
fi
rm -rf "$seed"
mkdir -p "$seed/apps/Advanced Blocking/blocklists" "$seed/lists"
cp "$out"/AdvancedBlockingApp.dll "$out"/AdvancedBlockingApp.deps.json "$out"/TechnitiumLibrary.IO.dll "$seed/apps/Advanced Blocking/"
cp lab/config/dnsApp.reload.config "$seed/apps/Advanced Blocking/dnsApp.config"
while IFS=$'\t' read -r idx url sha; do
	[ -f "lab/lists/$sha" ] || {
		echo "missing lab/lists/$sha; run lab/fetch-lists.sh" >&2
		exit 1
	}
	cp "lab/lists/$sha" "$seed/lists/$idx.txt"
done <lab/config/reload-map.tsv

if docker inspect dns-lab >/dev/null 2>&1; then
	[ "$(docker inspect -f '{{index .Config.Labels "technitiumfix.lab"}}' dns-lab)" = "1" ] || {
		echo "a container named dns-lab exists without the lab label; refusing to remove it" >&2
		exit 1
	}
	docker rm -f dns-lab >/dev/null
fi
docker run -d ${PLATFORM:+--platform "$PLATFORM"} --name dns-lab \
	${MEM:+--memory "$MEM" --memory-swap "${MEMSWAP:-$MEM}"} \
	--label technitiumfix.lab=1 \
	-p 127.0.0.1:15353:53/udp \
	-p 127.0.0.1:15353:53/tcp \
	-p 127.0.0.1:15380:5380/tcp \
	-e DNS_SERVER_DOMAIN=lab.test \
	-e DNS_SERVER_ADMIN_PASSWORD=lab-only-password \
	-e DNS_SERVER_RECURSION=AllowOnlyForPrivateNetworks \
	-e DNS_SERVER_FORWARDERS=1.1.1.1 \
	-v "$seed":/etc/dns \
	"$image" >/dev/null

pid=$(docker inspect -f '{{.State.Pid}}' dns-lab)
cg=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")
root="/sys/fs/cgroup$cg"
[ -r "$root/memory.current" ] || {
	echo "cannot read cgroup memory for dns-lab" >&2
	exit 1
}

mkdir -p results
rm -f "results/reload-$variant$tag".{json,csv,log,stat,applog,state.txt}
csv=results/reload-$variant$tag.csv
: >"$csv"

start_ns=$(date +%s%N)
now_ms() { echo $((($(date +%s%N) - start_ns) / 1000000)); }
count_reads() {
	docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log 2>/dev/null' 2>/dev/null | grep -c "list file (" || true
}

phase=load
load_done_ms=""
reload_done_ms=""
touched=""
last_check=0
max_s=300
while :; do
	now=$(now_ms)
	[ "$now" -lt $((max_s * 1000)) ] || break
	echo "$now,$(cat "$root/memory.current")" >>"$csv"

	if [ "$now" -ge $((last_check + 1000)) ]; then
		last_check=$now
		if [ "$(docker inspect -f '{{.State.Running}}' dns-lab 2>/dev/null || true)" != "true" ]; then
			docker inspect -f 'oom_killed={{.State.OOMKilled}} exit_code={{.State.ExitCode}}' dns-lab >"results/reload-$variant$tag.state.txt" 2>/dev/null || true
			echo "the container exited before the window ended (state in results/reload-$variant$tag.state.txt)" >&2
			exit 1
		fi
		reads=$(count_reads)
		if [ "$phase" = load ] && [ "$reads" -ge "$expected" ]; then
			load_done_ms=$now
			phase=reload
			touched=$now
			echo "load done at ${now} ms; touching list files to force reload" >&2
			find "$seed/lists" -type f -exec touch {} +
		fi
		if [ "$phase" = reload ] && [ "$reads" -ge $((expected * 2)) ] && [ -z "$reload_done_ms" ]; then
			reload_done_ms=$now
			echo "reload done at ${now} ms; settling for ${settle_s}s" >&2
		fi
		if [ -n "$reload_done_ms" ] && [ "$now" -ge $((reload_done_ms + settle_s * 1000)) ]; then
			break
		fi
	fi

	if [ -n "$touched" ] && [ "$now" -gt $((touched + 240 * 1000)) ]; then
		echo "reload did not happen within 240 s" >&2
		break
	fi
	sleep 0.05
done

docker logs dns-lab >"results/reload-$variant$tag.log" 2>&1 || true
docker exec dns-lab sh -c 'cat /var/log/technitium/dns/*.log' >"results/reload-$variant$tag.applog" 2>/dev/null || true
rm -f "results/reload-$variant$tag.stat"
cat "$root/memory.stat" >"results/reload-$variant$tag.stat"
peak_cgroup=$(cat "$root/memory.peak")

read -r peak_bytes peak_ms <<<"$(awk -F, 'BEGIN{p=0; t=0} $2 > p {p=$2; t=$1} END{print p, t}' "$csv")"
read -r med_last <<<"$(tail -20 "$csv" | cut -d, -f2 | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')"
reads=$(count_reads)
[ "$reads" -ge $((expected * 2)) ] || {
	echo "reload did not complete: $reads of $((expected * 2)) reads" >&2
	exit 1
}
final=$(tail -1 "$csv" | cut -d, -f2)
duration=$(tail -1 "$csv" | cut -d, -f1)
if [ -z "$reload_done_ms" ]; then
	echo "reload did not complete within ${max_s}s" >&2
	exit 1
fi
if [ "$duration" -lt $((reload_done_ms + settle_s * 1000)) ]; then
	echo "window ended at ${duration} ms, before the reload (${reload_done_ms} ms) + ${settle_s}s settle; not recording a truncated run" >&2
	exit 1
fi

python3 - "$variant" "$tag" "$image" "$expected" "$reads" "$peak_bytes" "$peak_ms" \
	"$peak_cgroup" "$med_last" "$final" "${load_done_ms:-0}" "${reload_done_ms:-0}" \
	"$settle_s" "$duration" \
	"$(sha256sum "$out/AdvancedBlockingApp.dll" | cut -d' ' -f1)" <<'PY'
import json, os, sys

(variant, tag, image, expected, reads, peak_bytes, peak_ms, cgroup_peak,
 steady_median, final_bytes, load_done_ms, reload_done_ms, settle_s,
 duration, app_sha) = sys.argv[1:]

data = {
    "variant": variant,
    "run_tag": tag,
    "image": image,
    "app_sha256": app_sha,
    "memory_limit": os.environ.get("MEM") or "none",
    "memory_swap": os.environ.get("MEMSWAP") or os.environ.get("MEM") or "none",
    "lists_expected": int(expected),
    "list_reads_total": int(reads),
    "peak_bytes": int(peak_bytes),
    "peak_at_ms": int(peak_ms),
    "cgroup_memory_peak_bytes": int(cgroup_peak),
    "steady_median_bytes": int(steady_median),
    "final_bytes": int(final_bytes),
    "load_done_ms": int(load_done_ms),
    "reload_done_ms": int(reload_done_ms),
    "settle_s": int(settle_s),
    "window_ms": int(duration),
}
with open(f"results/reload-{variant}{tag}.json", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

printf '\nresults/reload-%s%s.json\n' "$variant" "$tag"
cat "results/reload-$variant$tag.json"
