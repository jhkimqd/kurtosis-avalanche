#!/usr/bin/env bash
# Check the observability stack of a running devnet from the outside:
#
#   bash helpers/check-observability.sh <enclave>
#
# The package starts the stack but does not test it. This script checks, for
# each part that the arguments of the devnet enabled:
#
#   1. Alloy is ready.
#   2. Prometheus has every node, relayer, and signature aggregator, all up.
#   3. Loki has the log lines of every node, with a level and with the time
#      that the line itself states.
#   4. Every dashboard query returns data. helpers/gen-dashboards.py lists the
#      queries; one that can be empty on a healthy devnet is left out.
#   5. Grafana is healthy, reaches its datasources, and has every dashboard.
#
# Metrics and logs arrive a few seconds after their source starts, so each
# check repeats until it passes or CHECK_TIMEOUT seconds (default 90) are over.
# Without a stack the script succeeds. It needs the Kurtosis CLI, curl, jq,
# and python3.
set -euo pipefail
cd "$(dirname "$0")/.."
enclave=${1:?Usage: $0 <enclave>}
timeout=${CHECK_TIMEOUT:-90}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
manifest=$work/manifest/deployment.json
kurtosis files download "$enclave" deployment-manifest "$work/manifest" >/dev/null 2>&1 || true
[[ -s "$manifest" ]] || { echo "Cannot read the deployment manifest of enclave $enclave" >&2; exit 1; }
arg() { jq -r "$1" "$manifest"; }
# runs <service>: the manifest names the URL of each service of the stack that runs.
runs() { [[ $(arg ".observability.${1}_url // empty") ]]; }

if ! runs alloy; then
    echo "The devnet runs no observability stack; nothing to check"
    exit 0
fi

failures=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

# address <service>: the address that Kurtosis maps to this machine.
address() {
    [[ -s "$work/address-$1" ]] || kurtosis port print "$enclave" "$1" http >"$work/address-$1" 2>/dev/null || true
    cat "$work/address-$1"
}
# get <service> <path> [curl arguments]: the response body, or nothing.
get() {
    local service=$1 path=$2
    shift 2
    curl -s -m 20 -G "$(address "$service")$path" "$@" 2>/dev/null || true
}
# The result list of a query, as JSON. A store that does not answer, or that
# answers with an error, gives []: no answer must never count as data.
result() {
    local answer
    # jq 1.6 reports success for empty input, so the output decides.
    answer=$(jq -c 'select(.status == "success") | .data.result // []' 2>/dev/null) || true
    echo "${answer:-[]}"
}
prometheus() { get prometheus /api/v1/query --data-urlencode "query=$1" | result; }
loki() { get loki /loki/api/v1/query --data-urlencode "query=$1" | result; }
loki_lines() { get loki /loki/api/v1/query_range --data-urlencode "query=$1" --data-urlencode "limit=${2:-1}" --data-urlencode "direction=${3:-backward}" --data-urlencode "since=24h" | result; }

# eventually <description> <function>: call the function until it succeeds.
# The function prints why it failed; the last reason goes into the report.
eventually() {
    local description=$1 check=$2 deadline=$((SECONDS + timeout)) reason
    while true; do
        if reason=$($check); then
            pass "$description${reason:+: $reason}"
            return
        fi
        if ((SECONDS >= deadline)); then
            fail "$description: $reason"
            return
        fi
        sleep 3
    done
}

# ── What the arguments of the devnet promise ─────────────────────────────────

primary_count=$(arg .args.primary_network.validator_count)
l1_count=$(arg .args.l1.count)
validator_count=$(arg .args.l1.validator_count)
rpc_count=$(arg .args.l1.rpc_count)
bridge=$(arg .args.bridge)
nodes=()
for ((n = 0; n < primary_count; n++)); do nodes+=("primary-$n"); done
for ((i = 0; i < l1_count; i++)); do
    for ((n = 0; n < validator_count; n++)); do nodes+=("l1-$i-validator-$n"); done
    for ((n = 0; n < rpc_count; n++)); do nodes+=("l1-$i-rpc-$n"); done
done

# The dashboard queries that must return data on this devnet.
python3 helpers/gen-dashboards.py --queries >"$work/queries.json"
# queries <datasource>: one compact JSON object per line.
queries() {
    jq -c --arg datasource "$1" --argjson bridge "$bridge" \
        '.[] | select(.datasource == $datasource and (.optional | not) and (.requires != "bridge" or $bridge))' "$work/queries.json"
}
# check_queries <datasource>: run each query that still fails; print the first
# failure. A query that has passed once is not asked again.
check_queries() {
    local datasource=$1 pending=$work/pending-$1 query expr result remaining=()
    [[ -e "$pending" ]] || queries "$datasource" >"$pending"
    while IFS= read -r query; do
        expr=$(jq -r .expr <<<"$query")
        if [[ $datasource == prometheus ]]; then
            result=$(prometheus "$expr")
        elif [[ $(jq -r .range <<<"$query") == true ]]; then
            result=$(loki_lines "$expr")
        else
            result=$(loki "$expr")
        fi
        [[ "$result" != '[]' ]] || remaining+=("$query")
    done <"$pending"
    : >"$pending"
    if ((${#remaining[@]} > 0)); then
        printf '%s\n' "${remaining[@]}" >"$pending"
        jq -r '"\(.dashboard) / \(.panel) has no data: \(.expr)"' <<<"${remaining[0]}"
        ((${#remaining[@]} == 1)) || echo "  (and $((${#remaining[@]} - 1)) more)"
        return 1
    fi
    echo "$(queries "$datasource" | wc -l) queries"
}

# ── Alloy ────────────────────────────────────────────────────────────────────

echo "Alloy"
alloy_ready() { [[ $(get alloy /-/ready) == *ready* ]] || { echo "not ready at $(address alloy)"; return 1; }; }
eventually "the collector is ready" alloy_ready

# ── Prometheus ───────────────────────────────────────────────────────────────

if runs prometheus; then
    echo "Metrics in Prometheus"
    # job_up <job> <count>: that many targets of the job answer the scrape.
    job_up() {
        local up
        up=$(prometheus "count(up{job=\"$1\"} == 1)" | jq -r '.[0].value[1] // "0"')
        [[ "$up" == "$2" ]] || { echo "$up of $2 are up"; return 1; }
        echo "$up"
    }
    nodes_up() { job_up avalanche "${#nodes[@]}"; }
    aggregators_up() { job_up signature-aggregator "$l1_count"; }
    relayers_up() { job_up icm-relayer "$l1_count"; }
    none_down() {
        local down
        down=$(prometheus 'up == 0' | jq -r '[.[].metric | .node // .instance] | join(", ")')
        [[ -z "$down" ]] || { echo "$down"; return 1; }
    }
    eventually "every node is scraped" nodes_up
    eventually "every signature aggregator is scraped" aggregators_up
    [[ $bridge != true ]] || eventually "every ICM relayer is scraped" relayers_up
    eventually "no target is down" none_down
    prometheus_queries() { check_queries prometheus; }
    eventually "every dashboard query returns metrics" prometheus_queries
fi

# ── Loki ─────────────────────────────────────────────────────────────────────

if runs loki; then
    echo "Logs in Loki"
    # nodes_with <selector>: the nodes that have a line for the selector.
    missing_nodes() {
        local have missing=() node
        have=$(loki "count by (node) (count_over_time({job=\"avalanche\", $1}[24h]))" | jq -r '.[].metric.node')
        for node in "${nodes[@]}"; do
            grep -qx "$node" <<<"$have" || missing+=("$node")
        done
        ((${#missing[@]} == 0)) || { echo "no lines of ${missing[*]}"; return 1; }
        echo "${#nodes[@]} nodes"
    }
    main_logs() { missing_nodes 'logger="main"'; }
    levels() { missing_nodes 'level=~".+"'; }
    # The oldest line of the first node: Loki must hold it at the time that
    # the line states, for example [11-19|10:00:00.123]. Alloy read it later.
    line_time() {
        local entry stated stored
        entry=$(loki_lines '{job="avalanche", node="primary-0", logger="main", level=~".+"}' 1 forward | jq -c '.[0].values[0] // empty')
        [[ -n "$entry" ]] || { echo "no line of primary-0"; return 1; }
        stated=$(jq -r '.[1]' <<<"$entry" | grep -o '^\[[0-9|:.-]*\]' | tr -d '[]')
        stored=$(jq -r '.[0]' <<<"$entry")
        # Nanoseconds to the format of AvalancheGo, in UTC like the containers.
        stored=$(python3 -c 'import sys, time; print(time.strftime("%m-%d|%H:%M:%S", time.gmtime(int(sys.argv[1][:-9]))) + "." + sys.argv[1][-9:-6])' "$stored")
        [[ -n "$stated" && "$stated" == "$stored" ]] || { echo "the line states '$stated', Loki holds it at '$stored'"; return 1; }
        echo "$stated"
    }
    eventually "every node has lines of its main logger" main_logs
    eventually "every node has lines with a level" levels
    eventually "a line keeps the time that it states" line_time
    loki_queries() { check_queries loki; }
    eventually "every dashboard query returns logs" loki_queries
fi

# ── Grafana ──────────────────────────────────────────────────────────────────

if runs grafana; then
    echo "Grafana"
    healthy() { [[ $(get grafana /api/health | jq -r '.database // empty' 2>/dev/null) == ok ]] || { echo "no answer at $(address grafana)"; return 1; }; }
    eventually "Grafana is healthy" healthy
    for store in prometheus loki; do
        runs "$store" || continue
        datasource() {
            local status
            status=$(get grafana "/api/datasources/uid/$store/health" | jq -r '.status // .message // "no answer"' 2>/dev/null)
            [[ "$status" == OK ]] || { echo "${status:-no answer}"; return 1; }
        }
        eventually "Grafana reaches its $store datasource" datasource
    done
    # Grafana has the dashboards of each group whose store runs.
    expected=()
    ! runs prometheus || expected+=(static_files/observability/grafana/dashboards/metrics/*.json)
    ! runs loki || expected+=(static_files/observability/grafana/dashboards/logs/*.json)
    dashboards() {
        local have missing=() file uid
        have=$(get grafana '/api/search?type=dash-db' | jq -r '.[].uid' 2>/dev/null)
        for file in "${expected[@]}"; do
            uid=$(jq -r .uid "$file")
            grep -qx "$uid" <<<"$have" || missing+=("$uid")
        done
        ((${#missing[@]} == 0)) || { echo "missing ${missing[*]}"; return 1; }
        echo "${#expected[@]} dashboards"
    }
    eventually "Grafana has every dashboard" dashboards
fi

if ((failures > 0)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "All checks passed"
