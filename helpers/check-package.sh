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
plan_profile() {
    local profile=$1 entrypoint=${2:-main.star}
    echo "Planning $profile with $entrypoint"
    kurtosis run --dry-run --enclave "$enclave" . --args-file "$profile" --main-file "$entrypoint" 2>&1 | tee "$log"
    # Kurtosis 1.18.2 reports interpretation errors with exit status zero.
    if [[ $(<"$log") == *'Error encountered running Starlark code in dry-run mode.'* ]]; then
        echo "Package planning failed for $profile" >&2
        return 1
    fi
}
for profile in examples/*.yml .github/configs/*.yml; do
    plan_profile "$profile"
done
plan_profile .github/configs/two-l1s.yml nightly.star
