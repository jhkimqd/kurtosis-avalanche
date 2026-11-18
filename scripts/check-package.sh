#!/usr/bin/env bash
# Lint the package and plan every arguments file with the real Starlark
# interpreter. A dry run starts no service. Kurtosis still pulls the images
# and builds the tools image; the Docker cache makes that fast after the first
# time.
set -euo pipefail
cd "$(dirname "$0")/.."
kurtosis lint .
enclave="avax-check-$(date +%s)-$$"
log=$(mktemp)
trap 'rm -f "$log"; kurtosis enclave rm -f "$enclave" >/dev/null' EXIT
for profile in examples/*.yml .github/configs/*.yml; do
    echo "Planning $profile"
    kurtosis run --dry-run --enclave "$enclave" . --args-file "$profile" 2>&1 | tee "$log"
    # Kurtosis 1.18.2 reports interpretation errors with exit status zero.
    if [[ $(<"$log") == *'Error encountered running Starlark code in dry-run mode.'* ]]; then
        echo "Package planning failed for $profile" >&2
        exit 1
    fi
done
