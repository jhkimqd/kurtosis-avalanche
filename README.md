# kurtosis-avalanche

Launch a local Avalanche primary network and configurable Subnet-EVM L1s with Kurtosis. Startup generates node identities, creates and converts each L1, initializes validator management, and checks RPC agreement and native transfers. When enabled, it also configures staking and deploys, collateralizes, and tests the C-Chain/L1 token bridge.

## Start

Install Docker and Kurtosis 1.18.2 or newer, then run from this directory:

```sh
kurtosis run --enclave avalanche-devnet . --args-file examples/default.yml
kurtosis enclave inspect avalanche-devnet
```

No host Go, Foundry, or local Avalanche checkout is needed. Kurtosis automatically builds `tools/Dockerfile`; the first build downloads pinned dependencies. Node, signature-aggregator, relayer, and Prometheus images are pinned by digest.

The default starts three primary validators, four native-staked L1 validators, one L1 RPC node, a collateralized bridge, and Prometheus. Staking initialization temporarily adds **20 bootstrap nodes per L1**, each limited to 512 MB and 500 millicores. They are removed after the final validator set is verified. Permanent nodes default to 1536 MB and 1000 millicores each. Allow several minutes for staking transitions; L1s deploy sequentially.

For a smaller PoA network without bridge, staking transitions, or metrics:

```sh
kurtosis run --enclave avalanche-small . --args-file examples/poa.yml
```

Use a fresh enclave for each deployment. `bash scripts/run.sh [profile.yml]` generates a unique name by default and rejects existing names; set `ENCLAVE` to choose one. Restart existing services instead of rerunning creation/conversion transactions against persisted state.

## Configure

Launch profiles live in `examples/`:

- `default.yml`: native PoS with a bridge and metrics.
- `poa.yml`: minimal PoA network.
- `erc20-pos.yml`: validator staking with the local STAKE token.
- `two-l1s.yml`: two native-staked L1s sharing the primary network.
- `custom.yml`: annotated node, VM, resource, image, and genesis overrides.

Use [examples/custom.yml](examples/custom.yml) as the configuration guide; [src/config/input.star](src/config/input.star) defines defaults, accepted inputs, and bounds. `bridge: false` skips bridge setup; `metrics: false` skips Prometheus. Bridged CASH is L1 gas; `native-pos` also uses it for stake, while `erc20-pos` uses STAKE.

Node options merge **defaults → global `node_config` → `role_config` → `node_overrides`**. Roles are `primary`, `validator`, and `rpc`; exact service names include `primary-0`, `l1-0-validator-0`, and `l1-0-rpc-0`. Temporary `l1-0-bootstrap-0` through `l1-0-bootstrap-19` use the validator role. Native VM options belong in `c_chain_config` and `l1_chain_config`.

Generated identities, network wiring, paths, and required Warp/minter settings cannot be overridden. Use `chain_id_start` for L1 chain IDs; genesis overrides cannot change reserved deployer nonces or code. L1 nodes default to partial primary-network sync. Custom images must retain compatible APIs, configuration, and executable/plugin paths; see the launchers in `src/`.

## Endpoints and state

`kurtosis enclave inspect avalanche-devnet` shows host-mapped RPC ports. Append `/ext/bc/P` or `/ext/bc/C/rpc` to a primary HTTP endpoint; use `/ext/bc/<blockchain-id>/rpc` for an L1. Package output includes internal RPC URLs, chain/subnet IDs, contract addresses, and artifact names. C-Chain's EVM chain ID is `88888`; the first default L1 uses `77777`.

The funded development account is `0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC`, with public private key `56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027`. **Use these keys only for local development.** This package does not connect to Fuji or mainnet. Tokens and staking settings are test fixtures, not a production staking policy.

Inspect setup results or download the successful deployment's configuration and state:

```sh
kurtosis service exec avalanche-devnet tools "cat /state/l1-0/staking.json"
kurtosis service exec avalanche-devnet tools "cat /state/l1-0/bridge/verified.json"
kurtosis files download avalanche-devnet deployment-manifest ./artifacts/manifest
kurtosis files download avalanche-devnet deployment-state ./artifacts/state
```

`staking.json` exists for PoS profiles; `bridge/verified.json` exists when the bridge is enabled. State includes generated identities, signed transaction journals, and receipts. Treat exported state as private. Failed startup may not produce the final artifacts; inspect service logs and the tools service's `/state` directory before removing the enclave.

Node databases, tools state, and relayer progress use persistent Kurtosis directories. Stop/start preserves them; removing the enclave destroys them. If filesystem watchers report `too many open files`, remove unused enclaves before starting another fleet.

## Development checks

`main.star` sequences deployment; `src/` contains launchers and validation; `tools/` supplies transaction and identity commands. `static_files/` holds the base L1 genesis and runtime contract artifacts. `contracts/` and the exporter rebuild those artifacts for maintenance, not normal startup.

```sh
python3 -m unittest discover -s tests -v
bash scripts/build.sh             # Build tools; Docker's test layer may be cached.
bash scripts/check-contracts.sh   # Compare artifacts with the pinned build (cache allowed).
bash scripts/check-package.sh     # Native Kurtosis lint and dry runs for all profiles.
```

Required CI additionally runs uncached Go race tests and vet with the runtime ABIs mounted. Dry runs verify parsing and planning, not a live deployment. The integration workflow launches fresh devnets and captures journals and logs before cleanup.
