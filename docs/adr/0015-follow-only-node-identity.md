# 0015. Identify a follow-only L1 node through the Primary Network node it is connected to

Status: Accepted

## Context

`lab` writes a journal before it sends a transaction (ADR 0004). The journal includes the deployment identity: `LAB_INSTANCE` and the hash of the P-Chain genesis block, which `deploymentIdentity` (`tools/rpc.go`) reads with `platform.getBlockByHeight(0)` from the node that receives the transaction. For an EVM transaction on an L1, that node is an L1 node.

A custom AvalancheGo build adds `--p-chain-follow-only` (branch `containerman17/fde-helicon`, PR #5613). A node with the flag keeps its P-Chain in bootstrap mode for ever and rejects every `platform.*` call with HTTP 503. Measured on 2026-11-20: a deployment with `images.subnet_evm` set to such a build and `p-chain-follow-only: true` in `l1.node_config` stopped at the ValidatorManager deploy with `received status code: 503`.

## Decision

- The tools service gets `LAB_PRIMARY_URI`, the RPC URL of the first Primary Network validator. `main.star` reads it from `primary_network.planned_rpc_url` before that node exists.
- When the platform call fails, `followerIdentity` returns the identity of `LAB_PRIMARY_URI`, under three conditions: the node is not that URI, the node reports its P-Chain as not bootstrapped (`info.isBootstrapped`), and the node lists the NodeID of that Primary Network node among its connected peers (`info.peers`). Otherwise the original error stands.
- `localOnly` still runs on the node and on `LAB_PRIMARY_URI`. `LAB_INSTANCE` is unchanged.

## Consequences

- A deployment with follow-only L1 nodes works end to end. Measured: `examples/poa.yml` with `bridge: true` and a follow-only build passed every step and `scripts/check-devnet.sh`.
- For a follow-only node the guarantee is narrower. The check proves "network 88888 and connected to this deployment's first validator", not "same P-Chain genesis": the peer handshake checks the network ID, not the genesis. Inside one Kurtosis enclave, where service names resolve only to its own services, this is enough. The same holds for the per-RPC check in `lab icm-config` (`tools/interchain.go`).
- The tools service now depends on the first Primary Network validator for the identity of such a node.

## Alternatives

- Fingerprint L1 journals with the L1 genesis: it is the same in every enclave, so it cannot tell two deployments apart.
- Read the identity from the P-Chain index API of the L1 node: its first container is not the genesis block, so the identity would differ from the one of a Primary Network node.
- Pass the Primary Network URI to every `lab` command: many commands and signatures change for one case.
