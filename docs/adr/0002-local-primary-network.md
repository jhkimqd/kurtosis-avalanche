# 0002. Run a local Primary Network with a fixed network ID

Status: Accepted

## Context

An Avalanche L1 cannot exist alone. Its validator set lives on the P-Chain, and its cross-chain messages are verified against that set. A devnet therefore needs a Primary Network. Fuji is slow to use, needs funded keys, and cannot be reset. The package funds all accounts from the EWOQ key, whose private key is public.

## Decision

Each enclave runs its own Primary Network: validators that run the P-Chain, X-Chain, and C-Chain from a generated genesis. It stands in for Avalanche Mainnet.

- The network ID is `88888` and cannot be configured. The C-Chain ID is also `88888`.
- Every network upgrade is active from the first block (`upgrade.json`).
- `lab` signs only for a node that reports network `88888` (`localOnly` in `tools/rpc.go`).
- An L1 cannot take the EVM chain ID of Ethereum, the Fuji C-Chain, or the Mainnet C-Chain, so a signed devnet transaction is not valid there. The guard covers only these three IDs. The real protection is that no key of the devnet is secret or holds real funds.
- The genesis validators stake for ten years, so a long-lived devnet keeps its validators.

## Consequences

- A devnet is complete and offline: no faucet, no external endpoint.
- The package does not sign a Fuji or Mainnet transaction with its publicly known keys. No argument points a node or `lab` at another network: the network ID, the genesis, and the peers are managed.
- Behaviour that depends on Mainnet state or on Mainnet-only parameters is not reproduced. The economic parameters are the AvalancheGo defaults for a custom network, plus `DEFAULT_NODE_CONFIG`.
- L1 nodes sync only the P-Chain of the Primary Network (`partial-sync-primary-network`), which keeps them small.

## Alternatives

- Attach L1s to Fuji: not reproducible, and it would put a real network within reach of public keys.
- A configurable network ID: no use case needs it, and the fixed value is what makes the signing guard simple.
- The built-in `local` network (ID 12345): its genesis is fixed in AvalancheGo, so the package could not choose the validators.
