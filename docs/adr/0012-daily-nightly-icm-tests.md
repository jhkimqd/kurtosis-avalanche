# 0012. Run daily release reports and nightly application delivery tests

Status: Accepted

## Context

ADRs 0010 and 0011 schedule functionality tests and version reports weekly. The existing two-L1 deployment verifies creation, staking, transactions, and a separate C-Chain bridge for each L1. Those bridge relayers do not connect sibling L1s directly, so that deployment alone does not prove L1-to-L1 application delivery.

## Decision

Change the weekly schedules in ADRs 0010 and 0011 to daily. Keep their other decisions. Use `nightly.star` for the two-L1 CI profile: it calls the normal deployment, then adds a temporary ICM relayer configured from the manifest for every L1. No normal package argument or default service changes.

The nightly test deploys a small `MessageReceiver` contract on each L1. It accepts calls only from that L1's TeleporterMessenger and records a hash of the source blockchain, sender, and payload. The receiver artifact follows the existing pinned compiler and artifact-hash workflow.

Send a nonempty message for every ordered pair of L1s. Require a settled source transaction, an authenticated receiver event in a settled destination transaction, matching receiver and messenger state, and agreement across the destination RPC nodes. Preserve the existing network-ID and tools-service signing guards, and journal every setup transaction. Publish message and transaction IDs as a result artifact, then remove the test relayer.

## Consequences

- A nightly run creates infrastructure on a fresh hosted runner and tests application execution across sibling L1s.
- A source transaction or protocol acknowledgement alone cannot produce a passing delivery check.
- Route and node counts come from the manifest. Testing every ordered pair sends `N * (N - 1)` messages for `N` L1s.
- The ordinary package still supplies C-Chain-to-L1 bridges; the full-mesh relayer is a test fixture.

## Alternatives

- Count a C-Chain bridge transfer as an L1-to-L1 test: that does not exercise sibling routes.
- Send to an account without contract code: protocol receipt would not prove that an application executed the payload.
- Add a full-mesh relayer to every deployment: this request needs a nightly test fixture, without changing the normal service topology.
