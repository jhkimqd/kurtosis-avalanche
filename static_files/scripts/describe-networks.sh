#!/usr/bin/env bash
# Describe the devnet for its users, one directory per network:
#
#   bash describe-networks.sh <output-dir> [deployment-manifest-json]
#
# The package runs this script in the tools service at the end of a
# deployment, with the output directory /opt/networks and the deployment
# manifest (main.star). Run it again without the manifest to refresh the files
# from the network; it then reads <output-dir>/deployment.json:
#
#   kurtosis service exec <enclave> tools 'bash /fixtures/scripts/describe-networks.sh /opt/networks'
#
# It writes:
#
#   <output-dir>/README.md         the list of networks
#   <output-dir>/deployment.json   the deployment manifest
#   <output-dir>/primary-network/  the P-, X-, and C-Chain
#   <output-dir>/<l1>/             one directory per L1, such as l1-0
#
# Each network directory holds README.md (for a reader), network.json (IDs and
# RPC URLs), validators.json (platform.getCurrentValidators), genesis.json, and
# accounts.json (the development keys that the package uses on that network).
# primary-network/ adds blockchains.json (platform.getBlockchains); an L1
# directory adds subnet.json (platform.getSubnet).
#
# It needs bash, curl, and jq. STATE_DIR (default /state) is the state of the
# Go tools: the genesis files and the bridge relayer configuration.
set -euo pipefail

out=${1:?Usage: $0 <output-dir> [deployment-manifest-json]}
out=${out%/}
state=${STATE_DIR:-/state}
# The script replaces the output directory. It refuses one that holds files it
# did not write.
if [[ -z $out || ( -d $out && -n $(ls -A "$out") && ! -f $out/deployment.json ) ]]; then
    echo "Refusing to replace $out: it is not a description of this script" >&2
    exit 1
fi

# ── Constants ────────────────────────────────────────────────────────────────

# The P-Chain is not in platform.getBlockchains. Its blockchain ID, the ID of
# the Primary Network, and the ID of its VM are all the empty ID.
EMPTY_ID=11111111111111111111111111111111LpoYY

# The public EWOQ key funds the genesis of every chain (tools/main.go). The
# P-Chain and X-Chain addresses use the prefix "custom" of network 88888.
EWOQ_KEY=0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027
EWOQ_CB58_KEY=PrivateKey-ewoqjP7PxY4yr3iLTpLisriqt94hdyDFNgchSxGGztUrTXtNN
EWOQ_ADDRESS=0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC
EWOQ_P_ADDRESS=P-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p
EWOQ_X_ADDRESS=X-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p

# Development keys of the bridge: the private key is the number itself
# (devKey in tools/bridge.go).
BRIDGE_RECIPIENT_KEY=0x0000000000000000000000000000000000000000000000000000000000000008
BRIDGE_RECIPIENT_ADDRESS=0xF1F6619B38A98d6De0800F1DefC0a6399eB6d30C
MESSENGER_DEPLOYER_KEY=0x0000000000000000000000000000000000000000000000000000000000000009
MESSENGER_DEPLOYER_ADDRESS=0xF7Edc8FA1eCc32967F827C9043FcAe6ba73afA5c
TOKEN_REMOTE_DEPLOYER_KEY=0x000000000000000000000000000000000000000000000000000000000000000a
TOKEN_REMOTE_DEPLOYER_ADDRESS=0x4CCeBa2d7D2B4fdcE4304d3e09a1fea9fbEb1528

# ── Helpers ──────────────────────────────────────────────────────────────────

# rpc <url> <method> <params-json>: one JSON-RPC call; prints the result.
rpc() {
    local response
    response=$(curl -sS -m 30 -X POST -H 'content-type: application/json' \
        --data "$(jq -cn --arg method "$2" --argjson params "$3" \
            '{jsonrpc: "2.0", id: 1, method: $method, params: $params}')" "$1") ||
        { echo "$2: no answer from $1" >&2; return 1; }
    jq -e '.result' <<<"$response" 2>/dev/null ||
        { echo "$2: $(jq -c '.error // .' <<<"$response" 2>/dev/null || echo "$response")" >&2; return 1; }
}

# account <name> <role> <private-key> <evm-address>: one entry of accounts.json.
account() {
    jq -n --arg name "$1" --arg role "$2" --arg key "$3" --arg address "$4" \
        '{name: $name, role: $role, private_key: $key, evm_address: $address}'
}

ewoq() {
    account ewoq "$1" "$EWOQ_KEY" "$EWOQ_ADDRESS" | jq \
        --arg cb58 "$EWOQ_CB58_KEY" --arg p "$EWOQ_P_ADDRESS" --arg x "$EWOQ_X_ADDRESS" \
        '. + {p_chain_private_key: $cb58, p_chain_address: $p, x_chain_address: $x}'
}

# relayer <l1-name>: the account of the bridge relayer of one L1, from the
# relayer configuration that the Go tools wrote. The relayer pays its gas from
# this key and names the same account as its reward address.
relayer() {
    local config=$state/$1/bridge/relayer/config.json
    account "relayer-$1" "Pays the gas of the ICM relayer $1-relayer, which delivers the bridge messages between the C-Chain and $1. Funded on both chains." \
        "0x$(jq -r '."destination-blockchains"[0]."account-private-key"' "$config")" \
        "$(jq -r '[."source-blockchains"[0]."message-contracts"[].settings."reward-address"][0]' "$config")"
}

# markdown_accounts <accounts.json>: the accounts as a Markdown table.
markdown_accounts() {
    echo "| Name | EVM address | Private key | Role |"
    echo "| --- | --- | --- | --- |"
    jq -r '.[] | "| \(.name) | `\(.evm_address)` | `\(.private_key)` | \(.role) |"' "$1"
}

# ── Inputs ───────────────────────────────────────────────────────────────────

work=$(mktemp -d "$out.XXXXXX")
trap 'rm -rf "$work"' EXIT
if [[ $# -ge 2 ]]; then
    jq . <<<"$2" >"$work/deployment.json"
elif [[ -f $out/deployment.json ]]; then
    cp "$out/deployment.json" "$work/deployment.json"
else
    echo "No deployment manifest: pass it, or keep $out/deployment.json" >&2
    exit 1
fi
manifest=$work/deployment.json
primary=$(jq -r .primary_network.rpc_url "$manifest")
network_id=$(rpc "$primary/ext/info" info.getNetworkID '{}' | jq -r .networkID)
if [[ $network_id != "$(jq -r .primary_network.network_id "$manifest")" ]]; then
    echo "$primary serves network $network_id, not the network of the manifest" >&2
    exit 1
fi
blockchains=$(rpc "$primary/ext/bc/P" platform.getBlockchains '{}')
bridged=$(jq -r '[.l1s[] | select(.bridge != null) | .name] | join(", ")' "$manifest")

# ── Primary Network ──────────────────────────────────────────────────────────

dir=$work/primary-network
mkdir -p "$dir"
jq . <<<"$blockchains" >"$dir/blockchains.json"
rpc "$primary/ext/bc/P" platform.getCurrentValidators '{}' >"$dir/validators.json"
cp "$state/network/genesis.json" "$dir/genesis.json"
jq --argjson blockchains "$blockchains" --arg empty "$EMPTY_ID" '
    .primary_network as $p
    | ($p.host // {}) as $h
    | def chain($name): $blockchains.blockchains[] | select(.subnetID == $empty and .name == $name);
    {
        name: "primary-network",
        network_id: $p.network_id,
        subnet_id: $empty,
        chains: [
            {name: "P-Chain", blockchain_id: $empty, vm_id: $empty,
             rpc_url: $p.p_chain_rpc_url, host_rpc_url: $h.p_chain_rpc_url},
            (chain("X-Chain") | {name, blockchain_id: .id, vm_id: .vmID,
             rpc_url: $p.x_chain_rpc_url, host_rpc_url: $h.x_chain_rpc_url}),
            (chain("C-Chain") | {name, blockchain_id: .id, vm_id: .vmID, evm_chain_id: $p.c_chain_id,
             rpc_url: $p.c_chain_rpc_url, ws_url: $p.c_chain_ws_url,
             host_rpc_url: $h.c_chain_rpc_url, host_ws_url: $h.c_chain_ws_url})
        ]
    }' "$manifest" >"$dir/network.json"

role="Funded at genesis on the P-, X-, and C-Chain. Signs every setup transaction on the P-Chain and the C-Chain."
[[ -z $bridged ]] || role+=" Holds the CASH test token, and is the TeleporterManager of its ERC20TokenHome on the C-Chain."
{
    ewoq "$role"
    if [[ -n $bridged ]]; then
        account messenger-deployer "Deploys TeleporterMessenger on the C-Chain and on each L1 with a bridge ($bridged), so that it has the same address everywhere." \
            "$MESSENGER_DEPLOYER_KEY" "$MESSENGER_DEPLOYER_ADDRESS"
        for name in $(jq -r '.l1s[] | select(.bridge != null) | .name' "$manifest"); do relayer "$name"; done
    fi
} | jq -s . >"$dir/accounts.json"

{
    echo "# Primary Network"
    echo
    echo "The local stand-in for Avalanche Mainnet. Network ID \`$network_id\`. Its validators run the P-Chain (staking and the registry of every L1), the X-Chain (assets), and the C-Chain (EVM)."
    echo
    echo "| Chain | Blockchain ID | EVM chain ID | RPC URL in the enclave | RPC URL on the host |"
    echo "| --- | --- | --- | --- | --- |"
    jq -r '.chains[] | "| \(.name) | `\(.blockchain_id)` | \(.evm_chain_id // "") | `\(.rpc_url)` | \(if .host_rpc_url then "`\(.host_rpc_url)`" else "" end) |"' "$dir/network.json"
    echo
    echo "The C-Chain WebSocket is \`$(jq -r .primary_network.c_chain_ws_url "$manifest")\`. The host URLs are empty when \`rpc_port\` is 0."
    echo
    echo "## Accounts"
    echo
    echo "Public development keys: anyone can derive them. Never send them value on a public network."
    echo
    markdown_accounts "$dir/accounts.json"
    echo
    echo "EWOQ on the P-Chain: \`$EWOQ_P_ADDRESS\`; on the X-Chain: \`$EWOQ_X_ADDRESS\`. P-Chain and X-Chain tools take its key as \`$EWOQ_CB58_KEY\`."
    echo
    echo "## Files"
    echo
    echo "| File | Content |"
    echo "| --- | --- |"
    echo "| \`network.json\` | IDs and RPC URLs of the P-, X-, and C-Chain. |"
    echo "| \`blockchains.json\` | \`platform.getBlockchains\`: every blockchain that the P-Chain knows, the L1s included. |"
    echo "| \`validators.json\` | \`platform.getCurrentValidators\` of the Primary Network. |"
    echo "| \`genesis.json\` | The Primary Network genesis. |"
    echo "| \`accounts.json\` | The development accounts above, with their private keys. |"
} >"$dir/README.md"

# ── Each L1 ──────────────────────────────────────────────────────────────────

for ((i = 0; i < $(jq '.l1s | length' "$manifest"); i++)); do
    l1=$(jq ".l1s[$i]" "$manifest")
    name=$(jq -r .name <<<"$l1")
    subnet_id=$(jq -r .subnet_id <<<"$l1")
    blockchain_id=$(jq -r .blockchain_id <<<"$l1")
    mode=$(jq -r .validator_management <<<"$l1")
    has_bridge=$(jq -r '.bridge != null' <<<"$l1")
    dir=$work/$name
    mkdir -p "$dir"

    chain=$(jq --arg id "$blockchain_id" '.blockchains[] | select(.id == $id)' <<<"$blockchains")
    if [[ -z $chain ]]; then
        echo "The P-Chain does not list blockchain $blockchain_id of $name" >&2
        exit 1
    fi
    rpc "$primary/ext/bc/P" platform.getSubnet "$(jq -cn --arg id "$subnet_id" '{subnetID: $id}')" >"$dir/subnet.json"
    rpc "$primary/ext/bc/P" platform.getCurrentValidators "$(jq -cn --arg id "$subnet_id" '{subnetID: $id}')" >"$dir/validators.json"
    cp "$state/$name/genesis.json" "$dir/genesis.json"
    jq --argjson chain "$chain" '
        {name, chain_name: $chain.name, subnet_id, blockchain_id, vm_id: $chain.vmID, evm_chain_id,
         rpc_url: .rpc_urls[0], ws_url: .ws_urls[0], host_rpc_url: .host.rpc_url, host_ws_url: .host.ws_url,
         rpc_urls, ws_urls, validator_management, validator_manager_address}
        + (if .staking_manager_address then {staking_manager_address} else {} end)
        + (if .bridge then {bridge} else {} end)' <<<"$l1" >"$dir/network.json"

    role="Funded in the L1 genesis. Signs every setup transaction on $name."
    if [[ $mode == poa ]]; then
        role+=" Owns the ValidatorManager, so it adds and removes validators (Proof of Authority)."
    else
        role+=" Owns every validator of the L1 and receives its rewards. The staking manager owns the ValidatorManager ($mode)."
    fi
    [[ $has_bridge == false ]] || role+=" Is the TeleporterManager of NativeTokenRemote."
    {
        ewoq "$role"
        if [[ $has_bridge == true ]]; then
            account bridge-recipient "Receives the tokens of the bridge smoke test on $name, and spends one wei of them." \
                "$BRIDGE_RECIPIENT_KEY" "$BRIDGE_RECIPIENT_ADDRESS"
            account messenger-deployer "Deploys TeleporterMessenger, at the same address as on the C-Chain." \
                "$MESSENGER_DEPLOYER_KEY" "$MESSENGER_DEPLOYER_ADDRESS"
            account token-remote-deployer "Deploys NativeTokenRemote, at the address that the L1 genesis allows to mint the native token." \
                "$TOKEN_REMOTE_DEPLOYER_KEY" "$TOKEN_REMOTE_DEPLOYER_ADDRESS"
            relayer "$name"
        fi
    } | jq -s . >"$dir/accounts.json"

    {
        echo "# $name"
        echo
        echo "An Avalanche L1: a Subnet-EVM blockchain with its own validators ($mode). The P-Chain of the Primary Network registers it."
        echo
        echo "| | |"
        echo "| --- | --- |"
        jq -r '
            ["Blockchain ID", "`\(.blockchain_id)`"], ["Subnet ID", "`\(.subnet_id)`"], ["VM ID", "`\(.vm_id)`"],
            ["EVM chain ID", "\(.evm_chain_id)"], ["RPC URL in the enclave", "`\(.rpc_url)`"],
            ["RPC URL on the host", (if .host_rpc_url then "`\(.host_rpc_url)`" else "none: `rpc_port` is 0" end)],
            ["WebSocket in the enclave", "`\(.ws_url)`"], ["ValidatorManager", "`\(.validator_manager_address)`"],
            (if .staking_manager_address then ["Staking manager", "`\(.staking_manager_address)`"] else empty end)
            | "| \(.[0]) | \(.[1]) |"' "$dir/network.json"
        if [[ $(jq '.rpc_urls | length' "$dir/network.json") -gt 1 ]]; then
            echo
            echo "Every RPC node, in the enclave: $(jq -r '[.rpc_urls[] | "`\(.)`"] | join(", ")' "$dir/network.json")."
        fi
        echo
        echo "## Accounts"
        echo
        echo "Public development keys: anyone can derive them. Never send them value on a public network."
        echo
        markdown_accounts "$dir/accounts.json"
        echo
        echo "## Files"
        echo
        echo "| File | Content |"
        echo "| --- | --- |"
        echo "| \`network.json\` | IDs, RPC URLs, and contract addresses of the L1$([[ $has_bridge == false ]] || echo ", bridge contracts included"). |"
        echo "| \`subnet.json\` | \`platform.getSubnet\`: the conversion to an L1 and the ValidatorManager. |"
        echo "| \`validators.json\` | \`platform.getCurrentValidators\` of the L1. |"
        echo "| \`genesis.json\` | The Subnet-EVM genesis of the L1. |"
        echo "| \`accounts.json\` | The development accounts above, with their private keys. |"
    } >"$dir/README.md"
done

# ── Index ────────────────────────────────────────────────────────────────────

{
    echo "# Devnet networks"
    echo
    echo "One directory per network. \`describe-networks.sh\` wrote them from the deployment manifest and the P-Chain on $(date -u +%Y-%m-%dT%H:%M:%SZ). The files are a snapshot; to refresh them, run:"
    echo
    echo '    bash /fixtures/scripts/describe-networks.sh /opt/networks'
    echo
    echo "| Directory | Network | Chains | RPC URL on the host |"
    echo "| --- | --- | --- | --- |"
    echo "| [primary-network](primary-network/README.md) | Primary Network | P-, X-, C-Chain | \`$(jq -r '.primary_network.host.c_chain_rpc_url // "random port"' "$manifest")\` (C-Chain) |"
    jq -r '.l1s[] | "| [\(.name)](\(.name)/README.md) | L1, \(.validator_management) | `\(.blockchain_id)` | `\(.host.rpc_url // "random port")` |"' "$manifest"
    echo
    echo "\`deployment.json\` is the deployment manifest: every URL, ID, contract address, and the arguments."
} >"$work/README.md"

# Replace the old description in one step, so that a reader never sees half of it.
count=$(jq '.l1s | length + 1' "$manifest")
chmod -R a+rX "$work"
rm -rf "$out"
mv "$work" "$out"
trap - EXIT
echo "Described $count networks in $out"
