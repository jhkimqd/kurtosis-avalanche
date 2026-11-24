#!/usr/bin/env bash
# Check the Alloy pipelines in static_files/observability/alloy with the
# pinned Alloy image: format, syntax, and a real start.
#
# The start matters. `alloy validate` accepts a pipeline that Alloy then
# refuses to load, for example a scrape timeout above the scrape interval.
# It needs Docker.
set -euo pipefail
cd "$(dirname "$0")/.."
pipelines=$PWD/static_files/observability/alloy
image=$(grep -o 'grafana/alloy@sha256:[0-9a-f]\{64\}' src/config/constants.star)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The pipelines read their targets from files that the package renders. Give
# each of them an empty list, as the package does for a job without services.
mkdir "$work/targets"
grep -oh '/etc/alloy-targets/[a-z-]*\.json' "$pipelines"/*.alloy | sort -u | while read -r file; do
    echo '[]' >"$work/targets/${file##*/}"
done
chmod -R a+rX "$work"
alloy() {
    docker run --rm \
        -e PROMETHEUS_REMOTE_WRITE_URL=http://prometheus:9090/api/v1/write \
        -e LOKI_PUSH_URL=http://loki:3100/loki/api/v1/push \
        -v "$pipelines:/etc/alloy:ro" -v "$work/targets:/etc/alloy-targets:ro" "$image" "$@"
}
for file in "$pipelines"/*.alloy; do
    echo "Checking the format of ${file##*/}"
    alloy fmt --test "/etc/alloy/${file##*/}"
done
echo "Validating the pipelines"
alloy validate /etc/alloy
echo "Starting Alloy for 10 seconds"
# A healthy Alloy runs until `timeout` stops it (status 124).
status=0
timeout 10 docker run --rm \
    -e PROMETHEUS_REMOTE_WRITE_URL=http://prometheus:9090/api/v1/write \
    -e LOKI_PUSH_URL=http://loki:3100/loki/api/v1/push \
    -v "$pipelines:/etc/alloy:ro" -v "$work/targets:/etc/alloy-targets:ro" "$image" \
    run --disable-reporting --storage.path=/tmp/alloy /etc/alloy >"$work/log" 2>&1 || status=$?
if [[ $status != 124 ]] || grep -q 'level=error' "$work/log"; then
    cat "$work/log" >&2
    echo "Alloy did not load the pipelines" >&2
    exit 1
fi
echo "Alloy loaded the pipelines"
