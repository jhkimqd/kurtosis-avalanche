# 0009. Pin every image and contract artifact

Status: Accepted. The second bullet of the decision, the tools image, is superseded by 0018.

## Context

A devnet must start the same way next month. Tags move, and the contracts decide who may validate an L1. The Go tools link against AvalancheGo and must match the nodes exactly, because they build transactions and Warp messages for them.

## Decision

- Every image in `constants.IMAGES` is pinned by digest. A comment gives the version.
- `tools/Dockerfile` builds `lab` against the AvalancheGo commit of the node images. Its base images are pinned by digest.
- The contract artifacts in `static_files/contracts/` are committed, with their SHA-256 hashes in `hashes.json`. `helpers/check-contracts.sh` rebuilds them in a pinned Foundry image from pinned sources and compares the result.
- The `images` argument overrides any image for a test of another version.

## Consequences

- An image bump is a deliberate change in several places: `IMAGES`, the commit in `tools/Dockerfile`, the version in `tools/go.mod`, the regenerated and the hand-written files in `docs/config/`, and the version in `README.md`, `AGENTS.md`, and `examples/pos.yml`. `tests/test_docs.py` fails while one of the documents names another version.
- An override of `images.avalanchego` or `images.subnet_evm` runs nodes that the tools were not built for. It works only while the transaction formats agree.
- The contracts are not compiled at deploy time, so a run needs no compiler.

## Alternatives

- Version tags: readable, but a tag can be moved.
- Build the contracts in the enclave: slower, and the result would depend on the compiler image of the day.
