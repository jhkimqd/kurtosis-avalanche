"""Package arguments: defaults, parsing, and the AvalancheGo flags of each node.

`examples/pos.yml` shows every default below as an arguments file.
`docs/config/` lists every AvalancheGo option that the mappings accept.
"""

constants = import_module("./constants.star")
sanity_check = import_module("./sanity_check.star")

# The Primary Network is the local stand-in for Avalanche Mainnet. Its
# validators run the P-Chain (staking and L1 registry), the X-Chain (asset
# transfers), and the C-Chain (EVM contracts).
DEFAULT_PRIMARY_NETWORK_ARGS = {
    # Number of Primary Network validators.
    "validator_count": 3,
    # AvalancheGo flags of the Primary Network validators.
    "node_config": {},
    # Chain configs, written to <chain-config-dir>/{P,X,C}/config.json.
    "p_chain_config": {},
    "x_chain_config": {},
    "c_chain_config": {},
}

# An Avalanche L1 is a Subnet-EVM blockchain with its own validator set. The
# package registers it on the P-Chain of the local Primary Network.
DEFAULT_L1_ARGS = {
    # Number of identical L1s. L1 number n is named `l1-<n>`.
    "count": 1,
    # How validators join the L1: see `constants.VALIDATOR_MANAGEMENT`.
    "validator_management": constants.VALIDATOR_MANAGEMENT.native_pos,
    # Number of validators and of non-validating RPC nodes, per L1.
    "validator_count": 5,
    "rpc_count": 1,
    # EVM chain ID of the first L1. L1 number n uses `chain_id + n`.
    "chain_id": 77777,
    # Changes to the Subnet-EVM genesis, merged into static_files/l1-genesis.json.
    # Gas fees (`config.feeConfig`) and funded accounts (`alloc`) are set here.
    "genesis": {},
    # Subnet config, written to <subnet-config-dir>/<subnet-id>.json.
    "subnet_config": {},
    # Subnet-EVM chain config, written to <chain-config-dir>/<blockchain-id>/config.json.
    "chain_config": {},
    # AvalancheGo flags of the L1 validators and RPC nodes.
    "node_config": {},
}

DEFAULT_ARGS = {
    "primary_network": DEFAULT_PRIMARY_NETWORK_ARGS,
    "l1": DEFAULT_L1_ARGS,
    # AvalancheGo flags of every node. A `node_config` inside `primary_network`
    # or `l1` takes precedence for the nodes of that section.
    "node_config": {},
    # Deploy an ICM token bridge between the C-Chain and each L1, with a relayer.
    "bridge": True,
    # Collect the metrics of every node and support service: Alloy scrapes
    # them, and Prometheus stores them.
    "metrics": True,
    # Container images: see `constants.IMAGES`.
    "images": constants.IMAGES,
}

# AvalancheGo flags that the package changes from the upstream defaults. They
# make a network of a few local nodes start fast and stay healthy. Any of them
# can be overridden through `node_config`.
DEFAULT_NODE_CONFIG = {
    # Expose the Admin API and index every accepted block and transaction.
    "api-admin-enabled": True,
    "index-enabled": True,
    # Accept API requests addressed to a service name such as `primary-0`.
    # Services in the enclave reach each other by name, not by IP address.
    "http-allowed-hosts": "*",
    # Find peers, reconnect, and report health quickly.
    "network-peer-list-pull-gossip-frequency": "250ms",
    "network-max-reconnect-delay": "1s",
    "health-check-frequency": "2s",
    # Keep running on a development machine with a nearly full disk.
    "system-tracker-disk-required-available-space-percentage": 0,
    "system-tracker-disk-warning-available-space-percentage": 0,
    # Build each block against the latest P-Chain height. A validator set
    # change then takes effect on the L1 without the usual delay.
    "proposervm-use-current-height": True,
    # The genesis validators stake for ten years, so the limits must allow it.
    "max-stake-duration": "87600h",
    "stake-minting-period": "87600h",
    # Let tests add Primary Network validators that stake for only seconds.
    "min-stake-duration": "2s",
    "helicon-min-stake-duration": "1s",
    # Snowman consensus for a small network. Each poll samples 3 validators
    # (Mainnet: 20) and needs 2 matching answers (Mainnet: 15).
    "snow-sample-size": 3,
    "snow-preference-quorum-size": 2,
    "snow-confidence-quorum-size": 2,
}


# Subnet-EVM chain config options that the package changes from the upstream
# defaults. Any of them can be overridden through `l1.chain_config`.
DEFAULT_L1_CHAIN_CONFIG = {
    # Serve the `warp_*` RPC methods, so that ICM tools can fetch the Warp
    # messages of the L1 and their signatures.
    "warp-api-enabled": True,
}


def parse(input_args):
    """Applies the defaults to the user arguments and validates the result.

    Args:
        input_args: the arguments of `kurtosis run`, usually from `--args-file`.
    Returns:
        A dict with every key of `DEFAULT_ARGS`. Each `node_config` and the
        L1 `chain_config` hold the final values, package defaults included.
    """
    input_args = _with_defaults(input_args, DEFAULT_ARGS, "the arguments")
    args = {}
    for key, default in DEFAULT_ARGS.items():
        if key in ["primary_network", "l1", "images"]:
            args[key] = _with_defaults(input_args[key], default, key)
        else:
            args[key] = input_args[key]

    sanity_check.check(args)

    # Later layers win: package defaults, `node_config`, then the section.
    for section in ["primary_network", "l1"]:
        node_config = dict(DEFAULT_NODE_CONFIG)
        node_config.update(args["node_config"])
        node_config.update(args[section]["node_config"])
        args[section]["node_config"] = node_config

    args["l1"]["chain_config"] = DEFAULT_L1_CHAIN_CONFIG | args["l1"]["chain_config"]

    return args


def _with_defaults(input_args, defaults, label):
    """Returns a copy of `input_args` with a default for each missing key.

    A YAML key that holds only comments parses as None; it counts as missing.
    """
    if input_args == None:
        input_args = {}
    sanity_check.check_keys(input_args, defaults, label)
    args = {}
    for key, default in defaults.items():
        value = input_args.get(key)
        args[key] = default if value == None else value
    return args
