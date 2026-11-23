#!/usr/bin/env bash
# The first steps of the L1 lifecycle (ACP-77). See docs/l1-lifecycle.md.
#
#   l1.sh create  URI DIR GENESIS CHAIN_ID OVERRIDES BRIDGE CHAIN_CONFIG SUBNET_CONFIG
#   l1.sh convert URI DIR MANAGER_CHAIN MANAGER NETWORK_DIR WEIGHT INDEX...
#   l1.sh manager URI RPC DIR AGGREGATOR
#
# URI is the URL of a Primary Network node, RPC the EVM RPC URL of the L1, DIR
# the state directory of the L1, and AGGREGATOR the URL of its signature
# aggregator. P-Chain transactions go through platform-cli, contract calls
# through cast (lib.sh).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ── create ──────────────────────────────────────────────────────────────────

# l1_genesis BASE CHAIN_ID OVERRIDES BRIDGE prints the Subnet-EVM genesis:
# the base file merged with the user overrides, with the chain ID of the
# package. With the bridge, the future NativeTokenRemote contract may mint the
# native token.
#
# An override merges into the base object by object; any other value,
# including a list, replaces the base value. A null changes nothing: YAML
# reads a key that holds only comments as null. Account keys of `alloc` are
# compared in lowercase without 0x, so an override replaces the base account
# of the same address. The header gasLimit follows config.feeConfig.gasLimit:
# Subnet-EVM refuses a genesis in which the two differ, and by then the chain
# exists on the P-Chain and cannot be changed.
l1_genesis() {
    local base=$1 chain_id=$2 overrides=$3 bridge=$4 minter=""
    if [[ $bridge == true ]]; then
        # Development key 10 deploys NativeTokenRemote as its first contract.
        minter=$(cast compute-address --nonce 0 "$(cast wallet address "$(dev_key 10)")" | grep -oE '0x[0-9a-fA-F]{40}')
    fi
    jq --argjson overrides "$overrides" --argjson chain_id "$chain_id" --arg minter "$minter" '
        def normalize: if (.alloc | type) == "object" then
            .alloc |= (to_entries
                | map(.key |= (ascii_downcase | ltrimstr("0x")))
                | if (map(.key) | length) != (map(.key) | unique | length)
                  then error("genesis alloc lists an account twice") else from_entries end)
            else . end;
        def merge($src): reduce ($src | to_entries[]) as $e (.;
            if $e.value == null then .
            elif ($e.value | type) == "object" and (.[$e.key] | type) == "object"
            then .[$e.key] |= merge($e.value)
            else .[$e.key] = $e.value end);
        normalize | merge($overrides | normalize)
        | if (.config | type) != "object" then error("genesis config must be an object") else . end
        | .config.chainId = $chain_id
        | (.config.feeConfig.gasLimit) as $limit
        | if ($limit | type) != "number" or $limit < 1 or $limit != ($limit | floor)
          then error("genesis config.feeConfig.gasLimit must be a positive whole number") else . end
        | .gasLimit = ("0x" + ([$limit | recurse(if . >= 16 then (. / 16 | floor) else empty end) | . % 16]
            | reverse | map("0123456789abcdef"[.:.+1]) | join("")))
        | if $minter != "" then .config.contractNativeMinterConfig =
            {blockTimestamp: 0, enabledAddresses: [$minter]} else . end' "$base"
}

# blockchain_on_subnet prints the blockchain of SUBNET if the P-Chain has one.
blockchain_on_subnet() {
    rpc "$URI/ext/bc/P" platform.getBlockchains | jq -r --arg subnet "$SUBNET" \
        '[.blockchains[] | select(.subnetID == $subnet) | .id] | if length == 1 then .[0] else "-" end'
}

create() {
    local uri=$1 dir=$2 base=$3 chain_id=$4 overrides=$5 bridge=$6 chain_config=$7 subnet_config=$8
    local subnet chain genesis
    local_only "$uri"
    [[ $chain_id =~ ^[0-9]+$ ]] || die "invalid chain ID $chain_id"
    mkdir -p "$dir"
    genesis=$(l1_genesis "$base" "$chain_id" "$overrides" "$bridge")
    if [[ -f $dir/genesis.json ]]; then
        # A repeated step must create the same chain.
        [[ $(jq -S . "$dir/genesis.json") == "$(jq -S . <<<"$genesis")" ]] ||
            die "journal input mismatch: the genesis differs from $dir/genesis.json"
    else
        echo "$genesis" | atomic_write "$dir/genesis.json"
    fi
    # The genesis file is the exact genesis of the chain on the P-Chain.
    subnet=$(pchain_step "$uri" "$dir" subnet - 'Subnet ID: ([[:alnum:]]+)' -- subnet create)
    URI=$uri SUBNET=$subnet
    chain=$(pchain_step "$uri" "$dir" chain blockchain_on_subnet 'Chain ID: ([[:alnum:]]+)' -- \
        chain create --subnet-id "$subnet" --genesis "$dir/genesis.json" --vm-id "$SUBNET_EVM_ID" --name "Avalanche Devnet")

    # Every node of the L1 mounts these files. AvalancheGo finds them by ID,
    # and the IDs exist only now, so Kurtosis cannot name the files itself:
    #   chains/<blockchain-id>/config.json   Subnet-EVM chain config
    #   subnets/<subnet-id>.json             subnet config
    jq -e 'type == "object"' <<<"$chain_config" >/dev/null || die "the chain config must be a JSON object"
    jq -e 'type == "object"' <<<"$subnet_config" >/dev/null || die "the subnet config must be a JSON object"
    jq . <<<"$chain_config" | atomic_write "$dir/config/chains/$chain/config.json"
    jq . <<<"$subnet_config" | atomic_write "$dir/config/subnets/$subnet.json"

    jq -n --arg subnet "$subnet" --arg chain "$chain" --arg sha "$(sha256sum "$dir/genesis.json" | cut -c1-64)" \
        '{version: 1, subnet_id: $subnet, blockchain_id: $chain, genesis_sha256: $sha}' | atomic_write "$dir/chain.json"
}

# ── convert ─────────────────────────────────────────────────────────────────

# converted prints the conversion of SUBNET if the P-Chain shows one.
converted() {
    rpc "$URI/ext/bc/P" platform.getSubnet "$(jq -cn --arg id "$SUBNET" '{subnetID: $id}')" |
        jq -r 'if .isL1 then "conversion:" + .conversionID else "-" end'
}

# convert turns the subnet into an L1 with a ConvertSubnetToL1Tx. The
# ValidatorManager lives at MANAGER on MANAGER_CHAIN ("self": the L1 itself).
# Each first validator, picked by its node index, gets WEIGHT and 100 AVAX on
# the P-Chain, from which the P-Chain takes its continuous validator fee. The
# EWOQ key owns the remaining balance and may deactivate the validator.
convert() {
    local uri=$1 dir=$2 manager_chain=$3 manager=$4 network=$5 weight=$6 subnet chain validators tx
    shift 6
    local_only "$uri"
    subnet=$(jq -r .subnet_id "$dir/chain.json")
    chain=$(jq -r .blockchain_id "$dir/chain.json")
    [[ $manager_chain != self ]] || manager_chain=$chain
    [[ $manager =~ ^0x[0-9a-fA-F]{40}$ ]] || die "manager must be a 20-byte hex address"
    [[ $weight =~ ^[1-9][0-9]*$ ]] || die "invalid conversion weight"
    (($# > 0)) || die "convert needs at least one validator index"
    # The P-Chain requires the validators sorted by node ID; the order is also
    # the index of each validator in the justification of its removal.
    validators=$(
        for index in "$@"; do
            [[ $index =~ ^[0-9]+$ ]] || die "invalid validator index $index"
            jq -ce --argjson i "$index" '.nodes[$i] // error("invalid validator index \($i)")' "$network/network.json"
        done | while read -r node; do
            jq -c --arg hex "$(cb58_decode "$(jq -r .node_id <<<"$node")")" --argjson weight "$weight" \
                '{node_id, node_id_hex: ("0x" + $hex), public_key: .pop.publicKey, pop: .pop.proofOfPossession, weight: $weight}' <<<"$node"
        done | jq -sc 'sort_by(.node_id_hex)'
    )
    URI=$uri SUBNET=$subnet
    tx=$(pchain_step "$uri" "$dir" conversion converted 'TX ID: ([[:alnum:]]+)' -- \
        subnet convert-to-l1 --subnet-id "$subnet" --chain-id "$manager_chain" --manager "$manager" \
        --validator-node-ids "$(jq -r 'map(.node_id) | join(",")' <<<"$validators")" \
        --validator-bls-public-keys "$(jq -r 'map(.public_key) | join(",")' <<<"$validators")" \
        --validator-bls-pops "$(jq -r 'map(.pop) | join(",")' <<<"$validators")" \
        --validator-weights "$(jq -r 'map(.weight) | join(",")' <<<"$validators")" \
        --validator-balance 100)
    jq -n --arg tx "$tx" --arg chain "$manager_chain" --arg manager "$manager" --argjson validators "$validators" \
        '{tx_id: $tx, manager_chain: $chain, manager: $manager, validators: $validators}' | atomic_write "$dir/conversion.json"
}

# ── manager ─────────────────────────────────────────────────────────────────

# manager deploys the ValidatorManager of an L1 and loads the first validator
# set into it. From then on the contract controls the validator set: the owner
# adds and removes validators (Proof of Authority).
#
# The contract must land on the address named in the conversion, so the EWOQ
# account deploys the ValidatorMessages library first and the manager second.
# initializeValidatorSet needs proof of the conversion: a Warp message from the
# P-Chain, signed by the first validators of the L1.
manager() {
    local uri=$1 url=$2 dir=$3 aggregator=$4 subnet chain library address conversion_id message height signed
    local subnet_hex chain_hex validators
    subnet=$(jq -r .subnet_id "$dir/chain.json")
    chain=$(jq -r .blockchain_id "$dir/chain.json")
    [[ $(jq -r .manager_chain "$dir/conversion.json") == "$chain" ]] || die "this manager profile requires own-L1 placement"
    [[ $url == */ext/bc/$chain/rpc ]] || die "manager RPC does not match the blockchain of the deployment"
    library=$(deploy "$url" "$dir" ValidatorMessages "" "")
    address=$(deploy "$url" "$dir" ValidatorManager "$library" "" 0)
    [[ ${address,,} == "$(jq -r '.manager | ascii_downcase' "$dir/conversion.json")" ]] ||
        die "manager address differs from the conversion: $address"
    subnet_hex=0x$(cb58_decode "$subnet")
    chain_hex=0x$(cb58_decode "$chain")

    # The EWOQ account owns the manager. Per churn period of 1 second, the
    # validator set may change by at most 20% of its total weight; 20 is the
    # maximum the contract accepts. The bootstrap validators of a PoS L1 are
    # sized for this limit (see src/l1/launcher.star).
    invoke "$url" "$dir" initialize ValidatorManager "$address" "" "($EWOQ_ADDRESS,$subnet_hex,1,20)" >/dev/null

    conversion_id=$(rpc "$uri/ext/bc/P" platform.getSubnet "$(jq -cn --arg id "$subnet" '{subnetID: $id}')" | jq -r .conversionID)
    message=$(conversion_message "$(cb58_decode "$conversion_id")")
    height=$(epoch_height "$(base_uri "$url")/ext/bc/$chain/proposervm")
    signed=$(proof "$dir/conversion-proof.hex" "$aggregator" "$message" "$subnet_hex" "$subnet" "$height")

    validators=$(jq -r '[.validators[] | "(\(.node_id_hex),\(.public_key),\(.weight))"] | join(",")' "$dir/conversion.json")
    invoke "$url" "$dir" initializeValidatorSet ValidatorManager "$address" "$(predicate "$signed")" \
        "($subnet_hex,$chain_hex,$address,[$validators])" 0 >/dev/null
    jq -n --arg address "$address" --arg library "$library" --argjson count "$(jq '.validators | length' "$dir/conversion.json")" \
        '{address: $address, library: $library, mode: "poa", initialized: true, location: "self", bootstrap_validators: $count}' |
        atomic_write "$dir/manager.json"
}

main() {
    require_tools_service
    writer_lock
    case ${1:-} in
    create)
        (($# == 9)) || die "create requires URI, state directory, genesis file, chain ID, genesis overrides, bridge boolean, chain config and subnet config"
        create "${@:2}"
        ;;
    convert)
        (($# >= 8)) || die "convert requires URI, state directory, manager chain, address, network directory, validator weight, node indexes"
        convert "${@:2}"
        ;;
    manager)
        (($# == 5)) || die "manager requires primary URI, L1 RPC, state directory, aggregator URI"
        manager "${@:2}"
        ;;
    *) die "usage: l1.sh create|convert|manager ..." ;;
    esac
}

# Run only when executed, so that a test can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
