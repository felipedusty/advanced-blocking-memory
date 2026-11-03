#!/usr/bin/env bash
# Store the records of one CI run of the `lab` workflow.
#
#   gh run download <run-id> -D /tmp/run-<run-id>
#   lab/ci-record.sh <run-id> /tmp/run-<run-id>
#
# Writes results/ci-compare/run-<run-id>.md (the tables of lab/ci-table.py) and results/ci-compare/run-<run-id>.tar.gz
# (the records of the amd64 and arm64 legs, one directory per leg). `tar xzf` the archive to run
# `python3 lab/compare-ci.py` or to read a leg's raw files.
set -euo pipefail
cd "$(dirname "$0")/.."
id=${1:?run id}
src=${2:?directory with the downloaded artifacts}
out=results/ci-compare
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/artifacts" "$stage/run-$id"
for d in "$src"/results-amd64-* "$src"/results-arm64-*; do
	[ -d "$d" ] || continue
	cp -r "$d" "$stage/artifacts/$(basename "$d")"
	cp -r "$d" "$stage/run-$id/$(basename "$d" | awk '{ sub(/^results-/, ""); print }')"
done
python3 lab/ci-table.py "$stage/artifacts" >"$out/run-$id.md"
tar czf "$out/run-$id.tar.gz" -C "$stage" "run-$id"
echo "$out/run-$id.md $out/run-$id.tar.gz"
