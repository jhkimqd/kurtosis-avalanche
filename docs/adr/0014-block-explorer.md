# 0014. Add an optional Blockscout explorer for each EVM chain, pinned to its newest public GPL images

Status: Accepted. Its default (`explorer: false`) is superseded by [0017](0017-explorer-by-default.md), and its fixed host ports (`explorer_port`) by [0019](0019-random-host-ports.md).

## Context

The package had no block explorer. A user read the chains through JSON-RPC, `cast`, or the Grafana dashboards, none of which shows a transaction, its internal calls, its event logs, or a token transfer.

The C-Chain and every L1 are EVM chains. The P-Chain and the X-Chain are not; they have their own APIs (`platform.*`, `avm.*`).

The open-source explorers for EVM chains, as of 2026-11:

| Explorer | Licence | Needs from the node | Fit |
| --- | --- | --- | --- |
| Blockscout | GPL-3.0 up to backend v10.2.6 and frontend v2.7.1; a proprietary "Blockscout Licence" from backend v11.0.0 and frontend v2.8.0 (2026-04-22) | standard JSON-RPC, `debug_trace*` for internal calls | Used by Ethereum testnets, rollups, and the Kurtosis packages ethereum-package and kurtosis-cdk |
| Otterscan | MIT | the `ots_*` namespace of Erigon, Reth, or Anvil | Neither AvalancheGo VM serves `ots_*` |
| Ethernal | MIT | standard JSON-RPC | Self-hosting is in beta; Node.js, PostgreSQL, Redis, and workers |
| Expedition, Alethio lite explorer | Apache-2.0, MIT | standard JSON-RPC | Archived |

The release workflows of Blockscout push images to private repositories (`ghcr.io/blockscout/blockscout-private`); a manual workflow copies a release to the public ones. The public repositories stop at backend 9.0.2 (2025-08-14) and frontend v2.3.5 (2025-10-14). The GPL releases after them, up to backend v10.2.6 and frontend v2.7.1, have no public image. Both pinned images carry GPL-3.0 in their labels and source trees, and exist for `linux/amd64` and `linux/arm64`.

The pinned AvalancheGo activates every network upgrade at genesis (`static_files/upgrade.json`). The C-Chain therefore runs the SAE VM (`vms/saevm/cchain`), which serves `debug_trace*` by default. Subnet-EVM serves them only with `debug-tracer` in its `eth-apis` list, and a live run of Blockscout against a Subnet-EVM node without it logged `-32601 method not found` for every block. Both VMs prune old state by default (`pruning-enabled`).

## Decision

Add the boolean argument `explorer`, false by default. With it, `src/explorer/launcher.star` starts, after the L1s:

- `explorer-db`: one PostgreSQL with one database per chain.
- Per EVM chain, `<chain>-explorer-api` (Blockscout backend: indexer and API) and `<chain>-explorer` (Blockscout frontend). The chain is `c-chain` or the L1 name. The explorer of an L1 reads its first RPC node, so the indexer adds no load to a validator.

Pin Blockscout backend 9.0.2 and frontend v2.3.5: the newest GPL-3.0 releases with public images.

With `explorer`, the package sets `pruning-enabled: false` on the C-Chain and on the L1, and adds `debug-tracer` to the `eth-apis` of the L1. It rejects a user config that turns pruning back on or removes tracing. The explorer indexes each chain from block 0 after the deployment: it replays old transactions and reads balances at old blocks.

Publish the web app and the API of explorer i on the fixed host ports `explorer_port + 2i` and `explorer_port + 2i + 1` (argument `explorer_port`, default 28000). The web app runs in the browser and calls the API and its WebSocket at an address that must be known when the web app starts. Kurtosis picks a random host port unless a service names one. The Blockscout API answers any origin.

The deployment waits until each explorer has indexed at least one block and reports `finished_indexing`. Blockscout 9.0.2 reports it when it holds at least 99% of the blocks and fewer than `API_INTERNAL_TRANSACTIONS_INDEXING_FINISHED_THRESHOLD` of its blocks lack internal transactions; the package sets that threshold to 1 (upstream: 1000) and starts tracing at block 1, because the genesis block has nothing to trace. A node that cannot trace fails the deployment instead of leaving an explorer without internal calls. `helpers/check-devnet.sh` then checks the data itself: a new transaction, its token transfer, and the internal calls of a known contract.

Keep the explorer a lightweight proof of concept. A feature either shows data that matches the node or is turned off:

- Turn off what needs the internet or another service: market prices, the contract verification service, accounts, the stats charts, the REST API specification from GitHub, and NFT images from IPFS gateways. Serve the fonts of the web app from the web app instead of Google Fonts.
- Turn off what shows wrong data on Avalanche: the gas tracker (it predicts the base fee with the Ethereum rule), the miner and reward of a block, and the advanced filter.
- Document what Blockscout 9.0.2 cannot turn off: the balance of an L1 account that the NativeMinter precompile credits, genesis balances, the fee recipient row of the "State" tab, and the contract verification page.
- Refresh the cached counters every minute, and let the idle Erlang schedulers sleep (`ERL_FLAGS`): with the upstream defaults each API used 8 to 22% of a core while idle, and with this flag under 2%.

## Consequences

- The default network does not change. A run with `explorer: true` pulls three more images (about 1.3 GB) and runs `1 + 2 × (L1 count + 1)` more services.
- With `explorer: true`, every node of the Primary Network and of the L1 keeps all state. A devnet is small, so the disk cost is small.
- The explorer covers the C-Chain and the L1s only. The P-Chain and the X-Chain have no explorer; docs/explorer.md shows their API calls.
- Two devnets with explorers on one host need different `explorer_port` values. A port that is in use fails the deployment when the service starts.
- The explorer works when the browser runs on the host that runs Kurtosis: the web app calls `localhost`.
- The pins do not follow Blockscout releases. The version watch (ADR 0011) does not cover Blockscout: the GPL releases after the pins have no public image, and the releases from v11.0.0 on are under the proprietary licence. A move to a newer Blockscout needs a new ADR that either builds a GPL release from source or accepts the new licence. PostgreSQL is not watched either; review its pin with the Blockscout pins.
- Contracts are not verified, so the explorer shows bytecode and raw logs. The package's own artifacts in `static_files/contracts/` hold the ABIs.

## Alternatives

- Otterscan: no AvalancheGo VM serves the `ots_*` methods that it needs.
- Ethernal: smaller user base, self-hosting in beta, and more services than Blockscout.
- The current Blockscout release: proprietary licence, with images that are not public on release.
- Build the newest GPL release (backend v10.2.6, frontend v2.7.1) from source: every first run would compile an Elixir release and a Next.js app, and the package would maintain both builds, for a proof-of-concept explorer.
- The Next.js proxy of the Blockscout frontend (`NEXT_PUBLIC_USE_NEXT_JS_PROXY`): it builds absolute URLs from the configured app host and port, so a random host port breaks every API call (the browser's Content Security Policy blocks them), and the WebSocket still needs the API host.
- A reverse proxy in front of each explorer: one more service per chain, and the host port must still be fixed.
- Index only the L1 nodes that the user names, without archive state: the explorer would log errors and show incomplete balances for blocks older than the pruning window.
- Start each explorer before its L1, so that it indexes in real time: tracing would still read old state after a restart of the explorer, and the L1 launcher would depend on the explorer.
