# Architecture decision records

An ADR records one decision that shapes this package: the situation, the choice, and what follows from it. Read the accepted ADRs before you change the architecture. They explain why the code looks the way it does.

| ADR | Decision |
| --- | --- |
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions as ADRs |
| [0002](0002-local-primary-network.md) | Run a local Primary Network with a fixed network ID |
| [0003](0003-package-layout.md) | Lay out the package like kurtosis-pos and kurtosis-cdk |
| [0004](0004-journaled-go-tools.md) | Sign transactions in a Go tool that journals every step (superseded by 0018) |
| [0005](0005-l1-lifecycle.md) | Follow the ACP-77 lifecycle; start a PoS L1 with bootstrap validators |
| [0006](0006-configuration-passthrough.md) | Pass AvalancheGo options through unchanged and reject managed ones |
| [0007](0007-generated-option-references.md) | Generate the option references from the pinned release |
| [0008](0008-testing.md) | Test Starlark logic in Python and the real interpreter with dry runs |
| [0009](0009-pinned-dependencies.md) | Pin every image and contract artifact |
| [0010](0010-hosted-functionality-tests.md) | Run live functionality tests on hosted CI runners |
| [0011](0011-report-upstream-releases.md) | Report upstream releases without changing pins |
| [0012](0012-daily-nightly-icm-tests.md) | Run daily release reports and nightly application delivery tests |
| [0013](0013-observability-stack.md) | Collect metrics and logs with Alloy, and show them in Grafana |
| [0014](0014-block-explorer.md) | Add an optional Blockscout explorer for each EVM chain, pinned to its newest public GPL images |
| [0015](0015-fixed-rpc-host-ports.md) | Publish the first node of each chain on a fixed host port (superseded by 0019) |
| [0016](0016-network-description-script.md) | Describe each network in the tools service with a shell script |
| [0017](0017-explorer-by-default.md) | Run the block explorers by default |
| [0018](0018-existing-tools-and-shell-scripts.md) | Sign with platform-cli and cast from shell scripts, not a Go tool of the package |
| [0019](0019-random-host-ports.md) | Publish every port on a random host port, and print the addresses with a script |
| [0020](0020-mainnet-network-parameters.md) | Copy the Mainnet network parameters, and start each L1 from the upstream fee config |

## Add an ADR

1. Copy [template.md](template.md) to `NNNN-short-title.md` with the next number.
2. Fill it in. Keep it to one page. State facts that you verified.
3. Add it to the table above.
4. Commit it with the change that implements it.

An accepted ADR is not rewritten. To change a decision, add a new ADR and set the status of the old one to `Superseded by NNNN`.
