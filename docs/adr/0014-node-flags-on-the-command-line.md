# 0014. Pass unmanaged node flags on the command line, so that AvalancheGo rejects an unknown flag

Status: Accepted

## Context

ADR 0006 put every node flag in the node's `--config-file` and relied on AvalancheGo to validate it: "A wrong option fails when the node starts". That is not true for a config file. AvalancheGo v1.15.0 reads the file with viper (`config/viper.go`, `BuildViper`) and does not check for unknown keys. A misspelled or unsupported flag is ignored, and the node runs without it.

Measured on 2026-11-20: a stock v1.15.0 node with `"p-chain-follow-only": true` in its config file started, listed the key under `providedFlags`, and ran as a normal node. The same flag on the command line stopped the node: `couldn't configure flags: unknown flag: --p-chain-follow-only`. The flag exists only in a custom build, so a user who forgot the `images` override got no error and a network that did not do what they asked.

## Decision

`src/node/launcher.star` splits the flags of a node:

- The flags in `MANAGED_NODE_FLAGS` (identity, paths, ports, peers) stay in `node.json`, which the node reads with `--config-file`.
- All other flags, `DEFAULT_NODE_CONFIG` and the user's `node_config` layers, go on the command line as `--name=value`, sorted by name. A bool is `true` or `false`; a list is comma-separated; a mapping (`tracing-headers`) is `key=value` pairs. A flag whose value is an empty list or mapping is left out, because it means the default and AvalancheGo cannot parse an empty value for it. A flag without a value keeps the value of the layer below.

This supersedes the "Destination" of the three `node_config` arguments in ADR 0006. The rest of ADR 0006 stands.

## Consequences

- A misspelled or unsupported node flag stops the node at start. Kurtosis reports the failed service, and its log names the flag.
- A flag of a custom build works when the image has it, and fails loudly when it does not.
- A value must have its command-line form: a duration as a string such as `"5s"` (a bare number was nanoseconds in the config file), an integer flag as an integer.
- `node.json` no longer shows the user's flags. Read them in the service's command (`kurtosis service inspect`) or in the node's `initializing node` log line.
- The chain and subnet config files (`l1.chain_config`, `l1.subnet_config`, `primary_network.*_chain_config`) are still JSON files that AvalancheGo and Subnet-EVM read without a check for unknown keys. A misspelled key there is still ignored. `l1.genesis` keys that no registered precompile owns are also ignored (for example `gasPriceManagerConfig` in v1.15.0, whose precompile is not registered).

## Alternatives

- Validate the flag names in `sanity_check.star` against `docs/config/node.yml`: rejects the flags of a custom build, and repeats what AvalancheGo already knows.
- Keep the config file and add a strict mode upstream: not available in v1.15.0.
