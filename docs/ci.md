# Continuous integration

Pushes and pull requests run two workflows on GitHub-hosted Ubuntu runners:

- **package checks** runs the Python and Go tests, checks contract artifacts, lints Starlark, and plans every arguments file.
- **functionality tests** deploys the PoA, native-token PoS, ERC-20 PoS, and two-L1 networks. It also runs weekly and on manual dispatch.

Each functionality job deploys a fresh enclave, then runs `scripts/check-devnet.sh`. The checks read the deployment manifest to discover the configured validators and L1s. They verify validator registration, contract ownership, transfers, contract deployment and calls, block production, and agreement between L1 nodes. The package itself also tests bridge transfers when the bridge is enabled.

The jobs upload deployment output, check results, and an enclave dump as artifacts retained for seven days. Log capture and removal of the job's enclave run even after a failed deployment. Jobs use read-only repository permissions and public images; they need no repository secrets or self-hosted runner.

Both workflows install the same checksum-verified Kurtosis CLI through `.github/actions/setup-kurtosis`. Update its version and checksum together.

## Version watch

The **version watch** workflow runs weekly, on manual dispatch, and when its inputs change. It compares the recorded versions of both node images, the signature aggregator, ICM relayer, Prometheus, Kurtosis CLI, and Foundry with stable GitHub releases. ICM component releases are checked separately, excluding prerelease and network-specific tags.

GitHub runs [scheduled workflows from the default branch](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule). Merge the workflows there to activate their weekly schedules.

New releases produce warning annotations, a job summary, and a `version-watch` artifact. An API failure fails the job and marks the affected component as unavailable. Missing or malformed pins also fail the job with an error report. The watch never edits pins. A notice is a prompt for a compatibility review, not proof that a newer image can replace the pinned one. GitHub Actions updates are proposed separately by Dependabot.

Run the same report locally with `python3 scripts/watch-versions.py`; an optional `GITHUB_TOKEN` raises the public API rate limit.

The workflow structure follows the deployment, monitoring, and artifact collection patterns in [kurtosis-cdk](https://github.com/0xPolygon/kurtosis-cdk/tree/main/.github) and [kurtosis-pos](https://github.com/0xPolygon/kurtosis-pos/tree/main/.github).
