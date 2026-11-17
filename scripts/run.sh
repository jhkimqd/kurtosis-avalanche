#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
enclave=${ENCLAVE:-avalanche-$(date +%s)-$$}
[[ "$enclave" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { echo 'Invalid enclave name' >&2; exit 1; }
mkdir -p .build/locks
exec 9>".build/locks/$enclave.lock"
flock -n 9 || { echo "A deployment to $enclave is already running" >&2; exit 1; }
inventory=$(kurtosis enclave ls --full-uuids)
if ! [[ "$inventory" == *UUID* || "$inventory" == *'No enclaves'* ]]; then
    echo 'Cannot determine existing enclaves; refusing to deploy' >&2
    exit 1
fi
if awk -v name="$enclave" '$2 == name { found=1 } END { exit !found }' <<< "$inventory"; then
    echo "Enclave $enclave already exists; choose a fresh ENCLAVE" >&2
    exit 1
fi
kurtosis run --enclave "$enclave" . --args-file "${1:-examples/default.yml}"
