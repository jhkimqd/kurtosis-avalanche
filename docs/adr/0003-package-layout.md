# 0003. Lay out the package like kurtosis-pos and kurtosis-cdk

Status: Accepted. ADR 0013 changes the order of the steps in `main.star`.

## Context

The first version kept defaults, validation, and node flags in one file, and built node configuration in Go. Users of kurtosis-pos and kurtosis-cdk expect a certain layout, and those packages have proven it on larger networks.

## Decision

- `src/config/` holds three modules: `constants.star` (fixed values, enums, images), `input_parser.star` (every default, `parse()`), and `sanity_check.star` (validation before any service starts).
- Each service has a launcher that exports `launch(plan, args, ...)` and returns what its callers need: a context `struct` for a node or a network, a URL for the aggregator.
- One node launcher, `src/node/launcher.star`, starts every AvalancheGo node. A role (`primary`, `validator`, `bootstrap`, `rpc`) selects the image and the config.
- `main.star` only orchestrates: tools, Primary Network, L1s, metrics, manifest.
- `examples/` holds the documented networks. `.github/configs/` holds the files that exist only for CI coverage.
- The package rejects an unknown argument instead of ignoring it.

## Consequences

- A contributor who knows kurtosis-pos finds each concern in the expected file.
- Node configuration is rendered in Starlark, so the arguments file can set any AvalancheGo flag (ADR 0006).
- A new node type is a new role, not a new launcher.
- All L1s of one deployment are identical. Per-L1 arguments would need a list of L1 mappings; that is a future ADR.

## Alternatives

- A participants list as in kurtosis-pos: more flexible, but every user would pay for it in a longer arguments file. Counts cover the present use cases.
- Separate launchers for each node role: four files that differ in a few lines.
