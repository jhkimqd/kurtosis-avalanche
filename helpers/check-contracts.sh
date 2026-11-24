#!/usr/bin/env bash
# Rebuild in Docker; default check never updates the checkout. Refresh is explicit.
set -euo pipefail
mode=${1:-check}
if [[ $# -gt 1 || ( "$mode" != check && "$mode" != refresh ) ]]; then
    echo "Usage: $0 [check|refresh]" >&2
    exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A small, fresh context excludes ignored caches and unrelated working-tree data.
mkdir -p "$work/context/contracts" "$work/context/helpers" "$work/rebuilt"
cp "$root/contracts/Dockerfile" "$work/context/contracts/"
cp "$root/contracts/foundry.toml" "$work/context/contracts/"
cp -R "$root/contracts/src" "$work/context/contracts/"
cp "$root/helpers/export-contracts.py" "$work/context/helpers/"
docker build --iidfile "$work/image" -f "$work/context/contracts/Dockerfile" "$work/context"
docker run --rm "$(<"$work/image")" | tar -xf - -C "$work/rebuilt"
if [[ "$mode" == check ]]; then
    if ! diff -qr "$root/static_files/contracts" "$work/rebuilt"; then
        echo 'Contract artifacts differ; inspect the source changes, then run helpers/check-contracts.sh refresh.' >&2
        exit 1
    fi
    echo 'Verified all contract artifacts and hashes.json against the pinned source build.'
else
    cp "$work/rebuilt/"*.json "$root/static_files/contracts/"
    echo 'Refreshed all contract artifacts and hashes.json; review the diff before committing.'
fi
