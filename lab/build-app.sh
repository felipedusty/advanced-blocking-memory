#!/usr/bin/env bash
# Build the Advanced Blocking app from the pinned upstream commit.
#
#   lab/build-app.sh            # baseline (upstream code)
#   lab/build-app.sh patched    # applies patch/hash128/*.patch first (the 128-bit hash-set patch)
#   PATCH_DIR=patch/hash64 lab/build-app.sh patched   # the 64-bit hash set
#   PATCH_DIR=patch/exact lab/build-app.sh patched    # the exact DomainSet alternative
#
# Follows upstream build.md: TechnitiumLibrary and DnsServer as sibling clones;
# the app project references TechnitiumLibrary DLLs by relative path. Only the
# app assembly is rebuilt; the server image stays the official release.
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:-original}
case "$variant" in
original | patched) ;;
*)
	echo "usage: $0 [original|patched]" >&2
	exit 2
	;;
esac

# Pinned upstream master commit (develop 5ed3d47 is the other merge target).
# Override with UPSTREAM_PIN to build another commit.
pin=${UPSTREAM_PIN:-0dd592a}
[ -n "$pin" ] || {
	echo "cannot read the pinned commit" >&2
	exit 1
}

work=$PWD/lab/.work
src=$work/DnsServer
mkdir -p "$work"
stray=$(find "$work" -maxdepth 5 ! -user "$(id -u)" -print -quit)
[ -z "$stray" ] || {
	echo "lab/.work has files from another user (an earlier root build): $stray" >&2
	echo "run: sudo chown -R $(id -u):$(id -g) lab/.work" >&2
	exit 1
}

techpin=4a5a530ac6c4114e72216e0b9c74208a7a5e3fa0
[ -d "$work/TechnitiumLibrary/.git" ] ||
	git clone --depth 1 -q https://github.com/TechnitiumSoftware/TechnitiumLibrary.git "$work/TechnitiumLibrary"
[ -d "$src/.git" ] ||
	git clone --depth 1 -q https://github.com/TechnitiumSoftware/DnsServer.git "$src"

git -C "$work/TechnitiumLibrary" fetch -q --depth 1 origin "$techpin" 2>/dev/null || true
git -C "$work/TechnitiumLibrary" checkout -q "$techpin"
git -C "$src" fetch -q --depth 1 origin "$pin" 2>/dev/null || true
git -C "$src" checkout -q "$pin"
git -C "$src" reset -q --hard "$pin"

if [ "$variant" != original ]; then
	shopt -s nullglob
	patches=("$PWD/${PATCH_DIR:-patch/hash128}"/*.patch)
	shopt -u nullglob
	[ ${#patches[@]} -gt 0 ] || {
		echo "no patch found for $variant in ${PATCH_DIR:-patch/hash128}" >&2
		exit 1
	}
	for p in "${patches[@]}"; do
		echo "apply $p"
		git -C "$src" apply "$p"
	done
fi

docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e TECHPIN="$techpin" \
	-v "$work":/src -w /src mcr.microsoft.com/dotnet/sdk:10.0 bash -lc '
	set -e
	pin_file=TechnitiumLibrary/.built-techpin
	if [ ! -f TechnitiumLibrary/bin/TechnitiumLibrary.Net.dll ] ||
		[ "$(cat "$pin_file" 2>/dev/null)" != "$TECHPIN" ]; then
		dotnet build TechnitiumLibrary/TechnitiumLibrary.ByteTree/TechnitiumLibrary.ByteTree.csproj -c Release -v q
		dotnet build TechnitiumLibrary/TechnitiumLibrary.Net/TechnitiumLibrary.Net.csproj -c Release -v q
		dotnet build TechnitiumLibrary/TechnitiumLibrary.Security.OTP/TechnitiumLibrary.Security.OTP.csproj -c Release -v q
		printf "%s\n" "$TECHPIN" > "$pin_file"
	fi
	dotnet build DnsServer/Apps/AdvancedBlockingApp/AdvancedBlockingApp.csproj -c Release -v q
'

out=$work/out-$variant
rm -rf "$out"
mkdir -p "$out"
cp -a "$src"/Apps/AdvancedBlockingApp/bin/Release/. "$out"/
rm -f "$out"/*.pdb

printf '\n%s: %s\n' "$variant" "$out"
sha256sum "$out/AdvancedBlockingApp.dll"
printf 'size: %s bytes\n' "$(stat -c %s "$out/AdvancedBlockingApp.dll")"
