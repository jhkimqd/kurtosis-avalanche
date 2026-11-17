# TODO: private-network BLS signing with attested key release

Status: future work; no signer or cloud security controls are implemented by this document.

## Objective and boundaries

Build and validate remote BLS signing for an independent private Avalanche network with its own genesis, bootstrap peers, P-Chain, and application L1s. No public Mainnet/Fuji P-Chain synchronization is required; validators still synchronize the private P-Chain. Removing the P-Chain is outside scope.

Use this repository as a local compatibility and failure-testing harness. Its publicly known funded accounts, development consensus settings, generated secrets, and exported state are not a production deployment foundation. A Kurtosis enclave is a container environment, not a hardware trusted execution environment (TEE).

Recommended cloud candidate: one BLS identity per validator, signed inside an attested TEE, with KMS protecting encrypted key material and authorizing its release. This is a proposed design using established isolation and envelope-encryption patterns, not a claim of a universal institutional standard or HSM certification. AWS/GCP managed KMS/HSM signing APIs currently lack Avalanche-compatible BLS; recheck the provider algorithm matrices before implementation. If policy requires the BLS key to remain within a certified HSM boundary, stop and qualify a compatible HSM instead; a TEE does not meet that requirement automatically. Threshold BLS is a separate option requiring protocol, availability, and interoperability review.

Isolation means no public Avalanche peers and no public application endpoints. Private access to cloud KMS, storage, attestation, identity, logging, and software distribution services remains necessary; enumerate and validate every dependency. A truly disconnected/air-gapped deployment needs local alternatives.

## Target architecture

```text
Private network, repeated across validator failure domains

AvalancheGo validator (private P-Chain / application chain)
  -> loopback gRPC proxy
  -> authenticated encrypted tunnel terminating inside signer TEE
  -> caller/key binding + method/message policy
  -> Avalanche-compatible BLS implementation
  <- public key or signature only

Signer host relays transport; it does not receive plaintext BLS keys.
Signer TEE -> attested KMS key release through private service access
Signer TEE <- encrypted BLS-key blob + wrapped data key from private storage
Signer TEE -> protected audit destination (metadata/digests, no secrets)
```

Use a separate endpoint and authorization boundary for each validator key. Shared deployment tooling is acceptable; a shared credential granting access to every validator key is not. Separate signing hosts from validator hosts to reduce shared compromise, and distribute validator/signer pairs across failure domains. Do not expose the unauthenticated AvalancheGo-side gRPC endpoint beyond the local host.

AWS candidate: Nitro Enclaves, a parent-host vsock relay, and recipient-attested KMS decryption. Bind release to both caller permissions and approved workload measurements. The enclave authenticates its peer; mTLS terminated only on the untrusted parent is insufficient. GCP candidate: Confidential Space with attestation-based federated authorization to Cloud KMS resources; design and test its distinct identity and release flow separately. Neither provider integration is implemented here.

## Key and signature flows

### Provisioning

1. Approve a pinned signer build and release policy under separate software-release and key-policy authorities. Disable debug access; reject debug attestations.
2. Generate the BLS private key and data-encryption key inside the approved TEE using cryptographically secure randomness. Use authenticated encryption for the BLS key; wrap the data key with KMS. Validate the provider-specific provisioning route before implementation.
3. Initially bind the encrypted blob to an immutable pre-genesis deployment UUID, validator identity, public key, key version, and format version using authenticated metadata and an authoritative inventory. Genesis needs initial validator proofs, so its final hash cannot be a prerequisite for generating those proofs. In this provisioning state, permit only public-key retrieval and the exact registration proof inputs. After assembling genesis, approve an immutable manifest binding the deployment UUID, finalized genesis hash, validator/TLS identity, and public key before enabling runtime signing. A network ID alone does not distinguish two networks sharing that ID.
4. Persist only ciphertext, the wrapped data key, and nonsecret inventory. There is no plaintext export endpoint or ordinary-process fallback. Back up ciphertext and the required KMS/release-policy recovery dependencies.
5. Return the public key and proof of possession for the relevant private-network registration workflow. Check that the node identity, intended public key, and registration all agree.

### Startup and recovery

1. Start the approved TEE, acquire attestation, and fetch the encrypted key bundle.
2. For AWS, bind attestation to a recipient public key generated inside the enclave. KMS verifies policy and returns decrypted material encrypted to that recipient; only the enclave unwraps it. Implement and verify the GCP equivalent separately rather than assuming identical API behavior.
3. Validate bundle integrity and inventory binding, derive the public key, and compare it with the expected key before declaring readiness. A valid older blob must not silently roll back the selected key version.
4. Hold the plaintext BLS key only in TEE memory. Suppress secret-bearing logs/dumps and implement cleanup without claiming perfect zeroization from a managed runtime.
5. Admit the authenticated validator only after ownership/fencing and authorization checks succeed. Fail closed on invalid attestation, key mismatch, policy failure, or unavailable startup dependencies.

KMS is normally used for provisioning/startup key release, not each BLS signature. A running signer can continue during a KMS outage if its authorization remains valid; restarting cannot bypass KMS. Disabling KMS release does not revoke a key already loaded into memory.

### Each signing request

1. AvalancheGo invokes `PublicKey`, `Sign`, or `SignProofOfPossession` through `--staking-rpc-signer-endpoint` and the local proxy.
2. Authenticate the tunnel inside the TEE; bind its caller to exactly one key. The current protobuf has no key ID or trusted chain-context field; do not infer authorization from a caller-supplied header alone.
3. Enforce method permissions, request-size/rate/concurrency limits, and reviewed message policies. Inventory every BLS call site in the pinned AvalancheGo version before making parsing rules; not all messages are Warp messages. For supported Warp messages, validate network and source chain. Treat `SignProofOfPossession` as a separate cryptographic domain, not a one-time registration-only operation: the inspected AvalancheGo `network/peer/ip.go` also uses it for IP:port/timestamp claims. Verify this in the pinned image version and allow reviewed address changes and timestamp refreshes as well as public-key registration proofs; reject unknown formats. Do not disable this method after registration.
4. Execute BLS12-381 with G1 public keys (48 compressed bytes), G2 signatures (96 compressed bytes), and the exact domain separation tags below; return compressed output. Pin and review `blst` and serialization behavior.
5. Record caller, key/public-key version, method, request digest, outcome, approved signer version, and correlation ID without logging keys or sensitive message bodies. Ship audit records beyond the validator host; KMS logs cover key release, not these BLS operations.

```text
Sign:                 BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_
SignProofOfPossession: BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_
```

A TEE prevents some key-extraction paths; it does not establish that a legitimate caller's request is authorized by chain state. A compromised validator can still abuse its signing authority. Independently verifying chain authorization requires a trusted state source and additional policy engineering. Document the accepted residual authority explicitly.

## Implementation TODOs and acceptance gates

### Phase 0 — establish compatibility and threat model

- [ ] Select and record exact node image/source revisions. `tools/go.mod` declares AvalancheGo v1.15.0, but `tools/Dockerfile` builds the tools against upstream commit `70bd6d063b7343fd2cd8217200aaf77b57f19f68` plus `tools/ids.patch` through a Go workspace. Verify that effective tooling revision and the separately pinned primary and Subnet-EVM images support the remote-signer protocol. Do not assume a sibling source checkout equals those images.
- [ ] Inventory node roles, BLS call sites, startup proofs, expected traffic, validator registration paths, and private P-Chain dependencies. Include primary, L1 validator, RPC, and temporary bootstrap nodes; explicitly decide which require remote keys.
- [ ] Identify threats from compromised validators, parent hosts, storage operators, cloud policy administrators, release signers, and stale recovery material. Separate BLS, staking TLS/NodeID, P-Chain transaction, validator-manager, relayer, and treasury keys and their custody requirements. The BLS interface does not remote-sign TLS handshakes, P-Chain wallet transactions, or every consensus action.
- [ ] Define latency/throughput and recovery objectives, audit retention and failure policy, release approval/rollback policy, and key-compromise procedures before rollout. Define what happens when credentials/leases expire during a partition.

Gate: reviewed compatibility matrix, threat model, and measurable service objectives; no production-security claims based solely on the local harness.

### Phase 1 — local remote-signer harness

- [ ] Add an explicit opt-in remote-signer mode in `src/config/input.star`; keep managed identity settings protected instead of allowing arbitrary overrides.
- [ ] Adapt `tools/main.go` (`prepare` / `configure`) and fixture generation and `src/node/launcher.star` to use public signer identity and proof material. Never generate, embed, mount, or export BLS private keys into node fixtures, `/state`, manifests, config artifacts, logs, or failure bundles in remote mode. Preserve the separate TLS identity requirements.
- [ ] Store development signer keys only in a signer-owned volume excluded from node mounts, shared tools `/state`, manifests, exports, and failure bundles. Never reuse the current fixture-artifact flow for signer secrets. These development keys provide no hardware confidentiality.
- [ ] Launch a per-key software signer and local transport proxy for development. Integrate proof/public-key discovery before genesis/registration needs it; implement the restricted pre-genesis provisioning state followed by approved genesis-manifest activation to avoid signer/node/registration startup cycles.
- [ ] Label software signing and local credentials as development only. Production mode must reject mock attestation and plaintext fallback. Do not include production secret material in a Kurtosis package or package upload.
- [ ] Prove both signature methods, public-key retrieval, private-network startup, validator registration, and required ICM/validator-manager flows against the actual pinned images. Retain existing local profiles as the default.

Gate: the network functions through remote BLS endpoints and exported node artifacts contain no BLS private keys. A local software signer demonstrates protocol compatibility, not TEE confidentiality.

### Phase 2 — AWS attested signer pilot

- [ ] Build a minimal, pinned, reviewed signer enclave image and host relay. Terminate peer authentication and enforce policies inside the enclave. Explicitly configure deadlines, bounded queues, and fail-closed behavior; inspect whether the selected AvalancheGo client propagates deadlines.
- [ ] Define attestation-bound signer certificate enrollment, approved trust roots, validator credential enrollment, caller authorization, renewal, and revocation. Authenticate both directions inside the TEE tunnel; prevent the host relay from substituting an unapproved signer. Pin the expected BLS public key through an independently approved inventory rather than learning it from an arbitrary endpoint.
- [ ] Implement in-TEE generation, encrypted persistence, recipient-attested release, integrity/version checks, and public-key pinning. Test private endpoint/DNS/service availability from the target isolated network.
- [ ] Enforce KMS permissions and attestation restrictions with no alternative non-attested decrypt grant for this material. Control who can modify key policies, workload allowlists, image signing keys, and ciphertext inventory. Revoke old vulnerable builds rather than trusting all builds signed by a long-lived certificate.
- [ ] Implement authenticated audit shipping, monitoring, signing limits, certificate rotation, and prompt revocation/termination. A short-lived authorization mechanism must have specified renewal and trusted time/expiry semantics; a host-controlled clock or reused lease must not bypass it.
- [ ] Separate cloud infrastructure/IaC and production credentials from this local harness; choose their owner and repository before pilot deployment.

Gate: a pilot demonstrates real provider attestation and protected runtime signing. Ordinary Docker tests cannot satisfy this gate.

### Phase 3 — recovery, governance, and operational qualification

- [ ] Design active/standby ownership and fencing per validator identity. Attestation alone permits multiple approved enclaves to load the same key. Do not assume an external lease is sufficient unless the signer enforces freshness and loss of authority; test partitions and stale holders. Avoid concurrent independent nodes using the same validator identity.
- [ ] Exercise recovery from encrypted backups, host/AZ loss, KMS unavailability, and certificate expiry. Preserve KMS keys and release-policy recovery authority; ciphertext without a decryptable wrapping key is not a recoverable backup.
- [ ] Separate wrapping-key rotation/rewrapping from BLS identity replacement. Coordinate BLS replacement with the private network's supported membership/registration workflow and verify new proofs. Do not imply keys can be hot-swapped unilaterally.
- [ ] Rehearse compromise response: fence/terminate signer access, revoke caller credentials and future release, remove/replace affected validators through private-network governance, and restore service under a new key. Loaded keys are not revoked merely by disabling KMS.
- [ ] Qualify independent HSM or threshold-BLS alternatives only if needed. Check exact ciphersuites, proof method, serialization, certification scope, non-exportability, recovery, throughput, and operational failure modes; a generic BLS/Ethereum/PKCS#11 claim is insufficient.

Gate: security review and witnessed recovery/revocation exercises pass; independently review the TEE, cryptographic adapter, and release policies before production use.

## Required validation evidence

- [ ] Provisioning activation: runtime signing fails with an unfinalized or mismatched genesis manifest; required provisioning proofs remain available only under the restricted provisioning policy.
- [ ] Peer operation: exercise handshakes and refreshed/changed IP advertisements using the proof-domain method against the pinned node version.
- [ ] Interoperability: valid vectors for both BLS methods; negative tests for wrong domain, malformed encoding, mismatched public key, and policy-disallowed input. Verify that the pinned node rejects or handles invalid returned signatures as expected.
- [ ] Mutual authentication: wrong client, wrong signer certificate, relay-substituted endpoint, mismatched pinned BLS key, and expired/revoked credentials fail in both directions.
- [ ] Isolation: wrong caller, cross-validator access, unapproved/debug workload, non-attested decrypt, tampered/swapped/old blobs, and revoked builds fail without releasing keys.
- [ ] Failure behavior: unavailable/slow signer, host restart, concurrent recovery, partitioned fencing service, expired credentials, and audit outage produce the documented readiness and authorization behavior. Do not assume every BLS outage halts all consensus; measure affected startup, registration, and messaging paths.
- [ ] Performance: measure latency percentiles and sustained load against the objectives, including proxy overhead, cold startup, and recovery. Show healthy validators remain available when another signer fails.
- [ ] Secret handling: inspect fixtures, `/state`, manifests, downloaded artifacts, process arguments, and logs for BLS-key leakage. Keep unavoidable local development secrets distinct from future production artifacts.
- [ ] Repository checks when code is implemented: run Python unit tests, tools Go tests/vet, package lint/plans, and a live isolated-network integration profile. Add real cloud evidence for Phase 2; mock tests cannot establish hardware protection.

## References and review status

Revalidate these living documents and the pinned code at implementation time:

- [Avalanche node requirements and P-Chain synchronization](https://build.avax.network/docs/nodes/system-requirements)
- [AvalancheGo signer protobuf](https://github.com/ava-labs/avalanchego/blob/master/proto/signer/signer.proto), [ciphersuites](https://github.com/ava-labs/avalanchego/blob/master/utils/crypto/bls/ciphersuite.go), and [RPC client/local-proxy expectation](https://github.com/ava-labs/avalanchego/blob/master/utils/crypto/bls/signer/rpcsigner/client.go). These moving references must be replaced or supplemented with verified revision links in implementation evidence.
- [AWS KMS Sign algorithms](https://docs.aws.amazon.com/kms/latest/APIReference/API_Sign.html) and [CloudHSM signing mechanisms](https://docs.aws.amazon.com/cloudhsm/latest/userguide/pkcs11-mechanisms.html)
- [AWS Nitro Enclaves attested KMS integration](https://docs.aws.amazon.com/enclaves/latest/user/kms.html), [communication and recipient flow](https://docs.aws.amazon.com/enclaves/latest/user/connect-enclave-kms.html), and [KMS private endpoints](https://docs.aws.amazon.com/kms/latest/developerguide/kms-vpc-endpoint.html)
- [Google Cloud KMS algorithms](https://docs.cloud.google.com/kms/docs/algorithms) and [Confidential Space security model](https://docs.cloud.google.com/docs/security/confidential-space)

Adversarial plan review: an independent reviewer identified one high-priority issue (genesis/provisioning circularity) and three medium-priority issues (ongoing proof-domain peer signing, credential enrollment/server identity, and development key storage). The plan now specifies staged genesis activation, peer-signing coverage, attestation-bound mutual authentication enrollment, signer-only development storage, and corresponding validation gates. The reviewer rechecked the revised plan and reported no blocking plan issues. This is a future-work plan, not evidence of a completed implementation security assessment or deployment.
