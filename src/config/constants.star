"""Fixed values shared by every module: networks, enums, images, ports, and limits."""

# ── Networks ─────────────────────────────────────────────────────────────────

# Avalanche network ID of the local Primary Network. The setup scripts sign only
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
    # Alloy v1.22.0. Collects the metrics and logs and sends them to the stores.
    "alloy": "grafana/alloy@sha256:9acc2529bc1edb7f5b2bd801dd8334ebc80c158e3a9e5526ecd7c9a273d43189",
    # Grafana v13.3.1. Shows the metrics and logs on dashboards.
    "grafana": "grafana/grafana@sha256:0615ec4fbd4072004b7d86b46ded63013a74b7d6eb1119273dd89e8fa25c13cf",
    # Loki v3.7.10. Stores the logs.
    "loki": "grafana/loki@sha256:b43c257ccfc925d4a50b8717cac61a3b51df8c48d01847936057e5c4075a24a7",
    # Prometheus v3.2.1. Stores the metrics.
    "prometheus": "prom/prometheus@sha256:6927e0919a144aa7616fd0137d4816816d42f6b816de3af269ab065250859a62",
    # Blockscout 9.0.2, the newest GPL-3.0 release with a public image (see
    # ADR 0014). Indexes an EVM chain and serves the explorer API.
    "blockscout": "ghcr.io/blockscout/blockscout@sha256:7659f168e4e2f6b73dd559ae5278fe96ba67bc2905ea01b57a814c68adf5a9dc",
    # Blockscout frontend v2.3.5, the newest GPL-3.0 release with a public
    # image. The explorer web app.
    "blockscout_frontend": "ghcr.io/blockscout/frontend@sha256:4b69f44148414b55c6b8550bc3270c63c9f99e923d54ef0b307e762af6bac90a",
    # PostgreSQL 17.12 (Alpine). Stores the index of every explorer.
    "postgres": "postgres@sha256:526f86d93c6ea08fd3f1fe5605650cacc781b2c6013169a0ad8f42c7d3d84f32",
    # nginx 1.30.6 (Alpine). Serves the web app and the API of one explorer
    # on one address.
    "nginx": "nginx@sha256:901e593c95dc85f5a729f5765516321366ef4ac401821431d408897e95287d0a",
    # Tools service: AvalancheGo, platform-cli, cast, curl, and jq. Empty
    # builds the image from ./tools.
    "tools": "",
}

# ── Ports ────────────────────────────────────────────────────────────────────

NODE_HTTP_PORT_ID = "rpc"
NODE_HTTP_PORT_NUMBER = 9650
NODE_STAKING_PORT_ID = "staking"
NODE_STAKING_PORT_NUMBER = 9651

SIGNATURE_AGGREGATOR_API_PORT_NUMBER = 8080
SIGNATURE_AGGREGATOR_METRICS_PORT_NUMBER = 8081

# Fixed by the relayer configuration that `bridge.sh deploy` writes
# (static_files/scripts/bridge.sh).
ICM_RELAYER_API_PORT_NUMBER = 9091
ICM_RELAYER_METRICS_PORT_NUMBER = 9092

ALLOY_PORT_NUMBER = 12345
GRAFANA_PORT_NUMBER = 3000
LOKI_PORT_NUMBER = 3100
PROMETHEUS_PORT_NUMBER = 9090

EXPLORER_DB_PORT_NUMBER = 5432
EXPLORER_API_PORT_NUMBER = 4000
EXPLORER_WEB_PORT_NUMBER = 3000
EXPLORER_PROXY_PORT_NUMBER = 80

# ── Metrics and logs ─────────────────────────────────────────────────────────

# Value of the `job` label on the metrics of each kind of service. The logs of
# a node carry the same `job` as its metrics.
METRICS_JOB = struct(
    node="avalanche",
    icm_relayer="icm-relayer",
    signature_aggregator="signature-aggregator",
)

# Key of the persistent directory that holds the log files of every node.
# Kurtosis gives every service that names this key the same volume: each node
# writes to it, and Alloy reads from it.
NODE_LOGS_VOLUME_KEY = "node-logs"

# ── Resource limits ──────────────────────────────────────────────────────────

# Upper bounds, not reservations: CPU in millicores, memory in megabytes.
NODE_MAX_CPU = 1000
NODE_MAX_MEMORY = 1536
BOOTSTRAP_NODE_MAX_CPU = 500
BOOTSTRAP_NODE_MAX_MEMORY = 512
# Alloy and Prometheus hold every metric series of every node, so their limit
# grows with the network: a base amount plus an amount for each node.
ALLOY_BASE_MEMORY = 384
ALLOY_NODE_MEMORY = 48
PROMETHEUS_BASE_MEMORY = 384
PROMETHEUS_NODE_MEMORY = 32
LOKI_MAX_MEMORY = 512
GRAFANA_MAX_MEMORY = 768
# One explorer per EVM chain: an indexer with its API, a web app, and a proxy
# in front of both. The database holds every explorer, so its limit grows with
# the number of chains.
# Measured after the PoS example with a C-Chain and one L1 explorer: each API
# used 370 MB, each web app 180 MB, and the database 250 MB.
EXPLORER_API_MAX_MEMORY = 1024
EXPLORER_WEB_MAX_MEMORY = 512
EXPLORER_PROXY_MAX_MEMORY = 64
EXPLORER_DB_BASE_MEMORY = 384
EXPLORER_DB_CHAIN_MEMORY = 128

# ── L1 setup ─────────────────────────────────────────────────────────────────

# Address of the ValidatorManager contract on every L1. The P-Chain needs it
# before the contract exists, so it is predicted: the EWOQ account deploys a
# library with its first L1 transaction and the manager with its second.
VALIDATOR_MANAGER_ADDRESS = "0x17aB05351fC94a1a67Bf3f56DdbB941aE6c63E25"

# P-Chain weight of each PoA validator.
POA_VALIDATOR_WEIGHT = 1000000

# P-Chain weight of each PoS validator. It follows from the staking settings in
# static_files/scripts/staking.sh: a stake of 1 token divided by a
# weight-to-value factor of 5e12.
POS_VALIDATOR_WEIGHT = 200000

# Seconds that the bootstrap nodes of a PoS L1 keep running after the P-Chain
# removed them: the 60 seconds between two validator set reads of Subnet-EVM,
# plus a margin. See `_wait_for_uptime_trackers` in src/l1/launcher.star.
UPTIME_TRACKER_SYNC_SECONDS = 65

# Transfers sent on each L1 as a final smoke test.
SMOKE_TRANSACTION_COUNT = 5
