# 0011. Report upstream releases without changing pins

Status: Accepted. ADR 0013 adds Alloy, Grafana, and Loki to the watched components.

## Context

The package pins node images, tooling, and contract artifacts (ADR 0009). New upstream releases need a compatibility review and live tests. The reference kurtosis-cdk workflow checks versions on a schedule; kurtosis-pos also uses Dependabot for GitHub Actions.

## Decision

Run a read-only version watch weekly, manually, and when its inputs change. A Python script reads the current versions from the package and setup action, queries the public GitHub releases API, and writes a workflow summary and report artifact. New stable releases produce warnings. API or parsing failures fail the job instead of reporting that a dependency is current.

Watch the AvalancheGo release used by both node images, the signature aggregator, ICM relayer, Prometheus, Kurtosis CLI, and Foundry. Exclude drafts, prereleases, and network-specific ICM tags. Use Dependabot separately to propose GitHub Actions updates.

## Consequences

- No version-watch run changes a dependency pin or writes to the repository.
- The GitHub releases API is a CI dependency; the script uses only Python's standard library and the read-only built-in token.
- A release notice does not prove that the corresponding container image is available or compatible.
- Container digest changes and contract source commits still require the review described in ADR 0009.

## Alternatives

- Automatically update runtime dependencies: a newer node can disagree with the pinned transaction libraries and contract artifacts.
- Require a personal access token or Slack integration: neither is needed for a report visible in GitHub Actions.
