# Avalanche L1 institutional testing package

## Goal and decisions

Build reproducible local Avalanche networks for architecture experiments, institutional application PoCs, load tests, and failure recovery. All networks and funds are local. Public-network attachment is out of scope.

Retain PoA, native-token and ERC-20 PoS, explicit PoA-to-PoS migration, connected/disconnected/captured P-chain views, multiple EVM L1s, ICM, institutional fixtures, load and chaos testing, and a custom-VM adapter with a runnable example.

Follow the modular configuration, launch stages, contexts, optional services and CI patterns in `~/kurtosis-cdk` and `~/kurtosis-pos`. Review `../avalanche-benchmark` for reusable identity, lifecycle, oracle, load and failover logic. Review licenses before copying. Do not transplant Polygon consensus assumptions or the benchmark's SSH architecture.

Reproducibility covers immutable binaries, inputs, genesis, identities, workload seeds and evidence. It does not promise identical block histories, timing or performance.

## Architecture and interfaces

Starlark owns service orchestration. A containerized Go helper handles Avalanche transactions, reconciliation, scenarios and evidence. Kurtosis owns each node directly. The default target has three Primary validators, four equal-weight L1 validators, and a separate RPC node. Consensus parameters must fit the validator count. Derive fault expectations from actual weights and parameters.

Create real Subnets, blockchains and converted L1 registrations. Initialize the validator manager with the conversion message and verify accepted P-chain state. Manager location is fixed at creation. Provide C-chain and own-L1 profiles. Native staking requires the manager and staking contract on the L1 whose native token is used; C-chain staking uses ERC-20 assets for an institutional L1.

Version input and output schemas. Input groups cover network, L1s, observability, workloads, faults and execution. Reject unknown fields and unsupported combinations before launch. Export a deployment manifest with resolved inputs, hashes, identities, chain identifiers, contracts, endpoints and capabilities. Export experiment results with requirements, transaction outcomes, fault timeline, assertions and environment metadata. Keep private keys out of reports.

Lifecycle commands include inspect, run, validators, migrate, snapshot, restore and collect. Journal prepared/submitted/accepted/applied transitions, persist signed transactions before submission, reconcile against chain state, and never rebuild an ambiguous operation. Readiness verifies bootstrap, validators, chain identity and accepted transactions.

Custom VMs declare health, transaction, acceptance, management and messaging capabilities. EVM-only fixtures must reject incompatible adapters.

## Scenarios and evidence

### Validator management and isolation

Implement PoA registration/removal/weights and fee balances, both PoS variants, delegation where supported, uptime and reward assertions, and explicit PoA-to-PoS ownership transitions. Initial conversion validators remain distinct from staked validators. PoS admission alone does not establish a fully PoS-secured validator set.

Separate connected, temporarily disconnected, and captured isolated P-chain-view profiles. Record connectivity, observed heights and validator views, and expected management stalls. Snapshot software versions, architecture, genesis, upgrade schedule, height, format and checksums. Restore compatible snapshots into disposable networks. Verify long-duration isolation, fee depletion, stale views and reconnect reconciliation before declaring support. Report any fork requirement explicitly.

### Institutional fixtures

Each fixture defines actors, trust, authorization, workload mix, failure assertions and evidence:

- Cash ledger: authorized issuance/redemption/transfers, participant revocation, business-ID idempotency and supply reconciliation.
- Single-chain DvP: both cash and security legs commit atomically or neither does; reject unauthorized and duplicate settlement.
- Oracle settlement: publisher authorization, freshness/band checks, outage and controlled upgrade.
- Cross-L1 settlement: escrow, authenticated messaging, replay suppression, relayer interruption and reconciliation. State machine: initiated, escrowed, committed or aborted. Refund requires authenticated abort; local timeout alone cannot refund a remotely committed operation. Test late delivery and refund/release races. Do not claim atomic cross-chain DvP.

Use synthetic actors and assets. Application permission checks do not constitute regulatory compliance.

### Load and faults

Implement seeded open-loop schedules, ramps/bursts and bounded closed-loop concurrency. Distinguish business operations and transaction attempts. Report offered/submitted rates; accepted-success/revert, rejected, pending and unknown outcomes; latency distributions; backlog; RPC/resource limits and generator saturation. Reconcile after a bounded drain. Missing SLOs produce informational results, not passing capacity claims.

Faults include process stop/restart, modeled site loss, delay/loss/partition, bounded dedicated-volume disk pressure, RPC and relayer outages. Namespace-scoped networking requires capability checks. Unsupported faults fail explicitly. Persist leases and place expiry cleanup outside affected namespaces. Test controller termination. Recovery requires accepted block-hash agreement at common heights, validator views, business invariants and outcome reconciliation. Single-host site tests are simulations.

## Delivery gates

1. Compatibility proof: pin AvalancheGo, Subnet-EVM, contracts, ICM, SDK and Kurtosis; prove conversion, migration and isolated-view semantics. Record exact transitions and recovery. Start with Linux Docker, 8 vCPU, 16 GiB RAM and 50 GiB free disk as a candidate, then measure. Target cached-image startup within ten minutes. Failed gates remain documented limitations.
2. Foundation: validated entrypoint, services, PoA deployment, readiness, metrics, manifests and evidence. Two enclaves must reproduce genesis/config hashes and remain independent. Failed startup exports diagnostics.
3. Institutional correctness: all fixtures, negative authorization, retry, stale-feed, revoked-actor, insufficient-funds and messaging tests.
4. Lifecycle: both PoS variants, migration, manager placements, snapshots and P-chain profiles. Preserve chain identity and application state; recover interrupted operations; certify combinations explicitly.
5. Performance/resilience/extension: load accounting, leased faults, recovery evidence, custom-VM example. Test injection, cleanup after controller failure, outcome reconciliation and capability boundaries.

PR checks: parsing, helper tests, contract tests and short PoA smoke. Scheduled integration: migration, isolation, multi-L1 and chaos. Dedicated hardware: repeated performance comparisons with variance and environment metadata.

## Independent adversarial review

The first review found the design promising but not implementation-ready. Required dispositions:

| Finding | Correction |
|---|---|
| Unspecified migration | Pinned-stack experiment before orchestration; exact ownership and bootstrap-validator treatment |
| Disconnection conflated with freezing | Three profiles with explicit connectivity and observed heights |
| Node count implied tolerance | Derive expectations from weights and configured consensus |
| Manager placement hid dependencies | Distinct location profiles; native staking stays on native chain |
| Deterministic execution implied | Reproducible inputs only |
| Universal compatibility implied | Certified combinations and capability checks |
| Retry throughput inflation | Business IDs, attempts and reconciliation |
| Timeout refund double release | Authenticated terminal decision and race tests |
| Cleanup dies with controller | External lease owner and termination test |
| Shallow institutional examples | Actors, authorization, invariants and evidence per fixture |

Repeat adversarial review against implementation evidence before declaring completion. Record unfinished work honestly in the implementation status below.

## Implementation status

Implementation remains partial. The broad release gates are not complete.

Verified on 2026-11-17 using Linux Docker on a host with 12 logical CPUs and 31 GiB RAM:

- Clean pinned-source build, including AvalancheGo, Subnet-EVM, ICM binaries and contracts.
- Real local PoA conversion, signed conversion-proof verification and five reconciled transfers. Manager initialization also resumed successfully with its aggregator unavailable, using the stored proof and journals.
- Native-token and ERC-20 staking admission through the full L1/P-chain acknowledgement round trip. Bootstrap validators remain unstaked; these are not fully PoS networks.
- Two L1s with distinct validator identities and matching reproducible genesis inputs.
- 100/100 accepted and balance-reconciled native transfers at an offered 20 transactions/second for five seconds. Latencies are observation upper bounds, not capacity claims.
- Validator pause/recovery, independent watchdog recovery after controller termination, and network disconnection/reconnection with alias restoration.
- Three accepted L1 transfers during a 15-second Primary-validator pause. Post-recovery validator/RPC agreement at accepted height 19.
- Prometheus reported 11/11 configured scrape targets healthy in the two-L1 check. The final package additionally scrapes RPC nodes.
- Six Go tests with the race detector, 16 Solidity tests including 256-run conservation fuzzing, and seven Python configuration/recovery tests.

Evidence is generated under `artifacts/`; the final deployment manifest and journal bundle are in `artifacts/final-deployment/` and `artifacts/final-evidence/`. Integration stdout is retained under `.build/`. These runtime outputs are intentionally ignored by Git.

Remaining implementation: full PoA-validator retirement, C-chain manager placement, delegation/reward/removal suites, long-duration isolation and fee depletion, captured P-chain snapshot/restore, live cross-L1 application delivery, custom VMs, precise acceptance-latency measurement, application load mixes, netem/disk pressure and Grafana. The institutional contracts are tested fixtures; their deployment/workload integration is incomplete.

The second and final adversarial passes found journal concurrency, identity validation, proof resume, application-ID squatting, revoked-payer refunds, fault lease races, transient cleanup failure, network alias restoration, staging races and stale source-export concerns. Corrections include a single helper writer lock, unique atomic journal files, transaction hash/version validation, per-instance fingerprints, stored-proof reuse, payer-qualified IDs, claimable blocked refunds, canonical per-enclave fault locks, guarded lease expiry, cleanup retries and repeated network-identity checks. Fresh deployments use per-run uploads and refuse existing enclaves. Source builds export into empty staging directories and validate tool versions. Regression tests cover expired leases, repeated recovery verification, authorization, replay and refund behavior.

No claim of full roadmap completion or institutional performance certification is made.

## Sources

- https://build.avax.network/docs/tooling/tmpnet/guides/l1-conversion
- https://build.avax.network/docs/avalanche-l1s/validator-manager/contract
- Local reference: `../takehome/RUNBOOK-DOCKER.md`, including explicit pinned-source patches.
