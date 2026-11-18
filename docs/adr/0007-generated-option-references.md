# 0007. Generate the option references from the pinned release

Status: Accepted

## Context

ADR 0006 exposes every AvalancheGo option, so a new user needs to know what exists, what it does, and its default. The upstream documentation is spread over several files, and it does not always match the binary: `config/config.md` lacks flags that `avalanchego --help` lists, and the default column of the Subnet-EVM `config.md` differs from `default_config.go` in places.

## Decision

`docs/config/` holds one reference file per config. Each is a commented arguments file: to use an option, copy its line and remove the `#`.

- `scripts/gen-config-reference.py` generates `node.yml` from `avalanchego --help` of the pinned image. It generates `l1-chain.yml` and `c-chain.yml` from an AvalancheGo checkout at the pinned commit: option names and types from the JSON tags in `config.go`, descriptions from `config.md`, and Subnet-EVM defaults from `default_config.go`.
- `l1-genesis.yml`, `l1-subnet.yml`, and `p-x-chain.yml` are written by hand from the Go sources, which they cite. Upstream has no table to generate them from.
- `node.yml` marks each managed flag and each package default.
- `tests/test_docs.py` checks that the managed flags and the package defaults match the code, that each file sets nothing as written, and that each file is a valid arguments file once every option is turned on.

## Consequences

- After a change to the node images, `MANAGED_NODE_FLAGS`, or `DEFAULT_NODE_CONFIG`, run the generator and commit the result.
- The generator stops when it cannot parse a flag, or when a Subnet-EVM option has no description. A new release cannot leave a silent gap there. For the C-Chain it prints each option that upstream does not describe and leaves it out; today that is one option for tests.
- A default that depends on the network ID or on the machine is listed with a fixed value and a note (`NODE_FIXED_DEFAULTS`), so the output is the same on every machine.
- The hand-written files need a review at each image bump.

## Alternatives

- Link to the upstream documentation: it describes the latest release, not the pinned one, and has the gaps named above.
- Put every option into `examples/pos.yml`: a thousand lines would hide the arguments that matter.
