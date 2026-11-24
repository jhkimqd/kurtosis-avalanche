#!/usr/bin/env bash
# Print the addresses of a running devnet on this machine:
#
#   bash helpers/endpoints.sh <enclave> [--json]
#
# Kurtosis publishes every port of the devnet on a random port of this
# machine, chosen when the service starts (ADR 0019). The deployment manifest
# holds the addresses inside the enclave and the blockchain IDs; `kurtosis port
# print` holds the published ports. This script joins the two: the RPC and
# WebSocket URLs of each chain, the address of each block explorer, and
# Grafana. It reads only; run it again after a service restarts.
#
# Without --json it prints a table. With --json it prints one JSON object:
#
#   primary_network  rpc_url, p_chain_rpc_url, x_chain_rpc_url,
#                    c_chain_rpc_url, c_chain_ws_url, c_chain_id
#   l1s[]            name, blockchain_id, evm_chain_id, rpc_url, ws_url
#   explorers[]      chain, evm_chain_id, url, api_url
#   grafana_url      when the devnet runs Grafana
#
# It needs the Kurtosis CLI and jq.
set -euo pipefail
enclave=${1:?Usage: $0 <enclave> [--json]}
format=${2:-table}
[[ $format == table || $format == --json ]] || { echo "Usage: $0 <enclave> [--json]" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
kurtosis files download "$enclave" deployment-manifest "$work/manifest" >/dev/null 2>&1 ||
    { echo "Cannot read the deployment manifest of enclave $enclave" >&2; exit 1; }
manifest=$work/manifest/deployment.json

# host_url <service> <port-id>: the address of a published port, such as
# http://127.0.0.1:32950.
host_url() {
    local url
    url=$(kurtosis port print "$enclave" "$1" "$2" 2>/dev/null) ||
        { echo "Kurtosis publishes no port $2 of service $1 in enclave $enclave" >&2; exit 1; }
    echo "$url"
}

# service_of <url>: the service name in an address inside the enclave, such as
# primary-0 in http://primary-0:9650/ext/bc/C/rpc.
service_of() {
    local rest=${1#*://}
    rest=${rest%%/*}
    echo "${rest%%:*}"
}

# Each node serves its API on the port "rpc" (src/config/constants.star).
primary=$(host_url "$(service_of "$(jq -r .primary_network.rpc_url "$manifest")")" rpc)
l1s='[]'
for ((i = 0; i < $(jq '.l1s | length' "$manifest"); i++)); do
    l1=$(jq ".l1s[$i]" "$manifest")
    node=$(host_url "$(service_of "$(jq -r '.rpc_urls[0]' <<<"$l1")")" rpc)
    l1s=$(jq --argjson l1 "$l1" --arg node "$node" '. + [{
        name: $l1.name, blockchain_id: $l1.blockchain_id, evm_chain_id: $l1.evm_chain_id,
        rpc_url: "\($node)/ext/bc/\($l1.blockchain_id)/rpc",
        ws_url: "\($node | sub("^http"; "ws"))/ext/bc/\($l1.blockchain_id)/ws"}]' <<<"$l1s")
done
explorers='[]'
for ((e = 0; e < $(jq '.explorers // [] | length' "$manifest"); e++)); do
    explorer=$(jq ".explorers[$e]" "$manifest")
    url=$(host_url "$(jq -r .service <<<"$explorer")" "$(jq -r .port_id <<<"$explorer")")
    explorers=$(jq --argjson explorer "$explorer" --arg url "$url" '. + [{
        chain: $explorer.chain, evm_chain_id: $explorer.evm_chain_id,
        url: $url, api_url: "\($url)/api/v2"}]' <<<"$explorers")
done
grafana=null
if [[ $(jq -r '.observability.grafana_url // empty' "$manifest") ]]; then
    grafana=$(host_url grafana http)
    grafana=$(jq -n --arg url "$grafana" '$url')
fi

endpoints=$(jq -n --arg p "$primary" --argjson c_chain_id "$(jq .primary_network.c_chain_id "$manifest")" \
    --argjson l1s "$l1s" --argjson explorers "$explorers" --argjson grafana "$grafana" '{
    primary_network: {
        rpc_url: $p, p_chain_rpc_url: "\($p)/ext/bc/P", x_chain_rpc_url: "\($p)/ext/bc/X",
        c_chain_rpc_url: "\($p)/ext/bc/C/rpc", c_chain_ws_url: "\($p | sub("^http"; "ws"))/ext/bc/C/ws",
        c_chain_id: $c_chain_id},
    l1s: $l1s, explorers: $explorers}
    + (if $grafana then {grafana_url: $grafana} else {} end)')

case $format in
--json) echo "$endpoints" ;;
table)
    jq -r '
        ["P-Chain", .primary_network.p_chain_rpc_url],
        ["X-Chain", .primary_network.x_chain_rpc_url],
        ["C-Chain (chain ID \(.primary_network.c_chain_id))", .primary_network.c_chain_rpc_url],
        ["C-Chain WebSocket", .primary_network.c_chain_ws_url],
        (.l1s[] | ["\(.name) (chain ID \(.evm_chain_id))", .rpc_url], ["\(.name) WebSocket", .ws_url]),
        (.explorers[] | ["Explorer of \(.chain)", .url]),
        (if .grafana_url then ["Grafana", .grafana_url] else empty end)
        | "\(.[0] | . + " " * ([28 - length, 1] | max))\(.[1])"' <<<"$endpoints"
    ;;
esac
