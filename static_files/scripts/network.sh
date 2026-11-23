#!/usr/bin/env bash
# Generates the node identities and the genesis of the Primary Network.
#
#   network.sh prepare DIR COUNT PRIMARY_COUNT
#
# It writes, before the first node starts:
#
#   DIR/nodes/<i>/   staking key, TLS certificate, and BLS signer key of node i
#   DIR/network.json node IDs and BLS proofs of possession, in node order
#   DIR/genesis.json Primary Network genesis (P-, X-, and C-Chain). It funds
#                    the EWOQ key and stakes the first PRIMARY_COUNT nodes.
#   DIR/upgrade.json network upgrade schedule (static_files/upgrade.json):
#                    every upgrade is active at genesis
#
# AvalancheGo creates its own keys on its first start and reports its node ID
# and proof of possession on its info API. The script starts the pinned
# AvalancheGo binary once per node, with an in-memory database and no peers,
# asks for that identity, and stops it. No other tool computes a BLS proof of
# possession. The genesis follows NewTestGenesis of AvalancheGo's tmpnet
# (tests/fixture/tmpnet/genesis.go), the generator that the package used
# before.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AVALANCHEGO=${AVALANCHEGO:-/avalanchego/build/avalanchego}
# Nodes that generate their identity at the same time.
PARALLEL=${PARALLEL:-8}
# Address without a known key that holds the genesis stake and receives the
# rewards of the genesis validators, as in tmpnet: the first 20 bytes of
# sha256("kurtosis-avalanche genesis stake").
STAKE_ADDRESS=X-custom18u0cl4rj3wm8a8uqvg6cexc0mz4cg490tzj2cn
# Amounts in nAVAX (1 AVAX = 1e9 nAVAX), from tmpnet.
MEGA_AVAX=1000000000000000
FUNDED_X_AMOUNT=30000000000000000 # 30 MegaAVAX on the X-Chain
FUNDED_P_AMOUNT=20000000000000000 # 20 MegaAVAX unlocked on the P-Chain
# 10^12 AVAX in wei on the C-Chain, as in tmpnet.
FUNDED_C_BALANCE=0xc9f2c9cd04674edea40000000
# Unix time at which AvalancheGo treats an upgrade as active from genesis
# (upgrade.InitiallyActiveTime, 2020-12-05T05:00:00Z).
INITIALLY_ACTIVE_TIME=1607144400

# identity INDEX DIR starts AvalancheGo once and writes the keys and the
# identity of node INDEX.
identity() {
    local index=$1 out=$2/nodes/$1 work port pid result="" until
    work=$(mktemp -d)
    port=$((20000 + 2 * index))
    "$AVALANCHEGO" --network-id=local --db-type=memdb --data-dir="$work" \
        --http-host=127.0.0.1 --http-port="$port" --staking-port=$((port + 1)) \
        --public-ip=127.0.0.1 --log-level=off --log-display-level=off >/dev/null 2>&1 &
    pid=$!
    until=$(deadline 120)
    while ! result=$(curl -sf --max-time 2 -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' "http://127.0.0.1:$port/ext/info"); do
        kill -0 "$pid" 2>/dev/null || die "AvalancheGo stopped before it reported the identity of node $index"
        expired "$until" && die "AvalancheGo did not report the identity of node $index"
        sleep 0.2
    done
    kill "$pid"
    wait "$pid" || true
    mkdir -p "$out"
    chmod 700 "$out"
    cp "$work"/staking/staker.key "$work"/staking/staker.crt "$work"/staking/signer.key "$out"/
    chmod 600 "$out"/*
    rm -rf "$work"
    jq -c '.result | {node_id: .nodeID, pop: .nodePOP}' <<<"$result" >"$out/identity.json"
}

prepare() {
    local dir=$1 count=$2 primaries=$3 i pid start lock total
    [[ $count =~ ^[0-9]+$ && $primaries =~ ^[0-9]+$ ]] || die "invalid node counts"
    ((primaries >= 1 && count >= primaries)) || die "invalid node counts"
    [[ ! -e $dir/genesis.json ]] || die "refusing to replace existing network files"
    mkdir -p "$dir"

    # Generate the identities in batches of PARALLEL nodes.
    local -a batch=()
    for ((i = 0; i < count; i++)); do
        identity "$i" "$dir" &
        batch+=($!)
        if ((${#batch[@]} == PARALLEL || i == count - 1)); then
            for pid in "${batch[@]}"; do wait "$pid" || die "node identity generation failed"; done
            batch=()
        fi
    done
    for ((i = 0; i < count; i++)); do cat "$dir/nodes/$i/identity.json"; done |
        jq -s '{nodes: .}' | atomic_write "$dir/network.json"

    # Start the network one minute in the past and keep the genesis validators
    # staked for ten years, so a long-lived devnet never loses its validators.
    # Locked funds unlock after one week.
    start=$(($(date +%s) - 60))
    lock=$((start + 7 * 24 * 60 * 60))
    total=$((primaries * MEGA_AVAX))
    jq --argjson network "$NETWORK_ID" --argjson start "$start" --argjson lock "$lock" \
        --argjson total "$total" --argjson primaries "$primaries" --arg stake "$STAKE_ADDRESS" \
        --arg ewoq "X-$EWOQ_P_ADDRESS" --arg ewoq_eth "$(strip0x "$EWOQ_ADDRESS")" \
        --argjson x_amount "$FUNDED_X_AMOUNT" --argjson p_amount "$FUNDED_P_AMOUNT" \
        --arg c_balance "$FUNDED_C_BALANCE" --arg timestamp "$(printf '0x%x' "$INITIALLY_ACTIVE_TIME")" '
        def zero(n): "0x" + ("0" * n);
        {
          networkID: $network,
          allocations: [
            {ethAddr: zero(40), avaxAddr: $stake, initialAmount: 0,
             unlockSchedule: [{amount: $total, locktime: $lock}]},
            {ethAddr: zero(40), avaxAddr: $ewoq, initialAmount: $x_amount,
             unlockSchedule: [{amount: $p_amount, locktime: 0}, {amount: $total, locktime: $lock}]}
          ],
          startTime: $start,
          initialStakeDuration: (10 * 365 * 24 * 60 * 60),
          initialStakeDurationOffset: (90 * 60),
          initialStakedFunds: [$stake],
          initialStakers: [.nodes[:$primaries][] | {
            nodeID: .node_id, rewardAddress: $stake, delegationFee: 10000, signer: .pop}],
          cChainGenesis: ({
            config: {chainId: $network}, nonce: "0x0",
            timestamp: $timestamp,
            extraData: "0x", gasLimit: "0x5f5e100", difficulty: "0x0",
            mixHash: zero(64), coinbase: zero(40),
            alloc: {($ewoq_eth): {balance: $c_balance}},
            number: "0x0", gasUsed: "0x0", parentHash: zero(64)
          } | tojson),
          message: "hello avalanche!"
        }' "$dir/network.json" | atomic_write "$dir/genesis.json"
    cp "$FIXTURES/upgrade.json" "$dir/upgrade.json"
}

main() {
    case ${1:-} in
    prepare)
        (($# == 4)) || die "usage: network.sh prepare DIR COUNT PRIMARY_COUNT"
        prepare "$2" "$3" "$4"
        ;;
    *) die "usage: network.sh prepare DIR COUNT PRIMARY_COUNT" ;;
    esac
}

# Run only when executed, so that a test can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
