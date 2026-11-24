# 0010. Run live functionality tests on hosted CI runners

Status: Accepted

## Context

The package checks workflow plans deployments but does not execute their transactions. The integration workflow requires an `avalanche-lab` self-hosted runner and runs only weekly or manually. A pull request therefore has no live deployment check.

## Decision

Run the existing integration matrix on GitHub-hosted Ubuntu runners for pushes, pull requests, weekly schedules, and manual dispatch. Deploy each arguments file into a fresh enclave, execute the independent checks in `helpers/check-devnet.sh`, collect diagnostics, and remove that enclave even after failure.

Use a shared composite action to install the checksum-verified Kurtosis CLI and test dependencies. Run with read-only repository permissions, without repository secrets or a self-hosted runner. Pin external actions to commit hashes.

## Consequences

- CI executes setup transactions, staking, bridge transfers, and checks of running nodes.
- Topology expectations come from the deployment manifest, rather than fixed container counts.
- Fork pull requests execute on disposable hosted runners.
- Every matrix job builds its own tools image and needs network access to public image registries.

## Alternatives

- Keep live checks on the self-hosted runner: pull requests would still need access to separately maintained infrastructure.
- Test only a fixed count of containers: that would miss transaction failures and reject valid custom topologies.
