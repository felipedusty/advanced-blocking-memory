#!/usr/bin/env bash
# Query latency during start-up and during a forced block list reload.
#
#   lab/stall-reload.sh original
#   lab/stall-reload.sh patched          # after lab/build-app.sh patched (any PATCH_DIR)
#
# Runs lab/run-reload.sh (the lists are loaded, then rebuilt from file:// URLs) and, from the
# moment the container answers, lab/stall-probe.py against a blocked name at RATE queries per
# second (default 200). Writes results/stall-<variant><tag>.json with the replies slower than
# THRESHOLD_MS (default 10) counted separately for the start-up window, the reload window and
# the rest, from the timing run-reload.sh records.
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:?original or patched}
tag=${RUN_TAG:--stall}
rate=${RATE:-200}
threshold=${THRESHOLD_MS:-10}
seconds=${PROBE_SECONDS:-100}
name=${PROBE_NAME:-doubleclick.net}

# The lab container of an earlier run is still up: remove it first, or the wait below would
# see it running and the probe would start against it with the wrong start time.
if docker inspect dns-lab >/dev/null 2>&1; then
	[ "$(docker inspect -f '{{index .Config.Labels "technitiumfix.lab"}}' dns-lab)" = "1" ] || {
		echo "a container named dns-lab exists without the lab label; refusing to remove it" >&2
		exit 1
	}
	docker rm -f dns-lab >/dev/null
fi

RUN_TAG=$tag lab/run-reload.sh "$variant" >"results/stall-$variant$tag.reload.log" 2>&1 &
reload_pid=$!

until [ "$(docker inspect -f '{{.State.Running}}' dns-lab 2>/dev/null || true)" = "true" ]; do
	kill -0 "$reload_pid" 2>/dev/null || { echo "run-reload.sh ended before the container started" >&2; exit 1; }
	sleep 0.2
done
python3 - "$name" <<'PY'
import socket, struct, sys, time
name = sys.argv[1]
q = struct.pack("!HHHHHH", 1, 0x0100, 1, 0, 0, 0) + b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack("!HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.3)
deadline = time.time() + 60
while time.time() < deadline:
    try:
        s.sendto(q, ("127.0.0.1", 15353))
        s.recv(2048)
        break
    except OSError:
        time.sleep(0.2)
else:
    sys.exit("the server did not answer within 60 s")
PY
started_at=$(docker inspect -f '{{.State.StartedAt}}' dns-lab)

# The server rate limits a client subnet to 600 UDP queries a minute ("Client subnet ... is being
# rate limited"), so a probe from the host at 200 qps is cut off after about 20 s and everything
# after that is a drop, not a pause. Inside the container's network namespace the probe talks to
# 127.0.0.1, as lab/exhaustive.py does, which is not limited.
docker run --rm --network container:dns-lab --user "$(id -u):$(id -g)" \
	-v "$PWD":/work -w /work python:3.13-slim \
	python3 lab/stall-probe.py 127.0.0.1 53 "$name" "$seconds" "$rate" "$threshold" "results/stall-$variant$tag.probe.json"
wait "$reload_pid" || { echo "run-reload.sh failed" >&2; exit 1; }

python3 - "$variant" "$tag" "$started_at" <<'PY'
import datetime, json, sys

variant, tag, started_at = sys.argv[1:4]
probe = json.load(open(f"results/stall-{variant}{tag}.probe.json"))
reload_ = json.load(open(f"results/reload-{variant}{tag}.json"))
start = datetime.datetime.fromisoformat(started_at.replace("Z", "+00:00").split(".")[0] + "+00:00").timestamp()
load_done = start + reload_["load_done_ms"] / 1000.0
reload_done = start + reload_["reload_done_ms"] / 1000.0

end = start + reload_["window_ms"] / 1000.0  # run-reload.sh removes the container after this

def window(t):
    if t < load_done:
        return "startup"
    if t < reload_done:
        return "reload"
    return "settle" if t < end else None

names = ("startup", "reload", "settle")
slow = {k: [] for k in names}
for t, rtt in probe["stalls"]:
    w = window(t)
    if w:
        slow[w].append(rtt)

bounds = {"startup": (start, load_done), "reload": (load_done, reload_done), "settle": (reload_done, end)}
queries = {k: 0 for k in names}
worst = {k: 0.0 for k in names}
for offset, (count, max_ms) in enumerate(probe["per_second"]):
    second = probe["first_second"] + offset
    for k, (lo, hi) in bounds.items():
        if lo <= second and second + 1 <= hi:
            queries[k] += count
            worst[k] = max(worst[k], max_ms)

data = {
    "variant": variant,
    "run_tag": tag,
    "app_sha256": reload_["app_sha256"],
    "rate": probe["rate"],
    "threshold_ms": probe["threshold_ms"],
    "windows_s": {k: round(hi - lo, 1) for k, (lo, hi) in bounds.items()},
    "queries": queries,
    "worst_reply_ms": worst,
    "slow_replies": {k: {"count": len(v), "max_ms": max(v) if v else 0.0, "over_50_ms": sum(1 for x in v if x >= 50), "over_100_ms": sum(1 for x in v if x >= 100)} for k, v in slow.items()},
}
json.dump(data, open(f"results/stall-{variant}{tag}.json", "w"), indent=2)
print(json.dumps(data, indent=2))
PY
