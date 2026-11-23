#!/usr/bin/env bash
# Nightly test of direct ICM messages between every pair of L1s.
#
#   icm.sh config URI DIR MANIFEST   fund a temporary relayer and write its config
#   icm.sh smoke  URI DIR MANIFEST   send and verify one message per ordered pair
#
# MANIFEST is the deployment manifest JSON (main.star). The temporary relayer
# connects the L1s directly; the bridge relayers connect each L1 to the
# C-Chain instead.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Development key 11 is the account of the temporary relayer.
RELAYER_KEY=$(dev_key 11)
ZERO_ADDRESS=0x0000000000000000000000000000000000000000

# event_topic CONTRACT EVENT prints topic 0 of an event, read from the artifact.
event_topic() {
    cast keccak "$(jq -er --arg event "$2" '
        def t: if (.type | startswith("tuple"))
            then "(" + ([.components[] | t] | join(",")) + ")" + (.type | ltrimstr("tuple"))
            else .type end;
        [.abi[] | select(.type == "event" and .name == $event)] | .[0] // error("no event \($event)")
        | "\(.name)(\([.inputs[] | t] | join(",")))"' "$CONTRACTS/$1.json")"
}

# check_manifest rejects incomplete or duplicate routes before any account is
# funded, and any RPC that does not belong to this deployment.
check_manifest() {
    local uri=$1 identity url base
    jq -e --argjson network "$NETWORK_ID" '.primary_network.network_id == $network and (.l1s | length) >= 2' <<<"$MANIFEST" >/dev/null ||
        die "ICM tests require network $NETWORK_ID and at least two L1s"
    jq -e '
        (.l1s | map(.blockchain_id) | unique | length) == (.l1s | length)
        and (.l1s | map(.evm_chain_id) | unique | length) == (.l1s | length)
        and all(.l1s[]; (.evm_chain_id // 0) > 0 and (.rpc_urls | length) > 0
            and (.bridge.messenger // "0x0000000000000000000000000000000000000000" | ascii_downcase)
                != "0x0000000000000000000000000000000000000000"
            and (.blockchain_id as $id | all(.rpc_urls[]; endswith("/ext/bc/" + $id + "/rpc"))))' <<<"$MANIFEST" >/dev/null ||
        die "incomplete or duplicate ICM route in the manifest"
    for id in $(jq -r '.l1s[] | .blockchain_id, .subnet_id' <<<"$MANIFEST"); do cb58_decode "$id" >/dev/null; done
    identity=$(deployment_identity "$uri")
    for ((i = 0; i < L1_COUNT; i++)); do
        for url in $(jq -r ".l1s[$i].rpc_urls[]" <<<"$MANIFEST"); do
            base=$(base_uri "$url")
            [[ $(deployment_identity "$base") == "$identity" ]] || die "$url is not part of this deployment"
            [[ $(cast chain-id -r "$url") == "$(jq -r ".l1s[$i].evm_chain_id" <<<"$MANIFEST")" ]] ||
                die "the EVM chain ID of $url does not match $(jq -r ".l1s[$i].name" <<<"$MANIFEST")"
        done
    done
    echo "$identity"
}

config() {
    local uri=$1 dir=$2 relayer url
    relayer=$(cast wallet address "$RELAYER_KEY")
    for ((i = 0; i < L1_COUNT; i++)); do
        url=$(jq -r ".l1s[$i].rpc_urls[0]" <<<"$MANIFEST")
        evm_tx "$url" "$dir/$i" fund-relayer "$relayer" 0x "$(tokens 1)" >/dev/null
    done
    jq --arg uri "$uri" --arg relayer "$relayer" --arg key "$(strip0x "$RELAYER_KEY")" '
        def ws: sub("^http://"; "ws://") | sub("/rpc$"; "/ws");
        {
          "log-level": "info", "api-port": 9091, "metrics-port": 9092, "allow-private-ips": true,
          "storage-location": "/data", "process-missed-blocks": true,
          "p-chain-api": {"base-url": $uri}, "info-api": {"base-url": $uri},
          "source-blockchains": [.l1s[] | {
            "subnet-id": .subnet_id, "blockchain-id": .blockchain_id,
            "rpc-endpoint": {"base-url": .rpc_urls[0]}, "ws-endpoint": {"base-url": (.rpc_urls[0] | ws)},
            "message-contracts": {(.bridge.messenger): {"message-format": "teleporter", settings: {"reward-address": $relayer}}}}],
          "destination-blockchains": [.l1s[] | {
            "subnet-id": .subnet_id, "blockchain-id": .blockchain_id,
            "rpc-endpoint": {"base-url": .rpc_urls[0]}, "account-private-key": $key}]
        }' <<<"$MANIFEST" | atomic_write "$dir/relayer/config.json"
}

# canonical URL RECEIPT fails unless RECEIPT succeeded in the block that the
# node now serves at its height. The node's own block hash is used: a generic
# Ethereum header decoder drops Avalanche header fields.
canonical() {
    local block
    jq -e '.status == "0x1" and .blockNumber != null and .blockHash != null' <<<"$2" >/dev/null ||
        die "message transaction has no successful settled receipt"
    block=$(rpc "$1" eth_getBlockByNumber "$(jq -c '[.blockNumber, false]' <<<"$2")")
    [[ $(jq -r .hash <<<"$block") == "$(jq -r .blockHash <<<"$2")" ]] ||
        die "message transaction block differs from the canonical block"
}

# delivery URL RECEIVER MESSENGER MESSAGE_ID ENVELOPE waits until the
# application on URL received the message and prints the settling receipt.
delivery() {
    local url=$1 receiver=$2 messenger=$3 id=$4 envelope=$5 logs log receipt until
    until=$(deadline "$WAIT_SECONDS")
    while :; do
        logs=$(rpc "$url" eth_getLogs "$(jq -cn --arg address "$receiver" --arg topic "$RECEIVED_TOPIC" --arg envelope "$envelope" \
            '[{fromBlock: "0x0", toBlock: "latest", address: $address, topics: [$topic, $envelope]}]')")
        (($(jq length <<<"$logs") <= 1)) || die "the application received the same envelope more than once"
        if (($(jq length <<<"$logs") == 1)); then
            log=$(jq -c '.[0]' <<<"$logs")
            receipt=$(rpc "$url" eth_getTransactionReceipt "$(jq -c '[.transactionHash]' <<<"$log")")
            canonical "$url" "$receipt"
            jq -e --argjson r "$receipt" '(.removed | not) and .blockHash == $r.blockHash
                and .transactionHash == $r.transactionHash and .blockNumber == $r.blockNumber' <<<"$log" >/dev/null ||
                die "the destination event is not in the settled transaction"
            [[ $(view "$url" MessageReceiver "$receiver" receivedMessages "$envelope" | jq -r '.[0]') == true ]] ||
                die "MessageReceiver did not record delivery"
            [[ $(view "$url" TeleporterMessenger "$messenger" messageReceived "$id" | jq -r '.[0]') == true ]] ||
                die "TeleporterMessenger did not record delivery"
            echo "$receipt"
            return
        fi
        expired "$until" && die "application message not delivered"
        sleep 1
    done
}

smoke() {
    local uri=$1 dir=$2 identity=$3 relayer source destination
    local -a receivers=() names=() chains=() messengers=() rpcs=()
    relayer=$(cast wallet address "$RELAYER_KEY")
    SENT_TOPIC=$(event_topic TeleporterMessenger SendCrossChainMessage)
    RECEIVED_TOPIC=$(cast keccak "MessageReceived(bytes32)")
    for ((i = 0; i < L1_COUNT; i++)); do
        names+=("$(jq -r ".l1s[$i].name" <<<"$MANIFEST")")
        chains+=("$(jq -r ".l1s[$i].blockchain_id" <<<"$MANIFEST")")
        messengers+=("$(jq -r ".l1s[$i].bridge.messenger" <<<"$MANIFEST")")
        rpcs+=("$(jq -r ".l1s[$i].rpc_urls[0]" <<<"$MANIFEST")")
        receivers+=("$(deploy "${rpcs[i]}" "$dir/$i" MessageReceiver "" "" "${messengers[i]}")")
    done
    : >"$dir/deliveries.jsonl"
    for ((source = 0; source < L1_COUNT; source++)); do
        for ((destination = 0; destination < L1_COUNT; destination++)); do
            ((source != destination)) || continue
            local source_hex destination_hex payload input data receipt id envelope settled="" got url
            source_hex=0x$(cb58_decode "${chains[source]}")
            destination_hex=0x$(cb58_decode "${chains[destination]}")
            payload=$(cast from-utf8 "$identity:${chains[source]}:${chains[destination]}")
            input="($destination_hex,${receivers[destination]},($ZERO_ADDRESS,0),200000,[$relayer],$payload)"
            data=$(calldata TeleporterMessenger sendCrossChainMessage "$input")
            receipt=$(cat "$(evm_tx "${rpcs[source]}" "$dir/$source/to-$destination" send-message "${messengers[source]}" "$data" 0)")
            canonical "${rpcs[source]}" "$receipt"
            # Exactly one send event of the messenger, routed to the destination.
            id=$(jq -er --arg messenger "${messengers[source],,}" --arg topic "$SENT_TOPIC" --arg destination "$destination_hex" '
                [.logs[] | select((.address | ascii_downcase) == $messenger and (.topics | length) == 3 and .topics[0] == $topic)]
                | if length == 1 and .[0].topics[2] == $destination then .[0].topics[1]
                  else error("ambiguous or incorrectly routed ICM send") end' <<<"$receipt") ||
                die "no ICM message ID in the source receipt"
            # MessageReceiver records keccak256(abi.encode(source, sender, message)).
            envelope=$(cast keccak "$(cast abi-encode "f(bytes32,address,bytes)" "$source_hex" "$EWOQ_ADDRESS" "$payload")")
            log "ICM submitted ${names[source]} -> ${names[destination]}: message $id, transaction $(jq -r .transactionHash <<<"$receipt")"
            for url in $(jq -r ".l1s[$destination].rpc_urls[]" <<<"$MANIFEST"); do
                got=$(delivery "$url" "${receivers[destination]}" "${messengers[destination]}" "$id" "$envelope")
                if [[ -z $settled ]]; then
                    settled=$got
                else
                    jq -e --argjson a "$settled" '.transactionHash == $a.transactionHash and .blockHash == $a.blockHash
                        and .blockNumber == $a.blockNumber' <<<"$got" >/dev/null ||
                        die "the destination RPC nodes disagree on the settled message transaction"
                fi
            done
            jq -cn --arg source "${names[source]}" --arg destination "${names[destination]}" --arg id "$id" \
                --argjson sent "$receipt" --argjson settled "$settled" --arg envelope "$envelope" \
                --argjson height "$((16#$(strip0x "$(jq -r .blockNumber <<<"$settled")")))" '
                {Source: $source, Destination: $destination, MessageID: $id, SourceTx: $sent.transactionHash,
                 DestinationTx: $settled.transactionHash, EnvelopeHash: $envelope,
                 DestinationBlock: $settled.blockHash, DestinationHeight: $height}' >>"$dir/deliveries.jsonl"
            log "ICM delivered ${names[source]} -> ${names[destination]}: $id"
        done
    done
    jq -s --argjson count "$L1_COUNT" '{l1_count: $count, messages_delivered: length, messages: .}' "$dir/deliveries.jsonl" |
        atomic_write "$dir/results.json"
}

main() {
    require_tools_service
    writer_lock
    (($# == 4)) || die "usage: icm.sh config|smoke URI DIR MANIFEST"
    MANIFEST=$4
    L1_COUNT=$(jq '.l1s | length' <<<"$MANIFEST")
    identity=$(check_manifest "$2")
    case $1 in
    config) config "$2" "$3" ;;
    smoke) smoke "$2" "$3" "$identity" ;;
    *) die "usage: icm.sh config|smoke URI DIR MANIFEST" ;;
    esac
}

# Run only when executed, so that a test can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
