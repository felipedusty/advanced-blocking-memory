#!/usr/bin/env bash
# Stop condition of lab/on-device.sh: remove the lab container when the host starts to thrash. A board with a
# little RAM and its swap on an SD card freezes in paging while MemAvailable still shows over 100 MiB, and the
# amount of swap in use says nothing (the kernel moves idle pages of other containers to swap without traffic),
# so the guard looks at two signals, read every second:
#   MemAvailable under MIN_AVAIL_MIB (default 100);
#   swap traffic (pswpin + pswpout from /proc/vmstat) above MAX_SWAP_PAGES_S pages per second (default 1000,
#   about 4 MiB/s) in two consecutive seconds. On the board it was 0 in every one of 925 seconds of a
#   healthy run.
# Usage: lab/on-device-guard.sh <log>   (runs until killed; one line per second goes to <log>.samples)
log=${1:?log file}
min_avail_mib=${MIN_AVAIL_MIB:-100}
max_swap_pages_s=${MAX_SWAP_PAGES_S:-1000}
swap_used() { awk '/SwapTotal/ { t = $2 } /SwapFree/ { f = $2 } END { print int((t - f) / 1024) }' /proc/meminfo; }
swap_pages() { awk '/^pswpin / { i = $2 } /^pswpout / { o = $2 } END { print i + o }' /proc/vmstat; }
printf '%s guard start: trip at MemAvailable < %s MiB or swap traffic > %s pages/s for 2 s\n' \
	"$(date -u +%FT%TZ)" "$min_avail_mib" "$max_swap_pages_s" >>"$log"
prev=$(swap_pages)
hot=0
while :; do
	sleep 1
	avail=$(awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo)
	swap=$(swap_used)
	now=$(swap_pages)
	rate=$((now - prev))
	prev=$now
	[ "$rate" -gt "$max_swap_pages_s" ] && hot=$((hot + 1)) || hot=0
	printf '%s avail=%s swap=%s swap_pages_s=%s\n' "$(date -u +%FT%TZ)" "$avail" "$swap" "$rate" >>"$log.samples"
	if [ "$avail" -lt "$min_avail_mib" ] || [ "$hot" -ge 2 ]; then
		printf '%s GUARD TRIPPED avail=%s MiB swap=%s MiB swap_pages_s=%s: removing dns-lab\n' \
			"$(date -u +%FT%TZ)" "$avail" "$swap" "$rate" >>"$log"
		docker rm -f dns-lab >/dev/null 2>&1
		hot=0
		sleep 5
		prev=$(swap_pages)
	fi
done
