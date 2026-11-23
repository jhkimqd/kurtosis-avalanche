#!/usr/bin/env bash
# Moves an L1 from Proof of Authority to Proof of Stake.
#
#   staking.sh migrate  URI RPC DIR AGGREGATOR NODE_INDEX MODE
#   staking.sh finalize URI RPC DIR AGGREGATOR MODE NODE_INDEX...
#
# MODE is native-pos or erc20-pos. `migrate` stakes one validator, the node
# with NODE_INDEX; the first call also deploys the staking manager. `finalize`
# removes the bootstrap validators named at conversion, which hold no stake,
# and verifies the result. See docs/l1-lifecycle.md.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Staking rules of the L1, in the order of the settings struct:
#
#   minimum stake              1 token
#   maximum stake              10 tokens
#   minimum stake duration     60 seconds
#   minimum delegation fee     1 basis point (0.01%)
#   maximum stake multiplier   4: stake plus delegations of at most 4 times
#                              the stake, so delegations of up to 3 times
#   weight-to-value factor     5e12 wei per unit of P-Chain weight, so a stake
#                              of 1 token has weight 200000
#   reward calculator          ExampleRewardCalculator with a rate of 0
#   uptime blockchain          the L1 itself
STAKE=1000000000000000000
MAX_STAKE=10000000000000000000
VALIDATOR_WEIGHT=200000
# Status of an active validator in the ValidatorManager (ValidatorStatus.Active).
ACTIVE=2

staking_contract() {
    case $1 in
    native-pos) echo NativeTokenStakingManager ;;
    erc20-pos) echo ERC20TokenStakingManager ;;
    *) die "unsupported staking mode $1" ;;
    esac
}

# self_tx URL DIR NAME sends an empty transaction, so that the L1 makes a block.
self_tx() { evm_tx "$1" "$2" "$3" "$EWOQ_ADDRESS" 0x 0 >/dev/null; }

# wait_churn URL MANAGER DIR waits until the L1 has entered a new churn
# period, so that the next validator change gets the full allowance of 20% of
# the total weight. Chain time moves only with new blocks, so it sends empty
# transactions until a block is late enough.
wait_churn() {
    local url=$1 manager=$2 dir=$3 tracker target i=0
    tracker=$(view "$url" ValidatorManager "$manager" getChurnTracker)
    # getChurnTracker returns the period, the maximum percentage, and the
    # current period, whose first field is its start time.
    target=$(jq '(.[2][0] | tonumber) + (.[0] | tonumber)' <<<"$tracker")
    local now
    while :; do
        # Read the time outside the condition, so that a failed call stops.
        now=$(cast block latest --field timestamp -r "$url")
        ((now < target)) || break
        self_tx "$url" "$dir" "churn-$target-$i"
        i=$((i + 1))
        sleep 1
    done
}

# observe_pchain URI URL DIR waits until the ProposerVM epoch of the L1 has
# reached the current P-Chain height, and prints the epoch height. Only then
# do the L1 validators sign a Warp message about the latest P-Chain change.
# The epoch moves with new blocks, so it sends empty transactions.
observe_pchain() {
    local uri=$1 url=$2 dir=$3 target height i=0
    target=$(rpc "$uri/ext/bc/P" platform.getHeight | jq -r '.height | tonumber')
    while :; do
        height=$(epoch_height "${url%/rpc}/proposervm")
        ((height < target)) || break
        self_tx "$url" "$dir" "epoch-$target-$i"
        i=$((i + 1))
        sleep 1
    done
    echo "$height"
}

# l1_validator_exists prints "registered" if the P-Chain knows VALIDATION_ID.
l1_validator_exists() {
    if rpc_quiet "$URI/ext/bc/P" platform.getL1Validator "$(jq -cn --arg id "$VALIDATION_ID" '{validationID: $id}')" >/dev/null; then
        echo registered
    else
        echo -
    fi
}

# l1_validator_removed prints "removed" if the P-Chain answers that it no
# longer knows VALIDATION_ID, or lists it with weight 0. Any other answer,
# such as a failed call, is "-".
l1_validator_removed() {
    local response
    response=$(curl -sS --max-time 30 -H 'Content-Type: application/json' \
        --data "$(jq -cn --arg id "$VALIDATION_ID" '{jsonrpc: "2.0", id: 1, method: "platform.getL1Validator", params: {validationID: $id}}')" \
        "$URI/ext/bc/P") || {
        echo -
        return
    }
    jq -r 'if .result then (if (.result.weight | tonumber) == 0 then "removed" else "-" end)
        elif (.error.message // "" | test("not found")) then "removed" else "-" end' <<<"$response" 2>/dev/null || echo -
}

# topup_retry lets a top-up step run again: a second top-up only adds 1 AVAX
# to the fee balance of a validator.
topup_retry() { echo retry; }

# validator_state URL MANAGER VALIDATION_ID prints "status weight" from the
# ValidatorManager.
validator_state() {
    view "$1" ValidatorManager "$2" getValidator "$3" | jq -r '.[0] | "\(.[0]) \(.[5])"'
}

# migrate stakes the node with NODE_INDEX as a validator of the L1.
#
# The first call deploys the staking manager (NativeTokenStakingManager or
# ERC20TokenStakingManager) and a reward calculator, and makes the staking
# manager the owner of the ValidatorManager. Later calls find these steps in
# the journals and skip them. Each call then registers one validator:
#
#  1. initiateValidatorRegistration on the L1 locks the stake and sends a Warp
#     message.
#  2. RegisterL1ValidatorTx carries that message, signed by the L1 validators,
#     to the P-Chain. It also pays 100 AVAX into the validator's fee balance.
#  3. completeValidatorRegistration returns the P-Chain's confirmation to the L1.
migrate() {
    local uri=$1 url=$2 dir=$3 aggregator=$4 index=$5 mode=$6
    local contract subnet chain manager library migration staking reward settings token node node_hex
    local owner value args data receipt unsigned validation_hex validation_id target height signed ack signed_ack state
    local_only "$uri"
    contract=$(staking_contract "$mode")
    subnet=$(jq -r .subnet_id "$dir/chain.json")
    chain=$(jq -r .blockchain_id "$dir/chain.json")
    [[ $url == */ext/bc/$chain/rpc ]] || die "migration RPC must be the deployed L1"
    manager=$(jq -r .address "$dir/manager.json")
    library=$(jq -r .library "$dir/manager.json")
    [[ $index =~ ^[0-9]+$ ]] || die "invalid node index $index"
    if [[ -f $dir/migration-profile.json ]]; then
        [[ $(jq -r .mode "$dir/migration-profile.json") == "$mode" ]] ||
            die "deployment already selected migration profile $(jq -r .mode "$dir/migration-profile.json")"
    else
        jq -n --arg mode "$mode" '{mode: $mode}' | atomic_write "$dir/migration-profile.json"
    fi

    migration=$dir/$mode
    staking=$(deploy "$url" "$migration" "$contract" "$library" "" 0)
    reward=$(deploy "$url" "$migration" ExampleRewardCalculator "" "" 0)
    settings="($manager,$STAKE,$MAX_STAKE,60,1,4,5000000000000,$reward,0x$(cb58_decode "$chain"))"
    if [[ $mode == erc20-pos ]]; then
        token=$(deploy "$url" "$migration" StakingToken "" "")
        invoke "$url" "$migration/fund-$index" mint StakingToken "$token" "" "$EWOQ_ADDRESS" "$STAKE" >/dev/null
        invoke "$url" "$migration" setRewardMinter StakingToken "$token" "" "$staking" >/dev/null
        invoke "$url" "$migration/fund-$index" approve StakingToken "$token" "" "$staking" "$STAKE" >/dev/null
        invoke "$url" "$migration" initialize "$contract" "$staking" "" "$settings" "$token" >/dev/null
    else
        invoke "$url" "$migration" initialize "$contract" "$staking" "" "$settings" >/dev/null
    fi
    invoke "$url" "$migration" transferOwnership ValidatorManager "$manager" "" "$staking" >/dev/null
    owner=$(view "$url" ValidatorManager "$manager" owner | jq -r '.[0] | ascii_downcase')
    [[ $owner == "${staking,,}" ]] || die "manager ownership did not transfer"

    # Register the node: stake 1 token with a delegation fee of 1 basis point
    # and a minimum duration of 60 seconds. The EWOQ account owns the
    # validator and receives its rewards; the EWOQ P-Chain address owns the
    # remaining balance and may deactivate it.
    node=$(jq -ce --argjson i "$index" '.nodes[$i] // error("invalid node index \($i)")' "$STATE/network/network.json")
    node_hex=0x$(cb58_decode "$(jq -r .node_id <<<"$node")")
    owner="(1,[$EWOQ_P_SHORT_ID])"
    args=("$node_hex" "$(jq -r .pop.publicKey <<<"$node")" "$owner" "$owner" 1 60)
    value=$STAKE
    if [[ $mode == erc20-pos ]]; then
        args+=("$STAKE")
        value=0
    fi
    args+=("$EWOQ_ADDRESS")
    migration=$migration/validator-$index
    data=$(calldata "$contract" initiateValidatorRegistration "${args[@]}")
    wait_churn "$url" "$manager" "$migration"
    receipt=$(evm_tx "$url" "$migration" register-request "$staking" "$data" "$value")
    unsigned=$(receipt_warp_message "$receipt")
    # The validation ID is the hash of the RegisterL1Validator message.
    validation_hex=0x$(sha256_hex "$(warp_payload_message "$unsigned")")
    validation_id=$(cb58_encode "$validation_hex")

    # Add 1 AVAX to the fee balance of an existing validator. The transaction
    # makes the P-Chain produce a block before its epoch height is read below.
    if [[ ! -f $migration/topup-target.json ]]; then
        target=$(rpc "$uri/ext/bc/P" platform.getCurrentValidators "$(jq -cn --arg id "$subnet" '{subnetID: $id}')" |
            jq -e '.validators[0].validationID // error("no initial validators")')
        echo "$target" | atomic_write "$migration/topup-target.json"
    fi
    target=$(jq -r . "$migration/topup-target.json")
    pchain_step "$uri" "$migration" topup topup_retry 'Increase L1 Validator Balance TX: ([[:alnum:]]+)' -- \
        l1 increase-validator-balance --validation-id "$target" --balance 1 >/dev/null

    height=$(epoch_height "$uri/ext/bc/P/proposervm")
    signed=$(proof "$migration/register-proof.hex" "$aggregator" "$unsigned" "" "$subnet" "$height")
    URI=$uri VALIDATION_ID=$validation_id
    pchain_step "$uri" "$migration" registration l1_validator_exists 'Register L1 Validator TX: ([[:alnum:]]+)' -- \
        l1 register-validator --message "$signed" --pop "$(jq -r .pop.proofOfPossession <<<"$node")" --balance 100 >/dev/null

    height=$(observe_pchain "$uri" "$url" "$migration")
    ack=$(registration_message "$validation_hex" true)
    signed_ack=$(proof "$migration/ack-proof.hex" "$aggregator" "$ack" "" "$subnet" "$height")
    invoke "$url" "$migration" completeValidatorRegistration "$contract" "$staking" "$(predicate "$signed_ack")" 0 >/dev/null
    state=$(validator_state "$url" "$manager" "$validation_hex")
    [[ $state == "$ACTIVE $VALIDATOR_WEIGHT" ]] || die "unexpected validator state (status weight): $state"
    jq -n --arg mode "$mode-admission" --arg manager "$manager" --arg staking "$staking" --arg id "$validation_id" \
        --argjson weight "$VALIDATOR_WEIGHT" \
        '{mode: $mode, fully_pos: false, manager: $manager, staking: $staking, validation_id: $id, weight: $weight,
          rpc_node_promoted: false, reward_rate: 0}' | atomic_write "$dir/migration-$index.json"
}

# finalize removes every bootstrap validator and verifies the result.
#
# Each removal takes three steps:
#
#  1. initiateValidatorRemoval on the L1 sends a Warp message.
#  2. SetL1ValidatorWeightTx carries it to the P-Chain and sets the weight to 0.
#  3. completeValidatorRemoval returns the P-Chain's confirmation to the L1.
#
# The final checks: the P-Chain lists exactly the staked validators; each is
# active with the expected weight, owner, and a P-Chain balance; and the
# staking manager holds one token for each of them.
finalize() {
    local uri=$1 url=$2 dir=$3 aggregator=$4 mode=$5
    local contract subnet subnet_hex manager staking count i stage node_hex validation_hex data receipt unsigned
    local height signed ack justification signed_ack current expected id hex locked token
    shift 5
    (($# > 0)) || die "finalize needs the node indexes of the staked validators"
    contract=$(staking_contract "$mode")
    subnet=$(jq -r .subnet_id "$dir/chain.json")
    subnet_hex=0x$(cb58_decode "$subnet")
    manager=$(jq -r .address "$dir/manager.json")
    staking=$(jq -r .staking "$dir/migration-$1.json")
    count=$(jq '.validators | length' "$dir/conversion.json")
    for ((i = 0; i < count; i++)); do
        stage=$dir/remove-bootstrap/$i
        node_hex=$(jq -r --argjson i "$i" '.validators[$i].node_id_hex' "$dir/conversion.json")
        # Keep the ID: the removal deletes the manager's lookup by node ID.
        if [[ ! -f $stage/id.json ]]; then
            validation_hex=$(view "$url" ValidatorManager "$manager" getNodeValidationID "$node_hex" | jq -r '.[0]')
            [[ $validation_hex != 0x$(printf '%064d' 0) ]] || die "bootstrap validator $node_hex missing before removal"
            jq -n --arg id "$validation_hex" '$id' | atomic_write "$stage/id.json"
        fi
        validation_hex=$(jq -r . "$stage/id.json")
        wait_churn "$url" "$manager" "$stage"
        data=$(calldata "$contract" initiateValidatorRemoval "$validation_hex" false 0)
        receipt=$(evm_tx "$url" "$stage" initiate "$staking" "$data" 0)
        unsigned=$(receipt_warp_message "$receipt")
        height=$(epoch_height "$uri/ext/bc/P/proposervm")
        signed=$(proof "$stage/weight-proof.hex" "$aggregator" "$unsigned" "" "$subnet" "$height")
        URI=$uri VALIDATION_ID=$(cb58_encode "$validation_hex")
        pchain_step "$uri" "$stage" weight l1_validator_removed 'Set L1 Validator Weight TX: ([[:alnum:]]+)' -- \
            l1 set-validator-weight --message "$signed" >/dev/null

        height=$(observe_pchain "$uri" "$url" "$stage")
        ack=$(registration_message "$validation_hex" false)
        # The justification names the validator by its position in the
        # conversion.
        justification=$(removal_justification "$subnet_hex" "$i")
        signed_ack=$(proof "$stage/ack-proof.hex" "$aggregator" "$ack" "$justification" "$subnet" "$height")
        invoke "$url" "$stage" completeValidatorRemoval "$contract" "$staking" "$(predicate "$signed_ack")" 0 >/dev/null
        [[ $(view "$url" ValidatorManager "$manager" getNodeValidationID "$node_hex" | jq -r '.[0]') == 0x$(printf '%064d' 0) ]] ||
            die "bootstrap removal of $node_hex not reflected by the manager"
    done

    expected=$(for index in "$@"; do
        jq -er --argjson i "$index" '.nodes[$i].node_id // error("invalid final validator index \($i)")' "$STATE/network/network.json"
    done | jq -Rsc 'split("\n") | map(select(. != "")) | sort')
    current=$(rpc "$uri/ext/bc/P" platform.getCurrentValidators "$(jq -cn --arg id "$subnet" '{subnetID: $id}')" |
        jq -c '[.validators[] | {nodeID, validationID}]')
    [[ $(jq -c 'map(.nodeID) | sort' <<<"$current") == "$expected" ]] ||
        die "the P-Chain validators $(jq -c 'map(.nodeID)' <<<"$current") differ from the staked validators $expected"
    for id in $(jq -r '.[].validationID' <<<"$current"); do
        hex=0x$(cb58_decode "$id")
        [[ $(validator_state "$url" "$manager" "$hex") == "$ACTIVE $VALIDATOR_WEIGHT" ]] ||
            die "final validator $id not active at the expected weight"
        [[ $(view "$url" "$contract" "$staking" getStakingValidator "$hex" | jq -r '.[0][0] | ascii_downcase') == "${EWOQ_ADDRESS,,}" ]] ||
            die "final validator $id has not the expected staking owner"
        rpc "$uri/ext/bc/P" platform.getL1Validator "$(jq -cn --arg id "$id" '{validationID: $id}')" |
            jq -e '(.balance | tonumber) > 0' >/dev/null || die "final validator $id has no operating balance"
    done
    if [[ $mode == native-pos ]]; then
        locked=$(cast balance "$staking" -r "$url")
    else
        token=$(jq -r .contractAddress "$dir/erc20-pos/deploy-StakingToken.receipt.json")
        locked=$(view "$url" StakingToken "$token" balanceOf "$staking" | jq -r '.[0]')
    fi
    # Wei amounts exceed 64 bits; compare them as text.
    [[ $locked == "$(tokens "$#")" ]] || die "locked stake mismatch: got $locked want $(tokens "$#")"
    jq -n --arg mode "$mode" --argjson validators "$current" --arg staking "$staking" --arg manager "$manager" \
        '{fully_pos: true, mode: $mode, validators: $validators, staking: $staking, manager: $manager, rpc_node_promoted: false}' |
        atomic_write "$dir/staking.json"
}

main() {
    require_tools_service
    writer_lock
    case ${1:-} in
    migrate)
        (($# == 7)) || die "migrate requires primary URI, L1 RPC, state directory, aggregator URI, node index and staking mode"
        migrate "${@:2}"
        ;;
    finalize)
        (($# >= 7)) || die "finalize requires primary URI, L1 RPC, state directory, aggregator URI, staking mode and node indexes"
        finalize "${@:2}"
        ;;
    *) die "usage: staking.sh migrate|finalize ..." ;;
    esac
}

# Run only when executed, so that a test can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
