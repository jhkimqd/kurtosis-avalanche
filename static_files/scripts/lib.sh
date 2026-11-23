# shellcheck shell=bash
# shellcheck disable=SC2034 # the scripts that source this file use its constants
# Shared helpers of the setup scripts in the tools service.
#
# The setup scripts (network.sh, l1.sh, staking.sh, bridge.sh, checks.sh,
# icm.sh) source this file. They do the work that Starlark cannot do, with
# existing tools:
#
#   avalanchego    generates node identities: staking key, TLS certificate,
#                  BLS signer key, and its proof of possession
#   platform-cli   signs and sends every P-Chain transaction
#   cast           signs and sends every EVM transaction, ABI encoding
#   curl, jq       JSON-RPC calls, the signature aggregator, JSON files
#
# Bash code here only fills the gaps: CB58 encoding, the two P-Chain Warp
# messages that the L1 must receive, and the journals that make every setup
# step safe to repeat.
#
# Safety rules, kept from the earlier Go tool:
#
#   - A script that signs runs only where TOOLS_INSTANCE is set (the tools
#     service) and only against a node of network 88888 (local_only).
#   - One lock lets one signing script run at a time: all of them sign with
#     the EWOQ account and would otherwise reuse a nonce.
#   - Every journal records its deployment, so the state of one enclave is
#     never replayed against another.

set -euo pipefail
# Let a failure inside $(...) stop the function, as it would outside.
shopt -s inherit_errexit

# ── Constants ───────────────────────────────────────────────────────────────


# Network ID of the local Primary Network. The scripts never sign for any other.
NETWORK_ID=88888
# The public EWOQ development key. It funds and owns everything on the devnet.
EWOQ_KEY=0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027
EWOQ_ADDRESS=0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC
# The same key on the P-Chain and X-Chain of network 88888 (HRP "custom").
EWOQ_P_ADDRESS=custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p
# Raw 20-byte P-Chain address of the EWOQ key, as the contracts take it.
EWOQ_P_SHORT_ID=0x3cb7d3842e8cee6a0ebd09f1fe884f6861e1b29c
# Precompiles of Subnet-EVM and the C-Chain.
WARP_PRECOMPILE=0x0200000000000000000000000000000000000005
NATIVE_MINTER_PRECOMPILE=0x0200000000000000000000000000000000000001
# VM ID of Subnet-EVM.
SUBNET_EVM_ID=srEXiWaHuhNyGwPUi444Tu47ZEDwxTWrbQiuD7FmgSAQ6X7Dy
# keccak256("SendWarpMessage(address,bytes32,bytes)"), the event of the Warp
# precompile that carries an unsigned message.
SEND_WARP_MESSAGE_TOPIC=0x56600c567728a800c0aa927500f831cb451df66a7af570eb4df4dfbf4674887d

# Files of ./static_files, mounted in the tools service.
FIXTURES=${FIXTURES:-/fixtures}
CONTRACTS=${CONTRACTS:-$FIXTURES/contracts}
STATE=${STATE_DIR:-/state}

# How long a script waits for a transaction, a node, or a relayed message.
WAIT_SECONDS=${WAIT_SECONDS:-600}

# ── Basics ──────────────────────────────────────────────────────────────────

die() {
    echo "error: $*" >&2
    exit 1
}

log() { echo "$*" >&2; }

# require_tools_service stops a signing script outside the tools service.
require_tools_service() {
    case ${TOOLS_INSTANCE:-} in
    "" | manual) die "the setup scripts sign only in the tools service, where TOOLS_INSTANCE is set" ;;
    esac
}

# writer_lock lets one signing script run at a time in this container.
writer_lock() {
    exec 9>"${TMPDIR:-/tmp}/avalanche-tools-writer.lock"
    flock -n 9 || die "another setup script is running"
}

# atomic_write PATH writes stdin to PATH so that a crash leaves either the old
# or the new file, never a partial one. Empty input writes nothing and fails:
# in `producer | atomic_write`, a producer that failed sends nothing, and an
# empty file would read as a finished step on the next run.
atomic_write() {
    local path=$1 tmp
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "$(dirname "$path")/.tmp-XXXXXX")
    cat >"$tmp"
    if [[ ! -s $tmp ]]; then
        rm -f "$tmp"
        die "refusing to write an empty $path"
    fi
    sync "$tmp"
    mv -f "$tmp" "$path"
    sync "$(dirname "$path")"
}

# deadline SECONDS prints the epoch second at which a wait gives up.
deadline() { echo $(($(date +%s) + $1)); }

# expired DEADLINE succeeds once the deadline has passed.
expired() { (($(date +%s) >= $1)); }

# ── Hex and CB58 ────────────────────────────────────────────────────────────

# strip0x HEX prints HEX in lowercase without the 0x prefix.
strip0x() {
    local value=${1#0x}
    echo "${value,,}"
}

# hex_bytes HEX writes the bytes of HEX to stdout.
hex_bytes() {
    local hex
    hex=$(strip0x "$1")
    # shellcheck disable=SC2059,SC2001 # the format holds only \x escapes
    printf "$(sed 's/../\\x&/g' <<<"$hex")"
}

# sha256_hex HEX prints the SHA-256 of the bytes of HEX, in hex.
sha256_hex() { hex_bytes "$1" | sha256sum | cut -c1-64; }

# u32 N prints N as 4 bytes big-endian, in hex.
u32() { printf '%08x' "$1"; }

# hex_len HEX prints the byte length of HEX.
hex_len() {
    local hex
    hex=$(strip0x "$1")
    echo $((${#hex} / 2))
}

B58_ALPHABET=123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz

# base58_decode TEXT prints the bytes of TEXT in hex.
base58_decode() {
    local text=$1 i j digit carry prefix rest out=""
    local -a bytes=()
    for ((i = 0; i < ${#text}; i++)); do
        rest=${B58_ALPHABET%%"${text:i:1}"*}
        digit=${#rest}
        ((digit < 58)) || die "invalid base58 character in $text"
        carry=$digit
        for ((j = 0; j < ${#bytes[@]}; j++)); do
            carry=$((bytes[j] * 58 + carry))
            bytes[j]=$((carry & 255))
            carry=$((carry >> 8))
        done
        while ((carry > 0)); do
            bytes+=($((carry & 255)))
            carry=$((carry >> 8))
        done
    done
    for ((i = 0; i < ${#text}; i++)); do
        [[ ${text:i:1} == 1 ]] || break
        out+=00
    done
    for ((j = ${#bytes[@]} - 1; j >= 0; j--)); do
        printf -v prefix '%02x' "${bytes[j]}"
        out+=$prefix
    done
    echo "$out"
}

# base58_encode HEX prints the bytes of HEX in base58.
base58_encode() {
    local hex i j carry out=""
    local -a digits=()
    hex=$(strip0x "$1")
    for ((i = 0; i < ${#hex}; i += 2)); do
        carry=$((16#${hex:i:2}))
        for ((j = 0; j < ${#digits[@]}; j++)); do
            carry=$((digits[j] * 256 + carry))
            digits[j]=$((carry % 58))
            carry=$((carry / 58))
        done
        while ((carry > 0)); do
            digits+=($((carry % 58)))
            carry=$((carry / 58))
        done
    done
    for ((i = 0; i < ${#hex}; i += 2)); do
        [[ ${hex:i:2} == 00 ]] || break
        out+=1
    done
    for ((j = ${#digits[@]} - 1; j >= 0; j--)); do out+=${B58_ALPHABET:digits[j]:1}; done
    echo "$out"
}

# cb58_decode TEXT prints the bytes of an Avalanche ID in hex, without the
# 0x prefix. CB58 is base58 with the last 4 bytes of the SHA-256 of the
# payload appended as a checksum. A "NodeID-" prefix is removed.
cb58_decode() {
    local text=${1#NodeID-} raw payload
    raw=$(base58_decode "$text")
    ((${#raw} > 8)) || die "invalid CB58 value $1"
    payload=${raw:0:${#raw}-8}
    [[ $(sha256_hex "$payload" | tail -c 9) == "${raw: -8}" ]] || die "invalid CB58 checksum in $1"
    echo "$payload"
}

# cb58_encode HEX prints the CB58 form of HEX, as Avalanche shows an ID.
cb58_encode() {
    local hex
    hex=$(strip0x "$1")
    base58_encode "$hex$(sha256_hex "$hex" | tail -c 9)"
}

# ── Large numbers ───────────────────────────────────────────────────────────
#
# Token amounts in wei exceed the 64 bits of bash arithmetic. These helpers
# work on decimal text.

# big_add A B prints A + B.
big_add() {
    local a=$1 b=$2 out="" carry=0 i=${#1} j=${#2} digit
    while ((i > 0 || j > 0 || carry > 0)); do
        digit=$carry
        if ((i > 0)); then
            i=$((i - 1))
            digit=$((digit + ${a:i:1}))
        fi
        if ((j > 0)); then
            j=$((j - 1))
            digit=$((digit + ${b:j:1}))
        fi
        out=$((digit % 10))$out
        carry=$((digit / 10))
    done
    echo "${out:-0}"
}

# big_ge A B succeeds if A >= B. Neither has leading zeros.
big_ge() {
    ((${#1} != ${#2})) && { ((${#1} > ${#2})); return; }
    [[ $1 == "$2" || $1 > $2 ]]
}

# ── JSON-RPC ────────────────────────────────────────────────────────────────

# rpc URL METHOD PARAMS prints the result of one JSON-RPC call. PARAMS is a
# JSON value. An error response or a missing result fails.
rpc() {
    local url=$1 method=$2 params=${3:-{\}} response
    response=$(curl -sS --fail-with-body --max-time 30 -H 'Content-Type: application/json' \
        --data "$(jq -cn --arg method "$method" --argjson params "$params" \
            '{jsonrpc: "2.0", id: 1, method: $method, params: $params}')" "$url") ||
        die "$method at $url: $response"
    jq -e 'has("result")' <<<"$response" >/dev/null ||
        die "$method at $url: $(jq -c '.error // .' <<<"$response" 2>/dev/null || echo "$response")"
    jq -c .result <<<"$response"
}

# rpc_quiet URL METHOD PARAMS is rpc without the error message: it fails
# quietly, for a check whose answer may be an error.
rpc_quiet() { (rpc "$@") 2>/dev/null; }

# base_uri URL prints the node URL of an Avalanche chain URL:
# http://host:9650/ext/bc/<chain>/rpc becomes http://host:9650.
base_uri() { echo "${1%%/ext/*}"; }

# local_only URI fails unless the node at URI belongs to network 88888.
local_only() {
    local got
    got=$(rpc "$(base_uri "$1")/ext/info" info.getNetworkID | jq -r .networkID)
    [[ $got == "$NETWORK_ID" ]] || die "the setup scripts require network $NETWORK_ID; $1 reports $got"
}

# deployment_identity URI prints the identity of one deployment: the instance
# name and the hash of the P-Chain genesis block. Each journal records it.
deployment_identity() {
    local uri block
    uri=$(base_uri "$1")
    local_only "$uri"
    block=$(rpc "$uri/ext/bc/P" platform.getBlockByHeight '{"height":"0","encoding":"hex"}' | jq -r .block)
    [[ -n $block && $block != null ]] || die "missing P-Chain genesis block at $uri"
    echo "$TOOLS_INSTANCE:$(sha256_hex "$block")"
}

# json_array ARGS... prints its arguments as one JSON array of strings. (jq
# --args would read an argument such as --subnet-id as its own option.)
json_array() {
    local -a named=()
    local i=0 value
    for value in "$@"; do
        named+=(--arg "$(printf 'a%06d' "$i")" "$value")
        i=$((i + 1))
    done
    jq -cn "${named[@]}" '[$ARGS.named | to_entries | sort_by(.key)[] | .value]'
}

# fingerprint ARGS... prints the SHA-256 of its arguments as one JSON array.
fingerprint() { json_array "$@" | sha256sum | cut -c1-64; }

# ── P-Chain transactions (platform-cli) ─────────────────────────────────────
#
# platform-cli builds, signs, sends, and waits for each P-Chain transaction in
# one call; it has no mode that signs without sending. A P-Chain step is
# therefore journaled in two files:
#
#   <name>.pending.pchain.json   written before platform-cli runs
#   <name>.pchain.json           written after the P-Chain accepted the transaction
#
# A repeated step with a finished journal does nothing. A repeated step with
# only a pending journal may have sent its transaction already. It runs the
# step's check, which looks for the result on the P-Chain; without a check, or
# if the check finds nothing, it stops rather than risk a second transaction.

# platform URI ARGS... runs platform-cli with the EWOQ key against URI.
platform() {
    local uri=$1
    shift
    PLATFORM_CLI_TIMEOUT=${PLATFORM_CLI_TIMEOUT:-5m} platform-cli "$@" \
        --key-name ewoq --rpc-url "$(base_uri "$uri")" --allow-insecure-http
}

# pchain_step URI DIR NAME CHECK PATTERN -- ARGS... runs one journaled P-Chain
# transaction and prints its transaction ID.
#
#   CHECK    a function that prints the transaction ID if the P-Chain already
#            holds the result, "-" for none, or "retry" for a transaction that
#            is harmless to send twice
#   PATTERN  an extended regex whose first group is the ID in the output of
#            platform-cli
#   ARGS     the platform-cli command and flags
pchain_step() {
    local uri=$1 dir=$2 name=$3 check=$4 pattern=$5 identity digest finished pending output tx found
    shift 6
    finished=$dir/$name.pchain.json
    pending=$dir/$name.pending.pchain.json
    identity=$(deployment_identity "$uri")
    digest=$(fingerprint "$identity" "$@")
    if [[ -f $finished ]]; then
        [[ $(jq -r .fingerprint "$finished") == "$digest" ]] || die "journal input mismatch: $finished"
        jq -r .tx_id "$finished"
        return
    fi
    if [[ -f $pending ]]; then
        [[ $(jq -r .fingerprint "$pending") == "$digest" ]] || die "journal input mismatch: $pending"
        found=-
        [[ $check == - ]] || found=$("$check")
        [[ $found != - ]] || die "$name may have been sent by an earlier attempt and the P-Chain does not show its result; inspect $pending or use a new enclave"
        tx=$found
    fi
    if [[ ! -f $pending || ${tx:-} == retry ]]; then
        jq -n --arg fingerprint "$digest" --argjson command "$(json_array "$@")" \
            '{version: 1, fingerprint: $fingerprint, command: $command, state: "prepared"}' | atomic_write "$pending"
        output=$(platform "$uri" "$@" 2>&1) || die "platform-cli $1 $2 failed: $output"
        log "$output"
        [[ $output =~ $pattern ]] || die "no transaction ID in the output of platform-cli $1 $2"
        tx=${BASH_REMATCH[1]}
    fi
    jq -n --arg fingerprint "$digest" --arg tx "$tx" \
        '{version: 1, fingerprint: $fingerprint, tx_id: $tx, state: "accepted"}' | atomic_write "$finished"
    rm -f "$pending"
    echo "$tx"
}

# ── EVM transactions (cast) ─────────────────────────────────────────────────

# chain_rpc_blockchain URL prints the blockchain ID in an Avalanche chain URL.
chain_rpc_blockchain() {
    local rest=${1#*/ext/bc/}
    echo "${rest%%/*}"
}

# evm_tx URL DIR NAME TO DATA VALUE [ACCESS_LIST] [KEY] sends one EVM
# transaction exactly once and prints the path of its receipt.
#
# TO is an address, or "create" to deploy DATA. ACCESS_LIST carries a signed
# Warp message for the Warp precompile (see predicate). KEY defaults to EWOQ.
#
# The transaction is signed with `cast mktx` and written to the journal
# DIR/NAME.evm.json before `cast publish` sends it. A repeated call finds the
# journal and sends the same bytes again, which is harmless.
evm_tx() {
    local url=$1 dir=$2 name=$3 to=$4 data=$5 value=$6 access=${7:-} key=${8:-$EWOQ_KEY}
    local path=$dir/$name.evm.json receipt_path=$dir/$name.receipt.json
    local from chain identity digest raw hash limit gas estimate send_error="" receipt until
    local -a target
    from=$(cast wallet address "$key")
    local_only "$url"
    chain=$(cast chain-id -r "$url")
    identity=$(deployment_identity "$url")
    digest=$(fingerprint "$identity" "$(chain_rpc_blockchain "$url")" "$chain" "$from" "$to" "$data" "$value" "$access")
    if [[ -f $path ]]; then
        [[ $(jq -r .fingerprint "$path") == "$digest" ]] || die "EVM operation input mismatch: $path"
        raw=$(jq -r .signed "$path")
        hash=$(jq -r .tx_id "$path")
        [[ $(cast keccak "$raw") == "$hash" ]] || die "invalid EVM journal: $path"
    else
        if [[ $to == create ]]; then target=(--create "$data"); else target=("$to" "$data"); fi
        limit=$(cast block latest --field gasLimit -r "$url")
        if [[ -n $access ]]; then
            # A call that verifies a Warp message cannot be estimated: the
            # estimate runs without the predicate.
            gas=$((limit < 10000000 ? limit : 10000000))
        else
            estimate=$(cast estimate --from "$from" --value "$value" -r "$url" "${target[@]}") ||
                die "gas estimate of $name failed"
            ((estimate <= limit)) || die "estimated gas $estimate of $name exceeds the block gas limit $limit"
            gas=$((estimate + (estimate / 5 < limit - estimate ? estimate / 5 : limit - estimate)))
            if [[ $to == create ]] && ((gas < 8000000)); then gas=$((limit < 8000000 ? limit : 8000000)); fi
        fi
        raw=$(cast mktx --private-key "$key" --gas-limit "$gas" --value "$value" \
            ${access:+--access-list "$access"} -r "$url" "${target[@]}")
        hash=$(cast keccak "$raw")
        jq -n --arg fingerprint "$digest" --arg hash "$hash" --arg raw "$raw" \
            '{version: 1, fingerprint: $fingerprint, tx_id: $hash, signed: $raw, state: "prepared"}' | atomic_write "$path"
    fi
    receipt=$(rpc "$url" eth_getTransactionReceipt "[\"$hash\"]")
    if [[ $receipt == null ]]; then
        # A second broadcast of the same bytes is harmless; the hash is fixed.
        if send_error=$(cast publish -r "$url" "$raw" 2>&1 >/dev/null); then
            jq '.state = "submitted"' "$path" | atomic_write "$path"
            send_error=""
        fi
        until=$(deadline "$WAIT_SECONDS")
        while receipt=$(rpc "$url" eth_getTransactionReceipt "[\"$hash\"]") && [[ $receipt == null ]]; do
            expired "$until" && die "unresolved EVM transaction $hash of $name (send: ${send_error:-ok})"
            sleep 1
        done
    fi
    if [[ $(jq -r .status <<<"$receipt") != 0x1 ]]; then
        jq '.state = "reverted"' "$path" | atomic_write "$path"
        die "EVM transaction $hash of $name reverted"
    fi
    jq '.state = "accepted"' "$path" | atomic_write "$path"
    jq . <<<"$receipt" | atomic_write "$receipt_path"
    echo "$receipt_path"
}

# abi_signature CONTRACT METHOD prints the cast signature "m(inputs)(outputs)"
# of METHOD, read from the contract artifact. A method name must be unique.
abi_signature() {
    local artifact=$CONTRACTS/$1.json
    [[ -f $artifact ]] || die "no contract artifact $artifact"
    jq -er --arg method "$2" '
        def t: if (.type | startswith("tuple"))
            then "(" + ([.components[] | t] | join(",")) + ")" + (.type | ltrimstr("tuple"))
            else .type end;
        [.abi[] | select(.type == "function" and .name == $method)]
        | if length == 1 then .[0] else error("\($method) is missing or overloaded") end
        | "\(.name)(\([.inputs[] | t] | join(",")))(\([.outputs[] | t] | join(",")))"' "$artifact"
}

# calldata CONTRACT METHOD ARGS... prints the ABI-encoded call.
calldata() {
    local signature
    signature=$(abi_signature "$1" "$2")
    shift 2
    cast calldata "${signature%%)(*})" "$@"
}

# invoke URL DIR NAME CONTRACT ADDRESS ACCESS_LIST ARGS... calls the method
# NAME of a contract from the EWOQ account and prints the receipt path. The
# method name is also the journal name.
invoke() {
    local url=$1 dir=$2 name=$3 contract=$4 address=$5 access=$6 data
    shift 6
    data=$(calldata "$contract" "$name" "$@")
    evm_tx "$url" "$dir" "$name" "$address" "$data" 0 "$access"
}

# view URL CONTRACT ADDRESS METHOD ARGS... prints the decoded outputs of a
# read-only call as a JSON array: a tuple is an array, a uint256 a string, a
# smaller integer a number. (`cast call --json` prints the bare array; `cast
# decode-abi --json` wraps it in an object with `data`.)
view() {
    local url=$1 contract=$2 address=$3 method=$4 signature
    shift 4
    signature=$(abi_signature "$contract" "$method")
    cast call --json -r "$url" "$address" "$signature" "$@" | jq -c 'if type == "object" then .data else . end'
}

# link_bytecode CONTRACT LIBRARY prints the deployable bytecode of CONTRACT,
# with LIBRARY at every library placeholder.
link_bytecode() {
    local artifact=$CONTRACTS/$1.json library start code
    library=$(strip0x "${2:-}")
    code=$(jq -r '.bytecode.object' "$artifact")
    code=$(strip0x "$code")
    for start in $(jq -r '[.bytecode.linkReferences[][][] | select(.length == 20) | .start] | .[]' "$artifact"); do
        [[ ${#library} == 40 ]] || die "unresolved library for $1"
        code=${code:0:2*start}$library${code:2*start+40}
    done
    [[ $(jq '[.bytecode.linkReferences[][][]] | length' "$artifact") == 0 || -n $library ]] ||
        die "unresolved library for $1"
    echo "0x$code"
}

# deploy URL DIR CONTRACT LIBRARY [KEY] [ARGS...] deploys a contract and prints
# its address. LIBRARY is the address to link, or "" for none. The journal is
# DIR/deploy-CONTRACT.
deploy() {
    local url=$1 dir=$2 contract=$3 library=$4 key=${5:-$EWOQ_KEY} code types args="" receipt
    shift 5 || shift $#
    code=$(link_bytecode "$contract" "$library")
    types=$(jq -r '
        def t: if (.type | startswith("tuple"))
            then "(" + ([.components[] | t] | join(",")) + ")" + (.type | ltrimstr("tuple"))
            else .type end;
        [.abi[] | select(.type == "constructor") | .inputs[] | t] | join(",")' "$CONTRACTS/$contract.json")
    if [[ -n $types ]]; then args=$(cast abi-encode "constructor($types)" "$@"); fi
    receipt=$(evm_tx "$url" "$dir" "deploy-$contract" create "$code$(strip0x "$args")" 0 "" "$key")
    cast to-check-sum-address "$(jq -r .contractAddress "$receipt")"
}

# dev_key N prints the public development key whose private key is N.
dev_key() { printf '0x%064x' "$1"; }

# tokens N prints N tokens of 18 decimals, in wei.
tokens() { cast to-wei "$1" ether; }

# ── Warp messages ───────────────────────────────────────────────────────────
#
# A Warp message from the P-Chain to an L1 is built here, because neither
# platform-cli nor the signature aggregator builds one. The encoding follows
# the AvalancheGo codec (vms/platformvm/warp): codec version 0 (2 bytes),
# then the type ID (4 bytes) and the fields; a byte slice has a 4-byte length.

# warp_unsigned PAYLOAD prints an unsigned Warp message from the P-Chain
# (source chain ID 0) of network 88888.
warp_unsigned() {
    local payload
    payload=$(strip0x "$1")
    echo "0x0000$(u32 "$NETWORK_ID")$(printf '%064d' 0)$(u32 "$(hex_len "$payload")")$payload"
}

# addressed_call MESSAGE prints an AddressedCall payload (type 1) with an
# empty source address.
addressed_call() {
    local message
    message=$(strip0x "$1")
    echo "000000000001$(u32 0)$(u32 "$(hex_len "$message")")$message"
}

# conversion_message CONVERSION_ID prints the unsigned SubnetToL1Conversion
# message (type 0). CONVERSION_ID is hex.
conversion_message() { warp_unsigned "$(addressed_call "000000000000$(strip0x "$1")")"; }

# registration_message VALIDATION_ID REGISTERED prints the unsigned
# L1ValidatorRegistration message (type 2). REGISTERED is true or false.
registration_message() {
    local flag=00
    [[ $2 == true ]] && flag=01
    warp_unsigned "$(addressed_call "000000000002$(strip0x "$1")$flag")"
}

# varint N prints N as a protobuf varint, in hex.
varint() {
    local n=$1 out="" byte
    while ((n >= 128)); do
        printf -v byte '%02x' $(((n & 127) | 128))
        out+=$byte
        n=$((n >> 7))
    done
    printf -v byte '%02x' "$n"
    echo "$out$byte"
}

# removal_justification SUBNET_ID INDEX prints the justification that a
# validator named at conversion (position INDEX in the conversion) is no
# longer registered: the protobuf L1ValidatorRegistrationJustification with
# field 1, SubnetIDIndex{subnet_id = 1, index = 2}. Protobuf leaves out an
# index of 0.
removal_justification() {
    local inner
    inner="0a20$(strip0x "$1")"
    (($2 == 0)) || inner+="10$(varint "$2")"
    echo "0x0a$(printf '%02x' "$(hex_len "$inner")")$inner"
}

# predicate SIGNED prints the access list that carries a signed Warp message
# to the Warp precompile: the message bytes, the end marker 0xff, and zero
# padding to 32-byte words, one storage key per word.
predicate() {
    local data
    data="$(strip0x "$1")ff"
    while ((${#data} % 64 != 0)); do data+=00; done
    jq -cn --arg address "$WARP_PRECOMPILE" --arg data "$data" '
        [{address: $address, storageKeys: [range(0; $data | length; 64) as $i | "0x" + $data[$i:$i + 64]]}]'
}

# epoch_height URL prints the P-Chain height of the current ProposerVM epoch
# of a chain (URL ends in /proposervm). Validators check a Warp message
# against the validator set at that height.
epoch_height() { rpc "$1" proposervm.getCurrentEpoch | jq -r '.pChainHeight | tonumber'; }

# aggregate URL MESSAGE JUSTIFICATION SUBNET HEIGHT asks the signature
# aggregator for a message signed by 67% of the stake of SUBNET and prints
# it. Validators can need a moment to see a message, so it tries 30 times,
# 2 seconds apart.
aggregate() {
    local url=$1 request response signed i
    request=$(jq -cn --arg message "$2" --arg justification "$3" --arg subnet "$4" --argjson height "$5" \
        '{message: $message, justification: $justification, "signing-subnet-id": $subnet,
          "quorum-percentage": 67, "pchain-height": $height}')
    for ((i = 0; i < 30; i++)); do
        if response=$(curl -sS --fail-with-body --max-time 30 -H 'Content-Type: application/json' \
            --data "$request" "$url/aggregate-signatures" 2>&1); then
            signed=$(jq -r '."signed-message" // empty' <<<"$response" 2>/dev/null || true)
            if [[ -n $signed ]]; then
                echo "0x$(strip0x "$signed")"
                return
            fi
        fi
        sleep 2
    done
    die "signature aggregation failed: $response"
}

# proof PATH URL MESSAGE JUSTIFICATION SUBNET HEIGHT prints an aggregated
# signature and keeps it in PATH. A repeated call must reuse the same proof,
# because the proof is an input of a journaled transaction.
proof() {
    local path=$1 signed
    shift
    if [[ ! -f $path ]]; then
        signed=$(aggregate "$@")
        echo "$signed" | atomic_write "$path"
    fi
    cat "$path"
}

# warp_payload_message UNSIGNED prints the message inside the AddressedCall
# payload of an unsigned Warp message: after codec version, network ID,
# source chain ID, and payload length (2 + 4 + 32 + 4 bytes), the
# AddressedCall holds codec version, type ID, the source address with its
# length, and the message with its length.
warp_payload_message() {
    local hex address_length
    hex=$(strip0x "$1")
    hex=${hex:84}
    address_length=$((16#${hex:12:8}))
    hex=${hex:20+2*address_length}
    echo "${hex:8:2*16#${hex:0:8}}"
}

# receipt_warp_message RECEIPT prints the unsigned Warp message that a
# transaction sent through the Warp precompile.
receipt_warp_message() {
    local data
    data=$(jq -r --arg address "${WARP_PRECOMPILE,,}" --arg topic "$SEND_WARP_MESSAGE_TOPIC" '
        [.logs[] | select((.address | ascii_downcase) == $address and .topics[0] == $topic) | .data]
        | if length == 1 then .[0] else error("expected one Warp message, found \(length)") end' "$1") ||
        die "no Warp message in $1"
    cast decode-abi "f()(bytes)" "$data" --json | jq -r '.data[0]'
}
