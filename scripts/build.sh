#!/usr/bin/env bash
# Optional developer prebuild. A normal kurtosis run builds this automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -t avalanche-tools:local tools
