def parse(args):
    allowed = [
        "l1_genesis",
        "chain_id_start",
        "bridge",
        "primary_count",
        "metrics",
        "staking",
        "instance_id",
        "schema_version",
        "l1_count",
        "validator_count",
        "smoke_transactions",
        "bootstrap_memory_mb",
        "bootstrap_cpu_millicores",
        "node_memory_mb",
        "node_cpu_millicores",
        "tools_image",
        "rpc_count",
        "aggregator_image",
        "relayer_image",
        "node_image",
        "primary_image",
        "node_config",
        "role_config",
        "node_overrides",
        "c_chain_config",
        "l1_chain_config",
    ]
    for key in args:
        if key not in allowed:
            fail("Unknown input '{}'; supported inputs: {}".format(key, allowed))
    config = {
        "l1_genesis": {},
        "chain_id_start": 77777,
        "bridge": True,
        "primary_count": 3,
        "metrics": True,
        "staking": "native-pos",
        "instance_id": "devnet",
        "schema_version": 1,
        "l1_count": 1,
        "validator_count": 4,
        "smoke_transactions": 5,
        "bootstrap_memory_mb": 512,
        "bootstrap_cpu_millicores": 500,
        "node_memory_mb": 1536,
        "node_cpu_millicores": 1000,
        "tools_image": "",
    }
    config.update(
        {
            "rpc_count": 1,
            "aggregator_image": "avaplatform/signature-aggregator@sha256:9c7d0f61f01e04c0addaa727e55c53298adb4edd4984287c68ed4b547645464a",
            "relayer_image": "avaplatform/icm-relayer@sha256:57bb6048b78bb7728788ced10f7f4e9c7dce42303858f3bdbd78f5d810c5dc05",
            "node_image": "avaplatform/subnet-evm@sha256:c4a209cf7d8e3cef18eaa32ec173bd83d160a940639e16817a6eb1d33893b5e2",
            "primary_image": "avaplatform/avalanchego@sha256:5181093d02d2a201e890f714f8b9ebb9677de9fd6155e9c391214f3918b41710",
            "node_config": {},
            "role_config": {},
            "node_overrides": {},
            "c_chain_config": {},
            "l1_chain_config": {},
        }
    )
    config.update(args)
    if type(config["l1_genesis"]) != "dict":
        fail("l1_genesis must be a mapping")
    genesis_config = config["l1_genesis"].get("config", {})
    if type(genesis_config) != "dict":
        fail("l1_genesis.config must be a mapping")
    for key in ["chainId", "warpConfig", "contractNativeMinterConfig"]:
        if key in genesis_config:
            fail("l1_genesis.config.{} is managed by the package".format(key))
    if config["schema_version"] != 1:
        fail("Unsupported schema_version")
    for key, low, high in [
        ("chain_id_start", 1, 2147483547),
        ("primary_count", 2, 100),
        ("l1_count", 1, 100),
        ("validator_count", 1, 100),
        ("rpc_count", 1, 100),
        ("smoke_transactions", 1, 1000),
        ("bootstrap_memory_mb", 512, 16384),
        ("bootstrap_cpu_millicores", 100, 16000),
        ("node_memory_mb", 512, 16384),
        ("node_cpu_millicores", 100, 16000),
    ]:
        value = config[key]
        if type(value) != "int" or value < low or value > high:
            fail("{} must be an integer in [{}, {}]".format(key, low, high))
    if (
        config["chain_id_start"] <= 88888
        and 88888 < config["chain_id_start"] + config["l1_count"]
    ):
        fail("L1 chain IDs must not overlap the C-Chain EVM chain ID 88888")
    if type(config["tools_image"]) != "string":
        fail("tools_image must be a string; empty builds the tools image")
    if config["staking"] not in ["poa", "native-pos", "erc20-pos"]:
        fail(
            "staking must be poa, native-pos or erc20-pos; other profiles are not certified"
        )
    if type(config["bridge"]) != "bool":
        fail("bridge must be a boolean")
    if type(config["metrics"]) != "bool":
        fail("metrics must be a boolean")
    if (
        type(config["instance_id"]) != "string"
        or not config["instance_id"]
        or config["instance_id"] == "manual"
    ):
        fail("instance_id must be a nonempty string")
    extra = 0 if config["staking"] == "poa" else 20
    config["fleet_size"] = config["validator_count"] + config["rpc_count"] + extra
    for key in ["aggregator_image", "relayer_image"]:
        if type(config[key]) != "string" or not config[key]:
            fail("{} must be a nonempty image reference".format(key))
    if type(config["node_image"]) != "string" or not config["node_image"]:
        fail("node_image must be a nonempty image reference")
    if type(config["primary_image"]) != "string" or not config["primary_image"]:
        fail("primary_image must be a nonempty image reference")
    names = ["primary-{}".format(i) for i in range(config["primary_count"])]
    for chain in range(config["l1_count"]):
        prefix = "l1-{}".format(chain)
        names.extend(
            [
                "{}-validator-{}".format(prefix, i)
                for i in range(config["validator_count"])
            ]
        )
        names.extend(
            ["{}-rpc-{}".format(prefix, i) for i in range(config["rpc_count"])]
        )
        if extra:
            names.extend(["{}-bootstrap-{}".format(prefix, i) for i in range(20)])
    validate_node_config(config["node_config"], "node_config")
    for scope in ["role_config", "node_overrides"]:
        if type(config[scope]) != "dict":
            fail("{} must be a mapping".format(scope))
        for name, overrides in config[scope].items():
            if scope == "role_config" and name not in ["primary", "validator", "rpc"]:
                fail("Unknown node role '{}'".format(name))
            if scope == "node_overrides" and name not in names:
                fail("Unknown node '{}'".format(name))
            validate_node_config(overrides, scope + "." + name)
    for scope in ["c_chain_config", "l1_chain_config"]:
        if type(config[scope]) != "dict":
            fail("{} must be a mapping".format(scope))
        if config[scope].get("warp-api-enabled", True) != True:
            fail("warp-api-enabled is required for validator management")
    validate_deployers(config)
    return config


def validate_deployers(config):
    # Contract addresses are fixed before conversion; nonces and code must not
    # displace deployments from these public development accounts.
    reserved = ["8db97c7cece249c2b98bdc0226cc4c2a57bf52fc"]
    if config["bridge"]:
        reserved.extend(
            [
                "f7edc8fa1ecc32967f827c9043fcae6ba73afa5c",
                "4cceba2d7d2b4fdce4304d3e09a1fea9fbeb1528",
            ]
        )
    allocations = config["l1_genesis"].get("alloc", {})
    if type(allocations) != "dict":
        fail("l1_genesis.alloc must be a mapping")
    for address, account in allocations.items():
        if type(address) != "string" or type(account) != "dict":
            fail("l1_genesis.alloc must map address strings to account mappings")
        normalized = address.lower()
        if normalized.startswith("0x"):
            normalized = normalized[2:]
        if normalized in reserved:
            nonce = account.get("nonce", 0)
            if type(nonce) == "string":
                nonce = int(nonce, 0)
            if (
                type(nonce) != "int"
                or nonce != 0
                or account.get("code", "") not in ["", "0x"]
            ):
                fail(
                    "l1_genesis.alloc.{} must have zero nonce and no code; reserved deployer".format(
                        address
                    )
                )


# Paths, identities, and network wiring are generated by the package. Allowing
# overrides here would leave Kurtosis port metadata and peer discovery stale.
MANAGED_NODE_KEYS = [
    "staking-ephemeral-cert-enabled",
    "staking-ephemeral-signer-enabled",
    "staking-rpc-signer-endpoint",
    "staking-host",
    "genesis-file",
    "genesis-file-content",
    "network-id",
    "data-dir",
    "config-file",
    "chain-config-dir",
    "chain-config-content",
    "http-host",
    "http-port",
    "staking-port",
    "public-ip",
    "public-ip-resolution-service",
    "bootstrap-ids",
    "bootstrap-ips",
    "track-subnets",
    "plugin-dir",
    "staking-tls-cert-file",
    "staking-tls-key-file",
    "staking-signer-key-file",
    "staking-tls-cert-file-content",
    "staking-tls-key-file-content",
    "staking-signer-key-file-content",
]


def validate_node_config(config, label):
    if type(config) != "dict":
        fail("{} must be a mapping".format(label))
    for key in config:
        if type(key) != "string":
            fail("{} keys must be strings".format(label))
        if key in MANAGED_NODE_KEYS:
            fail("{}.{} is managed by the package".format(label, key))
