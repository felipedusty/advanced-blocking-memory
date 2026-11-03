#!/usr/bin/env bash
# Download the public block lists used by the production configuration.
#
# The Advanced Blocking app caches each list in
# <app>/blocklists/<sha256(url)>; the lab pre-seeds that cache so a run never
# depends on the network. No operational data is stored here.
set -euo pipefail
cd "$(dirname "$0")/.."

config=lab/config/${LAB_CONFIG:-dnsApp.config}
dest=lab/lists
mkdir -p "$dest"

urls_text=$(python3 - "$config" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1]))
seen = set()
for group in cfg["groups"]:
    for key in ("adblockListUrls", "allowListUrls", "blockListUrls"):
        for url in group.get(key, []):
            if isinstance(url, dict):
                url = url.get("url")
            if url and url.startswith(("http://", "https://", "file://")):
                seen.add(url)
for url in sorted(seen):
    print(url)
PY
)
if [ -z "$urls_text" ]; then
	echo "no list URLs found in $config" >&2
	exit 1
fi
mapfile -t urls <<<"$urls_text"

for url in "${urls[@]}"; do
	name=$(printf '%s' "$url" | sha256sum | cut -d' ' -f1)
	out="$dest/$name"
	if [ -s "$out" ]; then
		printf 'keep  %s (%s)\n' "$name" "$(du -h "$out" | cut -f1)"
		continue
	fi
	printf 'fetch %s\n' "$url"
	curl -fsSL --retry 3 --retry-delay 2 --max-time 600 "$url" -o "$out.tmp"
	mv "$out.tmp" "$out"
done

printf '\ntotal: %s across %s files\n' \
	"$(du -sh "$dest" | cut -f1)" \
	"$(ls -1 "$dest" | wc -l)"
