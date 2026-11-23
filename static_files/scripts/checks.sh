#!/usr/bin/env bash
# Checks of a running L1.
#
#   checks.sh wait      RPC CHAIN_ID   wait until RPC serves the EVM chain ID
#   checks.sh transfers RPC COUNT      send COUNT test transfers of 1 wei
#   checks.sh rpcs      RPC...         check that all RPC nodes agree on one block
#
# Only `transfers` signs; its transfers have no journal.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The recipient of the test transfers.
RECIPIENT=0x0000000000000000000000000000000000001234

wait_rpc() {
    local url=$1 expected=$2 until got=""
    until=$(deadline "$WAIT_SECONDS")
    until got=$(cast chain-id -r "$url" 2>/dev/null) && [[ $got == "$expected" ]]; do
        expired "$until" && die "$url does not serve chain ID $expected (last answer: ${got:-none})"
        sleep 1
    done
}

# transfers sends COUNT transfers of 1 wei, one after the other, prints one
# JSON line per transfer, and checks that the balance of the recipient grew
# by exactly COUNT.
transfers() {
    local url=$1 count=$2 before after start submitted receipt status success=0 i
    if ! [[ $count =~ ^[0-9]+$ ]] || ((count < 1 || count > 10000)); then die "count must be between 1 and 10000"; fi
    local_only "$url"
    before=$(cast balance "$RECIPIENT" -r "$url")
    start=$(date +%s%3N)
    for ((i = 0; i < count; i++)); do
        submitted=$(date +%s%3N)
        # `cast send` waits for the receipt.
        receipt=$(cast send --json --private-key "$EWOQ_KEY" --value 1 --gas-limit 21000 --timeout 30 \
            -r "$url" "$RECIPIENT") || die "unresolved transfer $i"
        status=$(jq -r .status <<<"$receipt")
        [[ $status == 0x1 ]] && success=$((success + 1))
        jq -cn --argjson id "$i" --arg tx "$(jq -r .transactionHash <<<"$receipt")" \
            --arg outcome "$([[ $status == 0x1 ]] && echo accepted-success || echo accepted-revert)" \
            --argjson latency "$(($(date +%s%3N) - submitted))" \
            '{business_id: $id, tx_id: $tx, outcome: $outcome, latency_ms: $latency}'
    done
    after=$(cast balance "$RECIPIENT" -r "$url")
    ((after - before == success)) || die "balance reconciliation failed"
    jq -cn --argjson n "$count" --argjson ok "$success" --argjson elapsed "$(($(date +%s%3N) - start))" \
        '{version: 1, kind: "correctness-smoke", submitted: $n, accepted_success: $ok, elapsed_ms: $elapsed, balance_reconciled: true}'
    ((success == count)) || die "$((count - success)) transactions reverted"
}

# rpcs waits for every RPC node to know the latest block of the first one,
# and checks that all serve the same chain ID and the same block hash.
rpcs() {
    local first=$1 number hash chain url got until
    number=$(cast block latest --field number -r "$first")
    hash=$(cast block "$number" --field hash -r "$first")
    chain=$(cast chain-id -r "$first")
    for url in "$@"; do
        [[ $(cast chain-id -r "$url") == "$chain" ]] || die "the EVM chain IDs of $first and $url differ"
        until=$(deadline "$WAIT_SECONDS")
        until got=$(cast block "$number" --field hash -r "$url" 2>/dev/null); do
            expired "$until" && die "$url does not reach block $number"
            sleep 1
        done
        [[ $got == "$hash" ]] || die "$first and $url differ at block $number"
    done
}

main() {
    case ${1:-} in
    wait)
        (($# == 3)) || die "wait requires L1 RPC and expected EVM chain ID"
        wait_rpc "$2" "$3"
        ;;
    transfers)
        (($# == 3)) || die "transfers requires RPC and count"
        require_tools_service
        writer_lock
        transfers "$2" "$3"
        ;;
    rpcs)
        (($# >= 2)) || die "rpcs requires at least one RPC"
        rpcs "${@:2}"
        ;;
    *) die "usage: checks.sh wait|transfers|rpcs ..." ;;
    esac
}

# Run only when executed, so that a test can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
