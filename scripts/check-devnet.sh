#!/usr/bin/env bash
# Check a running devnet from the outside: bash scripts/check-devnet.sh <enclave>
#
# The package already tests each network that it deploys. This script repeats
# the important checks with independent tools, at any later time:
#
#   1. The Primary Network: network ID, bootstrapped chains, validators.
#   2. Each L1 on the P-Chain: converted to an L1, validators registered.
#   3. Each L1's contracts: the ValidatorManager and who owns it.
#   4. Transactions on the C-Chain and on each L1: a transfer from the funded
#      account, a contract deployment, contract calls, and new blocks.
#   5. Every node of an L1 holds the same latest block.
#   6. With `explorer`, each explorer holds the transactions of step 4 and
#      their token transfer, the internal calls of a contract that makes them,
#      and reports its indexing finished; its web app answers.
#
# It needs Docker, the Kurtosis CLI, curl, and jq. It signs with the public
# EWOQ development key and sends a few transactions. Foundry's `cast` runs in a
# container inside the enclave network, so nothing else is installed.
set -euo pipefail
cd "$(dirname "$0")/.."
enclave=${1:?Usage: $0 <enclave>}

EWOQ_KEY=0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027
EWOQ_ADDRESS=0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC
# The Foundry image that also builds the contracts (contracts/Dockerfile).
foundry=$(grep -o -m1 'ghcr.io/foundry-rs/foundry[^ ]*' contracts/Dockerfile)
# Pull before capturing cast output: Docker writes first-pull progress to stderr.
if ! docker image inspect "$foundry" >/dev/null 2>&1; then
    docker pull "$foundry" >&2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
kurtosis files download "$enclave" deployment-manifest "$work/manifest" >/dev/null 2>&1 ||
    { echo "Cannot read the deployment manifest of enclave $enclave" >&2; exit 1; }
manifest=$work/manifest/deployment.json
# The contract that the script deploys: the CASH test token.
bytecode=$(jq -r .bytecode.object static_files/contracts/CashToken.json)

failures=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
# check <description> <actual> <expected>
check() { if [[ "$2" == "$3" ]]; then pass "$1: $2"; else fail "$1: got '$2', expected '$3'"; fi; }
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

# api <service> <path> <method> <params>: one JSON-RPC call through the port
# that Kurtosis maps to this machine. Prints the result, or nothing when the
# node does not answer; the check that reads it then fails.
api() {
    # The address of the node, for example http://127.0.0.1:32950. A file keeps
    # it, because each call runs in its own subshell.
    local address=$work/address-$1
    [[ -s "$address" ]] || kurtosis port print "$enclave" "$1" rpc >"$address" 2>/dev/null || true
    curl -s -m 10 -X POST -H 'content-type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$3\",\"params\":$4}" "$(<"$address")$2" |
        jq -c .result 2>/dev/null || true
}

# cast runs inside the enclave network. It reaches a node by its service name,
# so it can use the RPC URLs of the manifest as they are.
cast() { docker run --rm --network "kt-$enclave" --entrypoint cast "$foundry" "$@"; }
# send <cast send arguments>: sign with the EWOQ key, wait for the receipt, and
# print it as JSON. Prints {} when the chain does not accept the transaction.
send() {
    local receipt
    if receipt=$(cast send --private-key "$EWOQ_KEY" --json "$@" 2>/dev/null); then echo "$receipt"; else echo '{}'; fi
}

# check_evm <rpc-url> <chain-id>: send a transfer, deploy a contract, call it.
check_evm() {
    local url=$1 before after recipient receipt token
    check "chain ID" "$(cast chain-id --rpc-url "$url" 2>&1)" "$2"
    before=$(cast block-number --rpc-url "$url" 2>/dev/null || echo 0)
    # A new, random address: nobody holds its key, and its balance starts at 0.
    recipient=0x$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n')

    receipt=$(send --rpc-url "$url" --value 1 "$recipient")
    check "transfer of 1 wei, receipt status" "$(jq -r .status <<<"$receipt")" 0x1
    check "balance of the recipient, in wei" "$(cast balance --rpc-url "$url" "$recipient" 2>&1)" 1

    receipt=$(send --rpc-url "$url" --create "$bytecode")
    token=$(jq -r '.contractAddress // empty' <<<"$receipt")
    if [[ -z "$token" ]]; then
        fail "contract deployment: no receipt"
        return
    fi
    check "contract deployment at $token, receipt status" "$(jq -r .status <<<"$receipt")" 0x1
    check "contract call symbol()" "$(cast call --rpc-url "$url" "$token" 'symbol()(string)' 2>&1)" '"CASH"'
    receipt=$(send --rpc-url "$url" "$token" 'transfer(address,uint256)' "$recipient" 5)
    check "contract transaction transfer(), receipt status" "$(jq -r .status <<<"$receipt")" 0x1
    # Step 6 looks for this transaction in the explorer of the chain.
    jq -r '.transactionHash // empty' <<<"$receipt" >"$work/last-tx-$2"
    check "contract state balanceOf(recipient)" \
        "$(cast call --rpc-url "$url" "$token" 'balanceOf(address)(uint256)' "$recipient" 2>&1)" 5

    # A chain builds a block only when it has transactions. Three were sent.
    after=$(cast block-number --rpc-url "$url" 2>/dev/null || echo 0)
    if ((after > before)); then pass "new blocks: height $before -> $after"; else fail "no new block: height $before -> $after"; fi
}

# ── 1. Primary Network ───────────────────────────────────────────────────────
echo "Primary Network"
check "network ID" "$(api primary-0 /ext/info info.getNetworkID '{}' | jq -r .networkID)" \
    "$(jq -r .primary_network.network_id "$manifest")"
primary_count=$(jq -r .args.primary_network.validator_count "$manifest")
for ((n = 0; n < primary_count; n++)); do
    for chain in P X C; do
        check "primary-$n has bootstrapped the $chain-Chain" \
            "$(api "primary-$n" /ext/info info.isBootstrapped "{\"chain\":\"$chain\"}" | jq -r .isBootstrapped)" true
    done
done
check "validators on the P-Chain" \
    "$(api primary-0 /ext/bc/P platform.getCurrentValidators '{}' | jq '.validators | length')" "$primary_count"
height=$(api primary-0 /ext/bc/P platform.getHeight '{}' | jq -r '.height // empty')
if [[ $height =~ ^[0-9]+$ ]]; then pass "P-Chain height: $height"; else fail "the P-Chain reports no height"; fi
balance=$(api primary-0 /ext/bc/X avm.getBalance '{"address":"X-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p","assetID":"AVAX"}' | jq -r '.balance // empty')
if [[ $balance =~ ^[1-9][0-9]*$ ]]; then pass "X-Chain balance of the EWOQ account: $balance nAVAX"; else fail "the EWOQ account has no X-Chain balance"; fi

echo "C-Chain"
check_evm "$(jq -r .primary_network.c_chain_rpc_url "$manifest")" "$(jq -r .primary_network.c_chain_id "$manifest")"

# ── 2 to 5. Each L1 ──────────────────────────────────────────────────────────
validator_count=$(jq -r .args.l1.validator_count "$manifest")
rpc_count=$(jq -r .args.l1.rpc_count "$manifest")
for ((i = 0; i < $(jq '.l1s | length' "$manifest"); i++)); do
    l1() { jq -r ".l1s[$i].$1" "$manifest"; }
    name=$(l1 name)
    url=$(l1 'rpc_urls[0]')
    manager=$(l1 validator_manager_address)
    mode=$(l1 validator_management)
    echo "$name ($mode), blockchain $(l1 blockchain_id)"

    # 2. The P-Chain holds the registry of every L1 and its validator set.
    subnet=$(api primary-0 /ext/bc/P platform.getSubnet "{\"subnetID\":\"$(l1 subnet_id)\"}")
    check "P-Chain: the subnet is converted to an L1 (isPermissioned)" "$(jq -r .isPermissioned <<<"$subnet")" false
    check "P-Chain: address of the ValidatorManager" "$(lower "$(jq -r .managerAddress <<<"$subnet")")" "$(lower "$manager")"
    validators=$(api primary-0 /ext/bc/P platform.getCurrentValidators "{\"subnetID\":\"$(l1 subnet_id)\"}")
    check "P-Chain: registered validators of the L1" "$(jq '.validators | length' <<<"$validators")" "$validator_count"
    check "P-Chain: validators with weight and a fee balance" \
        "$(jq '[.validators[] | select((.weight | tonumber) > 0 and (.balance | tonumber) > 0)] | length' <<<"$validators")" "$validator_count"

    # 3. The ValidatorManager controls the validator set. With Proof of
    #    Authority the EWOQ account owns it. With Proof of Stake the staking
    #    manager owns it, so only a stake can add a validator.
    if [[ $(cast code --rpc-url "$url" "$manager" 2>/dev/null | wc -c) -gt 3 ]]; then pass "ValidatorManager is deployed at $manager"; else fail "no contract at $manager"; fi
    owner=$EWOQ_ADDRESS
    [[ $mode == poa ]] || owner=$(l1 staking_manager_address)
    check "owner of the ValidatorManager" "$(lower "$(cast call --rpc-url "$url" "$manager" 'owner()(address)' 2>&1)")" "$(lower "$owner")"

    # 4. Transactions.
    check_evm "$url" "$(l1 evm_chain_id)"

    # 5. Every validator and RPC node reports the same latest block. A node
    #    can be a moment behind, so the check asks up to 30 times.
    nodes=()
    for ((n = 0; n < validator_count; n++)); do nodes+=("$name-validator-$n"); done
    for ((n = 0; n < rpc_count; n++)); do nodes+=("$name-rpc-$n"); done
    latest=$(api "$name-rpc-0" "/ext/bc/$(l1 blockchain_id)/rpc" eth_getBlockByNumber '["latest",false]')
    [[ -n "$latest" ]] || latest='{}'
    height=$(jq -r '.number // "0x0"' <<<"$latest")
    for node in "${nodes[@]}"; do
        for ((attempt = 0; attempt < 30; attempt++)); do
            hash=$(api "$node" "/ext/bc/$(l1 blockchain_id)/rpc" eth_getBlockByNumber "[\"$height\",false]" | jq -r '.hash // empty')
            [[ -z "$hash" ]] || break
            sleep 1
        done
        check "$node holds block $((height))" "${hash:-no answer}" "$(jq -r '.hash // "unknown"' <<<"$latest")"
    done
done

# ── 6. Block explorers ───────────────────────────────────────────────────────
# explorer_api <api-url> <path>: one request to an explorer API on this host.
# Prints {} when the explorer does not answer; the check that reads it fails.
explorer_api() { curl -s -m 10 "$1$2" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null || echo '{}'; }
for ((e = 0; e < $(jq '.explorers // [] | length' "$manifest"); e++)); do
    explorer() { jq -r ".explorers[$e].$1" "$manifest"; }
    api_url=$(explorer api_url)
    chain=$(explorer chain)
    tx=$(cat "$work/last-tx-$(explorer evm_chain_id)" 2>/dev/null || true)
    tx=${tx:-none}
    echo "Explorer of $chain at $(explorer url)"
    check "web app, HTTP status" "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$(explorer url)" 2>/dev/null || true)" 200
    # The explorer indexes a new block within seconds, so it may lag a moment.
    # The transaction exists only on this chain, so finding it also shows that
    # the explorer reads the right chain.
    for ((attempt = 0; attempt < 30; attempt++)); do
        status=$(explorer_api "$api_url" "/transactions/$tx" | jq -r '.status // empty')
        [[ -z "$status" ]] || break
        sleep 2
    done
    check "transaction $tx of step 4, status in the explorer" "${status:-not indexed}" ok
    # That transaction is the CASH transfer() of step 4: one token transfer.
    check "token transfers of that transaction" \
        "$(explorer_api "$api_url" "/transactions/$tx/token-transfers" | jq '[.items[]? | select(.total.value == "5")] | length')" 1
    # Internal calls: on an L1, the ValidatorManager calls the Warp precompile
    # when it loads the first validator set. On the C-Chain, only the bridge
    # makes calls between contracts.
    if [[ $chain == c-chain ]]; then
        contract=$(jq -r '[.l1s[].bridge.home // empty][0] // empty' "$manifest")
    else
        contract=$(jq -r --arg name "$chain" '.l1s[] | select(.name == $name) | .validator_manager_address' "$manifest")
    fi
    if [[ -n "$contract" ]]; then
        for ((attempt = 0; attempt < 30; attempt++)); do
            calls=$(explorer_api "$api_url" "/addresses/$contract/internal-transactions" | jq '.items // [] | length')
            ((calls == 0)) || break
            sleep 2
        done
        if ((calls > 0)); then pass "internal transactions of $contract: $calls"; else fail "no internal transaction of $contract"; fi
    else
        echo "  skip  internal transactions: no contract on this chain makes internal calls"
    fi
    for ((attempt = 0; attempt < 30; attempt++)); do
        finished=$(explorer_api "$api_url" /main-page/indexing-status | jq -r '.finished_indexing_blocks == true and .finished_indexing == true')
        [[ $finished != true ]] || break
        sleep 2
    done
    check "indexing of blocks and internal transactions finished" "$finished" true
done

if ((failures > 0)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "All checks passed"
