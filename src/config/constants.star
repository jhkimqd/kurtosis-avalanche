"""Fixed values shared by every module: networks, enums, images, ports, and limits."""

# ── Networks ─────────────────────────────────────────────────────────────────

# Avalanche network ID of the local Primary Network. The Go tools sign only
# for a node that reports this ID, so they never sign for Fuji or Mainnet.
NETWORK_ID = 88888

# EVM chain ID of the local C-Chain. The generated genesis reuses the network ID.
C_CHAIN_ID = 88888

# ── Enums ────────────────────────────────────────────────────────────────────

# How an L1 decides who may validate it.
VALIDATOR_MANAGEMENT = struct(
    poa="poa",  # Proof of Authority: the contract owner adds and removes validators.
    native_pos="native-pos",  # Proof of Stake: validators lock the L1's native token.
    erc20_pos="erc20-pos",  # Proof of Stake: validators lock the STAKE ERC-20 token.
)

NODE_ROLE = struct(
    primary="primary",  # Primary Network validator: runs the P-, X-, and C-Chain.
    validator="validator",  # L1 validator: runs the L1 chain and follows the P-Chain.
    bootstrap="bootstrap",  # Temporary L1 validator that exists only during PoS setup.
    rpc="rpc",  # L1 node that serves the RPC API and does not validate.
)

# ── Images ───────────────────────────────────────────────────────────────────

# Every image is pinned by digest. Override one with the `images` argument.
IMAGES = {
    # AvalancheGo v1.15.0. Runs the Primary Network validators.
    "avalanchego": "avaplatform/avalanchego@sha256:5181093d02d2a201e890f714f8b9ebb9677de9fd6155e9c391214f3918b41710",
    # AvalancheGo v1.15.0 with the Subnet-EVM plugin. Runs every L1 node.
    "subnet_evm": "avaplatform/subnet-evm@sha256:c4a209cf7d8e3cef18eaa32ec173bd83d160a940639e16817a6eb1d33893b5e2",
    # Signature aggregator v0.6.0. Collects validator signatures for ICM messages.
    "signature_aggregator": "avaplatform/signature-aggregator@sha256:9c7d0f61f01e04c0addaa727e55c53298adb4edd4984287c68ed4b547645464a",
    # ICM relayer v1.8.2. Delivers bridge messages between the C-Chain and an L1.
    "icm_relayer": "avaplatform/icm-relayer@sha256:57bb6048b78bb7728788ced10f7f4e9c7dce42303858f3bdbd78f5d810c5dc05",
    # Prometheus v3.2.1.
    "prometheus": "prom/prometheus@sha256:6927e0919a144aa7616fd0137d4816816d42f6b816de3af269ab065250859a62",
    # Go tools. Empty builds the image from ./tools.
    "tools": "",
}

# ── Ports ────────────────────────────────────────────────────────────────────

NODE_HTTP_PORT_ID = "rpc"
NODE_HTTP_PORT_NUMBER = 9650
NODE_STAKING_PORT_ID = "staking"
NODE_STAKING_PORT_NUMBER = 9651

SIGNATURE_AGGREGATOR_API_PORT_NUMBER = 8080
SIGNATURE_AGGREGATOR_METRICS_PORT_NUMBER = 8081

# Fixed by the relayer configuration that `lab bridge-deploy` writes.
ICM_RELAYER_API_PORT_NUMBER = 9091

PROMETHEUS_PORT_NUMBER = 9090

# ── Resource limits ──────────────────────────────────────────────────────────

# Upper bounds, not reservations: CPU in millicores, memory in megabytes.
NODE_MAX_CPU = 1000
NODE_MAX_MEMORY = 1536
BOOTSTRAP_NODE_MAX_CPU = 500
BOOTSTRAP_NODE_MAX_MEMORY = 512
PROMETHEUS_MAX_MEMORY = 512

# ── L1 setup ─────────────────────────────────────────────────────────────────

# Address of the ValidatorManager contract on every L1. The P-Chain needs it
# before the contract exists, so it is predicted: the EWOQ account deploys a
# library with its first L1 transaction and the manager with its second.
VALIDATOR_MANAGER_ADDRESS = "0x17aB05351fC94a1a67Bf3f56DdbB941aE6c63E25"

# P-Chain weight of each PoA validator.
POA_VALIDATOR_WEIGHT = 1000000

# P-Chain weight of each PoS validator. It follows from the staking settings in
# tools/staking.go: a stake of 1 token divided by a weight-to-value factor of 5e12.
POS_VALIDATOR_WEIGHT = 200000

# Seconds that the bootstrap nodes of a PoS L1 keep running after the P-Chain
# removed them: the 60 seconds between two validator set reads of Subnet-EVM,
# plus a margin. See `_wait_for_uptime_trackers` in src/l1/launcher.star.
UPTIME_TRACKER_SYNC_SECONDS = 65

# Transfers sent on each L1 as a final smoke test.
SMOKE_TRANSACTION_COUNT = 5
