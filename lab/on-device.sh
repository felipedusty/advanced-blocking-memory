#!/usr/bin/env bash
# Run the original and prebuilt candidates on a real single-board computer, with no container memory limit.
#
#   lab/on-device.sh <name>=<dir> [<name>=<dir> ...]
#
# Each <dir> holds a prebuilt candidate (AdvancedBlockingApp.dll, .deps.json, TechnitiumLibrary.IO.dll), for
# example the out-patched directory of `PATCH_DIR=patch/experiments/hash64-set lab/build-app.sh patched` built
# on another machine (the assemblies are architecture neutral). The original is lab/.work/out-original.
# Needs docker, python3, ss and lab/lists on the board, and the host is expected to be otherwise idle.
#
# The serving container (SERVING, default dns-server) and the watchdog timer (WATCHDOG, default
# technitium-dns-watchdog.timer) are stopped for the run and stay stopped: the board is then free for the lab
# (it stops being a resolver), and starting them again is a decision of the operator:
#   docker start dns-server && systemctl start technitium-dns-watchdog.timer
# lab/on-device-guard.sh removes the lab container when the host starts to thrash (see its header).
# The original is not queried for the 500 TXT reports (ORIGINAL_CHECK=0, the default here): on a 1 GiB board
# that pass drove the host into swap; a guard that looked at MemAvailable and swap growth tripped in time once and
# missed once, and the SoC watchdog reset the board (2026-11-03). The latency client takes its names from the
# first candidate's reports; the responses of the original and the candidates are compared on the CI legs and
# locally, not on the board.
set -uo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: $0 <name>=<dir> ..." >&2; exit 2; }
serving=${SERVING:-dns-server}
watchdog=${WATCHDOG:-technitium-dns-watchdog.timer}
out=${OUT:-$PWD/results/session-device}
log=$PWD/on-device.log
mkdir -p "$out"
say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$log"; }

guard_pid=
cleanup() {
	kill "$guard_pid" 2>/dev/null || true
	docker rm -f dns-lab >/dev/null 2>&1 || true
	say "cleanup: $serving $(docker inspect -f '{{.State.Status}}' "$serving") (left stopped), $watchdog $(systemctl is-active "$watchdog")"
}
trap cleanup EXIT

say "host: $(uname -m) $(awk '/MemTotal/ { print int($2 / 1024) " MiB" }' /proc/meminfo), $(nproc) cores, kernel $(uname -r)"
systemctl stop "$watchdog"
docker stop "$serving" >/dev/null
say "$serving and $watchdog stopped; MemAvailable $(awk '/MemAvailable/ { print int($2 / 1024) " MiB" }' /proc/meminfo)"
lab/on-device-guard.sh "$PWD/on-device-guard.log" &
guard_pid=$!

export PREBUILT=1 OUT=$out ORIGINAL_CHECK=${ORIGINAL_CHECK:-0}
say "== original (start)"
lab/session-bench.sh start >>"$log" 2>&1
for c in "$@"; do
	say "== ${c%%=*}"
	lab/session-bench.sh cand "${c%%=*}" "${c#*=}" >>"$log" 2>&1
done
say "== original (end)"
lab/session-bench.sh end >>"$log" 2>&1
python3 lab/session-table.py "$out" >>"$log" 2>&1
say "done; results in $out"
