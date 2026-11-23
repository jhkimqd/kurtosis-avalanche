# 0017. Run the block explorers by default

Status: Accepted

## Context

ADR 0014 added a Blockscout explorer for each EVM chain, off by default, because it costs memory and makes every node keep all state. In practice the explorer is the first tool a user opens on a new devnet: it shows each transaction of the deployment, its internal calls, its events, and its token transfers without a script. Users turned it on in every arguments file.

Measured on `examples/pos.yml` (docs/explorer.md), the explorers of the C-Chain and one L1 use about 1.2 GB of memory. The nodes keep the state of every block; a devnet is small, so the disk cost is small.

## Decision

`explorer` defaults to true. `examples/pos.yml` shows it, and `examples/poa.yml` inherits it. `explorer: false` restores the earlier network: no explorer services, and the upstream pruning of old state on every node. The two-L1 CI job sets `explorer: false`, so that the nightly test keeps its memory; the other CI jobs check the explorers.

This supersedes the default of ADR 0014. The rest of ADR 0014 stands.

## Consequences

- A default deployment runs `1 + 2 × (L1 count + 1)` more services and pulls three more images (about 1.3 GB) on its first run.
- A default deployment uses the host ports from `explorer_port` (28000 and up). A second devnet on the same host needs another `explorer_port`, or `explorer: false`, as it needs another `rpc_port`.
- A user who sets `pruning-enabled: true`, or a C-Chain `apis` list without `trace`, must also set `explorer: false`. The validation names the argument. The option references in `docs/config/` show upstream defaults that need it.

## Alternatives

- Keep the explorer off by default: every user who wants it repeats one line, and the default devnet shows no transactions.
- Turn it on only in `examples/pos.yml`: the file must show the default of every argument, so the default and the example would disagree.
