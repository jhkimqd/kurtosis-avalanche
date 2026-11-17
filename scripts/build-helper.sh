#!/usr/bin/env bash
# Compatibility entrypoint: use the single pinned build workflow.
set -euo pipefail
exec bash "$(dirname "$0")/build.sh"
