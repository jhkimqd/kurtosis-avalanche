#!/usr/bin/env bash
# The ICM token bridge between the C-Chain and one L1.
#
#   bridge.sh deploy   URI RPC DIR   deploy the contracts, write the relayer config
#   bridge.sh activate URI RPC DIR   register the L1 side with the C-Chain side
#                                    through the relayer, then lock CASH as
#                                    collateral for the L1's genesis supply
#   bridge.sh smoke    URI RPC DIR   bridge tokens to the L1 and spend them
#
# URI is the URL of a Primary Network node, RPC the EVM RPC URL of the L1, and
# DIR the state directory of the L1. The bridge state is in DIR/bridge.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Public development keys: the private key is the number. Each key has one job,
# so that its first contract always lands on the same address:
#
#    8  receives the bridged tokens of the smoke test
#    9  deploys TeleporterMessenger
#   10  deploys NativeTokenRemote
RECIPIENT_KEY=$(dev_key 8)
MESSENGER_KEY=$(dev_key 9)
REMOTE_KEY=$(dev_key 10)
ZERO_ADDRESS=0x0000000000000000000000000000000000000000

# The contracts on the C-Chain are shared by all L1s, so their journals are
# shared too.
C_CHAIN_DIR=$STATE/c-chain

state() { jq -r ".$1" "$BRIDGE/contracts.json"; }

# token_balance URL TOKEN OWNER prints the CASH balance of OWNER.
token_balance() { view "$1" CashToken "$2" balanceOf "$3" | jq -r '.[0]'; }

# deploy_bridge deploys the ICM and token bridge contracts.
#
# Both chains get a TeleporterMessenger at the same address (deployed by
# development key 9) and a TeleporterRegistry. The C-Chain gets the CASH token
# and its ERC20TokenHome. The L1 gets the NativeTokenRemote (deployed by
# development key 10) at the address that the genesis allows to mint. It also
# funds a relayer account on both chains and writes the relayer config.
deploy_bridge() {
    local uri=$1 url=$2 dir=$3 c_rpc=$1/ext/bc/C/rpc subnet chain c_chain supply messenger_deployer remote_deployer
    local relay_key relay messenger expected c_code l_code entries c_registry l_registry token home remote settings
    local balance network_url network_dir address want got
    subnet=$(jq -r .subnet_id "$dir/chain.json")
    chain=$(jq -r .blockchain_id "$dir/chain.json")
    c_chain=$(rpc "$uri/ext/info" info.getBlockchainID '{"alias":"C"}' | jq -r .blockchainID)
    # The genesis supply of the L1 is the sum of its genesis balances.
    supply=0
    for balance in $(jq -r '.alloc[].balance' "$dir/genesis.json"); do
        supply=$(big_add "$supply" "$(cast to-dec "$balance")")
    done
    messenger_deployer=$(cast wallet address "$MESSENGER_KEY")
    remote_deployer=$(cast wallet address "$REMOTE_KEY")
    # One relayer account per L1, derived from its blockchain ID.
    relay_key=$(cast keccak "kurtosis-devnet-relayer:$chain")
    relay=$(cast wallet address "$relay_key")
    for network in "$c_rpc $C_CHAIN_DIR" "$url $BRIDGE"; do
        read -r network_url network_dir <<<"$network"
        evm_tx "$network_url" "$network_dir" fund-messenger "$messenger_deployer" 0x "$(tokens 5)" >/dev/null
        evm_tx "$network_url" "$network_dir" "fund-relayer-$chain" "$relay" 0x "$(tokens 10)" >/dev/null
        messenger=$(deploy "$network_url" "$network_dir" TeleporterMessenger "" "$MESSENGER_KEY")
        expected=$(cast compute-address --nonce 0 "$messenger_deployer" | grep -oE '0x[0-9a-fA-F]{40}')
        [[ ${messenger,,} == "${expected,,}" ]] || die "messenger deployment address mismatch"
    done
    c_code=$(cast code "$messenger" -r "$c_rpc")
    l_code=$(cast code "$messenger" -r "$url")
    [[ $c_code != 0x && $c_code == "$l_code" ]] || die "messenger runtime code differs"
    entries="[(1,$messenger)]"
    c_registry=$(deploy "$c_rpc" "$C_CHAIN_DIR" TeleporterRegistry "" "" "$entries")
    l_registry=$(deploy "$url" "$BRIDGE" TeleporterRegistry "" "" "$entries")
    token=$(deploy "$c_rpc" "$C_CHAIN_DIR" CashToken "" "")
    home=$(deploy "$c_rpc" "$C_CHAIN_DIR" ERC20TokenHome "" "" "$c_registry" "$EWOQ_ADDRESS" 1 "$token" 18)
    evm_tx "$url" "$BRIDGE" fund-remote "$remote_deployer" 0x "$(tokens 1)" >/dev/null
    settings="($l_registry,$EWOQ_ADDRESS,1,0x$(cb58_decode "$c_chain"),$home,18)"
    remote=$(deploy "$url" "$BRIDGE" NativeTokenRemote "" "$REMOTE_KEY" "$settings" CASH "$supply" 0)
    expected=$(cast compute-address --nonce 0 "$remote_deployer" | grep -oE '0x[0-9a-fA-F]{40}')
    [[ ${remote,,} == "${expected,,}" ]] || die "remote address differs from the genesis minter"
    # The genesis lets the remote mint (role 1, enabled), not administer.
    for pair in "$remote 1" "$EWOQ_ADDRESS 0"; do
        read -r address want <<<"$pair"
        got=$(cast call "$NATIVE_MINTER_PRECOMPILE" "readAllowList(address)(uint256)" "$address" -r "$url")
        [[ $got == "$want" ]] || die "unexpected native minter role $got of $address"
    done
    jq -n --arg messenger "$messenger" --arg c_registry "$c_registry" --arg l_registry "$l_registry" \
        --arg token "$token" --arg home "$home" --arg remote "$remote" --arg c_chain "$c_chain" --arg chain "$chain" \
        --arg supply "$supply" \
        '{Messenger: $messenger, CRegistry: $c_registry, LRegistry: $l_registry, Token: $token, Home: $home,
          Remote: $remote, CChain: $c_chain, LChain: $chain, InitialSupply: $supply}' | atomic_write "$BRIDGE/contracts.json"

    # Both chains are sources and destinations. The relayer keeps its progress
    # in /data, so it relays the blocks it missed after a restart.
    jq -n --arg uri "$uri" --arg c_rpc "$c_rpc" --arg url "$url" --arg c_chain "$c_chain" --arg chain "$chain" \
        --arg subnet "$subnet" --arg primary "$(cb58_encode "$(printf '%064d' 0)")" --arg messenger "$messenger" \
        --arg relay "$relay" --arg key "$(strip0x "$relay_key")" '
        def ws: sub("^http://"; "ws://") | sub("/rpc$"; "/ws");
        [{rpc: $c_rpc, chain: $c_chain, subnet: $primary}, {rpc: $url, chain: $chain, subnet: $subnet}] as $networks
        | {
            "log-level": "info", "api-port": 9091, "metrics-port": 9092, "allow-private-ips": true,
            "storage-location": "/data", "process-missed-blocks": true,
            "p-chain-api": {"base-url": $uri}, "info-api": {"base-url": $uri},
            "source-blockchains": [$networks[] | {
              "subnet-id": .subnet, "blockchain-id": .chain,
              "rpc-endpoint": {"base-url": .rpc}, "ws-endpoint": {"base-url": (.rpc | ws)},
              "message-contracts": {($messenger): {"message-format": "teleporter", settings: {"reward-address": $relay}}}}],
            "destination-blockchains": [$networks[] | {
              "subnet-id": .subnet, "blockchain-id": .chain,
              "rpc-endpoint": {"base-url": .rpc}, "account-private-key": $key}]
          }' | atomic_write "$BRIDGE/relayer/config.json"
}

# activate registers the L1 side with the C-Chain side, then adds collateral
# for the genesis supply of the L1.
activate() {
    local uri=$1 url=$2 c_rpc=$1/ext/bc/C/rpc chain_hex remote home token supply until
    chain_hex=0x$(cb58_decode "$(state LChain)")
    remote=$(state Remote)
    home=$(state Home)
    token=$(state Token)
    supply=$(state InitialSupply)
    invoke "$url" "$BRIDGE" registerWithHome NativeTokenRemote "$remote" "" "($ZERO_ADDRESS,0)" >/dev/null
    until=$(deadline "$WAIT_SECONDS")
    until [[ $(view "$c_rpc" ERC20TokenHome "$home" getRemoteTokenTransferrerSettings "$chain_hex" "$remote" | jq -r '.[0][0]') == true ]]; do
        expired "$until" && die "the relayer did not deliver the remote registration"
        sleep 1
    done
    invoke "$c_rpc" "$BRIDGE/collateral" approve CashToken "$token" "" "$home" "$supply" >/dev/null
    invoke "$c_rpc" "$BRIDGE" addCollateral ERC20TokenHome "$home" "" "$chain_hex" "$remote" "$supply" >/dev/null
    big_ge "$(token_balance "$c_rpc" "$token" "$home")" "$supply" || die "genesis collateral missing"
    jq -n --arg supply "$supply" '{registered: true, genesis_backing: $supply}' | atomic_write "$BRIDGE/collateral.json"
}

# smoke proves that the bridge works. It sends 7 CASH from the C-Chain to a new
# account on the L1, waits for the relayer to deliver them as 7 native tokens,
# and pays the gas of an L1 transfer with them. It reconciles the balances on
# both chains.
smoke() {
    local uri=$1 url=$2 c_rpc=$1/ext/bc/C/rpc chain_hex remote home token recipient amount input until
    local sender escrow receipt fee balance expected
    chain_hex=0x$(cb58_decode "$(state LChain)")
    remote=$(state Remote)
    home=$(state Home)
    token=$(state Token)
    recipient=$(cast wallet address "$RECIPIENT_KEY")
    amount=$(tokens 7)
    if [[ ! -f $BRIDGE/smoke-before.json ]]; then
        [[ $(cast balance "$recipient" -r "$url") == 0 ]] || die "the bridge smoke recipient must begin unfunded"
        jq -n --arg sender "$(token_balance "$c_rpc" "$token" "$EWOQ_ADDRESS")" \
            --arg escrow "$(token_balance "$c_rpc" "$token" "$home")" \
            '{Sender: $sender, Escrow: $escrow, Recipient: "0"}' | atomic_write "$BRIDGE/smoke-before.json"
    fi
    invoke "$c_rpc" "$BRIDGE/smoke" approve CashToken "$token" "" "$home" "$amount" >/dev/null
    input="($chain_hex,$remote,$recipient,$token,0,0,300000,$ZERO_ADDRESS)"
    invoke "$c_rpc" "$BRIDGE/smoke" send ERC20TokenHome "$home" "" "$input" "$amount" >/dev/null
    # Once the spend is prepared it may already be accepted; evm_tx reconciles
    # its journal, and the delivered balance may already be spent.
    if [[ ! -f $BRIDGE/spend.evm.json ]]; then
        until=$(deadline "$WAIT_SECONDS")
        until [[ $(cast balance "$recipient" -r "$url") == "$amount" ]]; do
            expired "$until" && die "the relayer did not deliver the bridged tokens"
            sleep 1
        done
    fi
    sender=$(token_balance "$c_rpc" "$token" "$EWOQ_ADDRESS")
    escrow=$(token_balance "$c_rpc" "$token" "$home")
    [[ $(big_add "$sender" "$amount") == "$(jq -r .Sender "$BRIDGE/smoke-before.json")" &&
        $escrow == "$(big_add "$(jq -r .Escrow "$BRIDGE/smoke-before.json")" "$amount")" ]] ||
        die "bridge escrow reconciliation failed"
    [[ $(view "$url" NativeTokenRemote "$remote" getIsCollateralized | jq -r '.[0]') == true ]] ||
        die "the remote remains uncollateralized"
    receipt=$(evm_tx "$url" "$BRIDGE" spend "$EWOQ_ADDRESS" 0x 1 "" "$RECIPIENT_KEY")
    # 7 tokens fit in 64 bits, so bash arithmetic is exact here.
    fee=$(($(jq -r .gasUsed "$receipt") * $(jq -r .effectiveGasPrice "$receipt")))
    balance=$(cast balance "$recipient" -r "$url")
    expected=$((amount - 1 - fee))
    ((fee > 0 && balance == expected)) || die "bridged native gas proof failed: balance $balance, expected $expected"
    jq -n --arg amount "$amount" --arg supply "$(state InitialSupply)" --arg fee "$fee" --arg recipient "$recipient" \
        '{bridge_operational: true, amount: $amount, genesis_backing: $supply, native_gas_paid: $fee, recipient: $recipient}' |
        atomic_write "$BRIDGE/verified.json"
}

main() {
    require_tools_service
    writer_lock
    (($# == 4)) || die "usage: bridge.sh deploy|activate|smoke URI RPC DIR"
    local_only "$2"
    BRIDGE=$4/bridge
    case $1 in
    deploy) deploy_bridge "$2" "$3" "$4" ;;
    activate) activate "$2" "$3" ;;
    smoke) smoke "$2" "$3" ;;
    *) die "usage: bridge.sh deploy|activate|smoke URI RPC DIR" ;;
    esac
}

# Run only when executed, so that a test can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
