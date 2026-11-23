# 0006. Pass AvalancheGo options through unchanged and reject managed ones

Status: Accepted

## Context

The purpose of a devnet is to test options: consensus parameters, fees, APIs, pruning. AvalancheGo v1.15.0 has 205 node flags and several config files. A package that wraps each option in its own argument is always behind the release and hides the real names.

## Decision

The arguments file carries AvalancheGo options under their upstream names, in mappings that the package passes on unchanged:

| Argument | Destination |
| --- | --- |
| `node_config`, `primary_network.node_config`, `l1.node_config` | `--config-file` of each node |
| `primary_network.{p,x,c}_chain_config` | `<chain-config-dir>/{P,X,C}/config.json` |
| `l1.chain_config` | `<chain-config-dir>/<blockchain-id>/config.json` |
| `l1.subnet_config` | `<subnet-config-dir>/<subnet-id>.json` |
| `l1.genesis` | merged into `static_files/l1-genesis.json` |

- Node flags merge in layers: `DEFAULT_NODE_CONFIG`, then `node_config`, then the `node_config` of the section. A later layer takes precedence.
- The package sets the flags in `MANAGED_NODE_FLAGS` itself: identity, paths, ports, peers. It rejects an override, because one would break the port mapping or peer discovery.
- The package does not validate the other options. AvalancheGo does, and the node log reports the error.
- The L1 config files are named by IDs that exist only after the P-Chain transactions. `l1.sh create` therefore writes them, and every L1 node mounts them.

## Consequences

- A new AvalancheGo release needs no new argument. Regenerate the references (ADR 0007).
- A wrong option fails when the node starts, not when the arguments are parsed. The user reads the service log.
- `DEFAULT_NODE_CONFIG` changes a few upstream defaults so that a network of a few nodes is healthy: for example a Snowman sample size of 3 instead of 20. The node reference marks each one.
- A few genesis fields are managed, because the steps of the package depend on them: the chain ID, the Warp settings, the native minter, and the header gas limit.
- Some overridable options can still break a deployment, for example `http-allowed-hosts`: the services reach each other by name. The references in `docs/config/` warn where we know of such a case.
- `l1.subnet_config.validatorOnly: true` is rejected. A private L1 would lock out the RPC nodes and the signature aggregator, whose node IDs exist only during the run.

## Alternatives

- One typed argument per option: complete validation, but hundreds of arguments to maintain.
- Raw config files as input: the user would also have to supply the managed values.
