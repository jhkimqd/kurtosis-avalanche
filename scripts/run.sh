#!/usr/bin/env bash
# Start a devnet in a fresh enclave: bash scripts/run.sh [arguments-file] [main-file]
#
# ENCLAVE names the enclave; the default is a new unique name. The script
# refuses to deploy into an enclave that exists, because the tools keep the
# state of one deployment and must not replay it onto another.
set -euo pipefail
cd "$(dirname "$0")/.."
enclave=${ENCLAVE:-avalanche-$(date +%s)-$$}
[[ "$enclave" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { echo 'Invalid enclave name' >&2; exit 1; }
# Stop a second run for the same name. macOS has no flock; the check below
# for an existing enclave still applies there.
if command -v flock >/dev/null; then
    mkdir -p .build/locks
    exec 9>".build/locks/$enclave.lock"
    flock -n 9 || { echo "A deployment to $enclave is already running" >&2; exit 1; }
fi
inventory=$(kurtosis enclave ls --full-uuids)
if ! [[ "$inventory" == *UUID* || "$inventory" == *'No enclaves'* ]]; then
    echo 'Cannot determine existing enclaves; refusing to deploy' >&2
    exit 1
fi
if awk -v name="$enclave" '$2 == name { found=1 } END { exit !found }' <<< "$inventory"; then
    echo "Enclave $enclave already exists; choose a fresh ENCLAVE" >&2
    exit 1
fi
kurtosis run --enclave "$enclave" . --args-file "${1:-examples/pos.yml}" --main-file "${2:-main.star}"
