"""Input validation. Every check runs before the package starts a service."""

constants = import_module("./constants.star")

# AvalancheGo flags that the package sets for every node: identities, paths,
# ports, and peer wiring. An override would break the Kurtosis port mapping,
# peer discovery, or log collection, so the package rejects it.
MANAGED_NODE_FLAGS = [
    "bootstrap-ids",
    "bootstrap-ips",
    "chain-config-content",
    "chain-config-dir",
    "config-file",
    "config-file-content",
    "data-dir",
    "genesis-file",
    "genesis-file-content",
    "http-host",
    "http-port",
    "log-dir",
    "network-id",
    "partial-sync-primary-network",
    "plugin-dir",
    "public-ip",
    "public-ip-resolution-service",
    "staking-ephemeral-cert-enabled",
    "staking-ephemeral-signer-enabled",
    "staking-host",
    "staking-port",
    "staking-rpc-signer-endpoint",
    "staking-signer-key-file",
    "staking-signer-key-file-content",
    "staking-tls-cert-file",
    "staking-tls-cert-file-content",
    "staking-tls-key-file",
    "staking-tls-key-file-content",
    "subnet-config-content",
    "subnet-config-dir",
    "track-subnets",
    "upgrade-file",
    "upgrade-file-content",
]

# Header fields of the L1 genesis that the package generates.
MANAGED_GENESIS_KEYS = [
    "gasLimit",  # Set from `config.feeConfig.gasLimit`; Subnet-EVM requires them equal.
]

# Fields of the L1 genesis `config` that the package generates.
MANAGED_GENESIS_CONFIG_KEYS = [
    "chainId",  # Set from `l1.chain_id`.
    "warpConfig",  # Warp is required for validator management and the bridge.
    "contractNativeMinterConfig",  # Grants mint rights to the bridge contract.
]

# Public development accounts that deploy contracts at predicted addresses.
# A genesis nonce or code on one of them would move those addresses.
VALIDATOR_MANAGER_DEPLOYER = "8db97c7cece249c2b98bdc0226cc4c2a57bf52fc"  # EWOQ
BRIDGE_DEPLOYERS = [
    "f7edc8fa1ecc32967f827c9043fcae6ba73afa5c",  # Deploys TeleporterMessenger.
    "4cceba2d7d2b4fdce4304d3e09a1fea9fbeb1528",  # Deploys NativeTokenRemote.
]

# EVM chain IDs of public networks. A transaction that is signed for a devnet
# with one of these IDs would also be valid on that network.
PUBLIC_CHAIN_IDS = {
    1: "Ethereum",
    43113: "the Fuji C-Chain",
    43114: "the Avalanche Mainnet C-Chain",
}

# Inclusive bounds of the integer arguments.
PRIMARY_NETWORK_RANGES = {"validator_count": (2, 100)}
L1_RANGES = {
    "count": (1, 100),
    "validator_count": (1, 100),
    "rpc_count": (1, 100),
    "chain_id": (1, 2147483547),
}


def check_keys(args, defaults, label):
    """Fails on an argument that the package does not know."""
    if type(args) != "dict":
        fail("{} must be a mapping".format(label))
    for key in args:
        if key not in defaults:
            fail(
                "Unknown argument '{}' in {}; supported arguments: {}".format(
                    key, label, sorted(defaults.keys())
                )
            )


def check(args):
    """Validates arguments after the defaults are applied."""
    primary_network = args["primary_network"]
    l1 = args["l1"]

    _check_ranges(primary_network, PRIMARY_NETWORK_RANGES, "primary_network")
    _check_ranges(l1, L1_RANGES, "l1")

    # Each L1 takes the next chain ID; none may reuse the C-Chain ID.
    first, last = l1["chain_id"], l1["chain_id"] + l1["count"] - 1
    if first <= constants.C_CHAIN_ID and constants.C_CHAIN_ID <= last:
        fail(
            "l1.chain_id {}..{} must not include the C-Chain ID {}".format(
                first, last, constants.C_CHAIN_ID
            )
        )

    for chain_id, network in PUBLIC_CHAIN_IDS.items():
        if first <= chain_id and chain_id <= last:
            fail(
                "l1.chain_id {}..{} must not include {}, the chain ID of {}".format(
                    first, last, chain_id, network
                )
            )

    modes = [
        constants.VALIDATOR_MANAGEMENT.poa,
        constants.VALIDATOR_MANAGEMENT.native_pos,
        constants.VALIDATOR_MANAGEMENT.erc20_pos,
    ]
    if l1["validator_management"] not in modes:
        fail("l1.validator_management must be one of {}".format(modes))

    for key in ["bridge", "metrics", "logs", "dashboards"]:
        if type(args[key]) != "bool":
            fail("{} must be a boolean".format(key))
    # Grafana shows what Prometheus and Loki store. With neither it is empty.
    if args["dashboards"] and not (args["metrics"] or args["logs"]):
        fail(
            "dashboards needs metrics or logs: set one of them to true, or set dashboards to false"
        )

    for name, image in args["images"].items():
        if type(image) != "string" or (image == "" and name != "tools"):
            fail("images.{} must be a nonempty image reference".format(name))

    _check_node_config(args["node_config"], "node_config")
    _check_node_config(primary_network["node_config"], "primary_network.node_config")
    _check_node_config(l1["node_config"], "l1.node_config")

    for key in ["p_chain_config", "x_chain_config", "c_chain_config"]:
        _check_mapping(primary_network[key], "primary_network." + key)
    for key in ["subnet_config", "chain_config"]:
        _check_mapping(l1[key], "l1." + key)

    # A private L1 talks only to its validators and to listed node IDs. The
    # package generates the node IDs during the run, so the RPC nodes and the
    # signature aggregator could not be listed, and the deployment would hang.
    if l1["subnet_config"].get("validatorOnly", False) != False:
        fail("l1.subnet_config.validatorOnly is not supported; it must stay false")

    _check_genesis(l1["genesis"], args["bridge"])


def _check_ranges(args, ranges, label):
    for key, (low, high) in ranges.items():
        value = args[key]
        if type(value) != "int" or value < low or value > high:
            fail("{}.{} must be an integer in [{}, {}]".format(label, key, low, high))


def _check_mapping(value, label):
    if type(value) != "dict":
        fail("{} must be a mapping".format(label))


def _check_node_config(config, label):
    _check_mapping(config, label)
    for flag in config:
        if type(flag) != "string":
            fail("{} keys must be strings".format(label))
        if flag in MANAGED_NODE_FLAGS:
            fail("{}.{} is managed by the package".format(label, flag))


def _check_genesis(genesis, bridge):
    _check_mapping(genesis, "l1.genesis")
    for key in MANAGED_GENESIS_KEYS:
        if key in genesis:
            fail("l1.genesis.{} is managed by the package".format(key))
    # A key without a value keeps the base genesis value (see mergeJSON in
    # tools/lifecycle.go).
    config = genesis.get("config")
    if config == None:
        config = {}
    _check_mapping(config, "l1.genesis.config")
    for key in MANAGED_GENESIS_CONFIG_KEYS:
        if key in config:
            fail("l1.genesis.config.{} is managed by the package".format(key))

    reserved = [VALIDATOR_MANAGER_DEPLOYER] + (BRIDGE_DEPLOYERS if bridge else [])
    alloc = genesis.get("alloc")
    if alloc == None:
        alloc = {}
    _check_mapping(alloc, "l1.genesis.alloc")
    for address, account in alloc.items():
        if type(address) != "string" or type(account) != "dict":
            fail("l1.genesis.alloc must map address strings to account mappings")
        # Subnet-EVM requires a balance for every account. YAML reads an
        # unquoted balance as a number and can round a large one.
        if type(account.get("balance")) != "string":
            fail(
                'l1.genesis.alloc.{}.balance is required as a quoted string, for example "0xde0b6b3a7640000"'.format(
                    address
                )
            )
        if address.lower().removeprefix("0x") not in reserved:
            continue
        if account.get("nonce", 0) not in [0, "0", "0x0"] or account.get(
            "code", ""
        ) not in ["", "0x"]:
            fail(
                "l1.genesis.alloc.{} is a reserved deployer; it must have zero nonce and no code".format(
                    address
                )
            )
