# 0018. Sign with platform-cli and cast from shell scripts, not a Go tool of the package

Status: Accepted

## Context

ADR 0004 put every setup step in `lab`, a Go program of about 3,000 lines plus 900 lines of tests, built from source against the AvalancheGo commit of the node images. Most of it repeated what released tools do:

- `platform-cli` (ava-labs/platform-cli, public releases) signs and sends every P-Chain transaction the package needs: `subnet create`, `chain create`, `subnet convert-to-l1`, `l1 register-validator`, `l1 set-validator-weight`, `l1 increase-validator-balance`. Its built-in key `ewoq` refuses Mainnet.
- `cast` (Foundry) deploys contracts, encodes and decodes ABI values, signs a transaction without sending it (`cast mktx`), and sends signed bytes (`cast publish`). It takes an EIP-2930 access list, which carries a signed Warp message.
- AvalancheGo creates its own staking key, TLS certificate, and BLS signer key on its first start, and reports its node ID and BLS proof of possession on `info.getNodeID`. No other released tool computes a proof of possession.

A change to `lab` needed a Go build of AvalancheGo, several minutes. vessel, a CLI with the same P-Chain commands, is a private repository, so a public package cannot build an image from it.

Two things have no tool: the two Warp messages from the P-Chain that an L1 must receive (`SubnetToL1Conversion` and `L1ValidatorRegistration`, with the protobuf justification of a removal), and CB58, the encoding of Avalanche IDs.

## Decision

- The tools image (`tools/Dockerfile`) holds only released tools: the AvalancheGo binary, copied from the node image at the digest of `IMAGES["avalanchego"]`; `platform-cli` and `cast` from their release archives, pinned by version and SHA-256 for amd64 and arm64; and curl and jq from the Debian snapshot of the base image. The base is Debian 13, because the `platform-cli` release needs glibc 2.38.
- Bash scripts in `static_files/scripts/` run the setup steps: `network.sh` (identities and genesis), `l1.sh` (create, convert, ValidatorManager), `staking.sh` (PoA to PoS), `bridge.sh`, `checks.sh`, and `icm.sh` (nightly). They are mounted at run time, so a change needs no image build. `lib.sh` holds the shared helpers, including CB58 and the two Warp messages; tests compare them with bytes that the AvalancheGo code produced.
- `network.sh` starts the AvalancheGo binary once per node, with an in-memory database and no peers, to create and read each identity. It writes the genesis with jq, in the form of tmpnet's `NewTestGenesis`. The upgrade schedule is the static file `static_files/upgrade.json`.
- EVM steps keep the exactly-once journal of ADR 0004: `cast mktx` signs, the script writes the signed bytes to `<name>.evm.json`, then `cast publish` sends them. A repeated step sends the same bytes again.
- P-Chain steps cannot be journaled that way, because `platform-cli` signs and sends in one call. The script writes `<name>.pending.pchain.json` before the call and `<name>.pchain.json` after it. A repeated step with a finished journal does nothing. A repeated step with only a pending journal runs a check on the P-Chain (for example, the subnet has a blockchain, the subnet is an L1, the validation ID is registered); if the check finds nothing, the step stops instead of sending a second transaction.
- Every journal records the deployment identity of ADR 0004 and a hash of its inputs. The scripts sign only where `TOOLS_INSTANCE` is set and only for a node of network 88888, and one lock lets one signing script run at a time.

This supersedes ADR 0004 and the second bullet of the decision of ADR 0009. ADRs 0002, 0005, 0006, 0008, 0014, and 0016 now name the scripts instead of the Go files; their decisions are unchanged.

## Consequences

- The tools image builds in seconds and has no code of the package. A script change takes effect at the next run.
- `platform-cli` gives no sign whether a failed call sent its transaction, so a P-Chain step that failed for any reason has only its check to resume. The checks: `chain` looks for the blockchain of the subnet, `conversion` for the L1, `registration` for the validation ID, and `weight` for the removed validator (only an explicit "not found" or weight 0 counts). `topup` sends again, because a second top-up only adds 1 AVAX. `subnet` has no check: a failed subnet creation stops every later run of that L1 with the path of its pending journal, and a new enclave is the remedy, as ADR 0004 already required for a second deployment.
- The genesis of an L1 is written once; a repeated `l1.sh create` with other genesis inputs stops with "journal input mismatch".
- The scripts depend on the output text of `platform-cli` for transaction IDs and on the JSON output of `cast`. A version bump of either needs a live run of both examples.
- An AvalancheGo bump changes the `COPY --from` digest in `tools/Dockerfile` (a test compares it with `IMAGES`) and may need a new `static_files/upgrade.json`.
- Contract methods are called by name; the cast signature comes from the ABI in `static_files/contracts/`. A test lists every method that the scripts call.

## Alternatives

- Keep `lab`: the package keeps code that released tools already have, and a change needs a slow build.
- vessel: same commands as `platform-cli`, but private, so `kurtosis run` could not build the image anywhere else.
- avalanche-cli: manages its own networks and keys; it does not fit nodes that Kurtosis starts.
- A small Go program only for keys and Warp messages: still a build of AvalancheGo for about 100 lines of logic that bash and the node binary cover.
- Python with `py_ecc` for the proofs of possession: one more runtime in the image, and a second BLS implementation beside the node's.
