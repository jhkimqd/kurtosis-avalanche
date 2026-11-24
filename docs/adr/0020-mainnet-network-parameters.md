# 0020. Copy the Mainnet network parameters, and start each L1 from the upstream fee config

Status: Accepted

## Context

ADR 0002 makes the local Primary Network the stand-in for Mainnet. Among its consequences: "Behaviour that depends on Mainnet state or on Mainnet-only parameters is not reproduced. The economic parameters are the AvalancheGo defaults for a custom network, plus `DEFAULT_NODE_CONFIG`." Those defaults are not the Mainnet values:

- For a network ID other than Mainnet and Fuji, AvalancheGo uses `LocalParams` (`genesis/genesis_local.go`). Its minimum L1 validator fee is 1 nAVAX per second instead of 512, its price doubles every minute instead of every day, and its X-Chain CreateAssetTx fee is 0.001 AVAX instead of 0.01.
- Since Helicon, the C-Chain gas target (ACP-176), minimum block delay (ACP-226), and minimum gas price (ACP-283) follow the votes of the validators. A validator without a vote keeps the value of the parent block. The devnet therefore stayed at the initial values (1,000,000 gas/s, 2,000 ms, 1 wei); on 2026-11-24 the Mainnet headers showed 4,000,000 gas/s, 700 ms, and 7.5 gwei. The genesis cannot set these values (`vms/saevm/cchain/genesis.go`).
- The base L1 genesis used a fee config that no upstream tool ships: a 20M gas limit, 1 gwei, and a 100M target. Subnet-EVM's `DefaultFeeConfig` is 8M, 25 gwei, and 15M. Avalanche CLI starts from the same values (`StarterFeeConfig` of `avalanche-tooling-sdk-go`) and then applies a throughput preset.

A devnet that charges less, or builds blocks under other limits, hides problems that appear on Mainnet: an L1 validator balance that runs out, a contract that does not fit in a block, a gas price that a tool does not expect.

## Decision

This ADR amends that consequence of ADR 0002 and leaves the rest of ADR 0002 in force.

- `DEFAULT_NODE_CONFIG` sets the P-Chain and X-Chain fee flags in which `LocalParams` differs from `MainnetParams`.
- `DEFAULT_C_CHAIN_CONFIG` makes every C-Chain validator vote for the Mainnet gas target, minimum block delay, and minimum gas price, as read from the Mainnet block headers.
- The base L1 genesis uses the Subnet-EVM `DefaultFeeConfig`. The minimum block delay of an L1 stays at the ACP-226 default of 2,000 ms.
- The devnet keeps the values that a network of a few nodes needs, and says why: short and long stake durations, Snowman parameters, `proposervm-use-current-height`, every upgrade active at genesis, and the test staking rules of a PoS L1.
- `docs/network-parameters.md` lists each value next to its Mainnet and Fuji values, with the source.
- These are defaults only. The package does not validate or restrict any of these values: a devnet exists to test configurations, Mainnet-like or not (ADR 0006). A P-Chain fee or staking flag that differs between the two sections of nodes is accepted too, and documented as a cause of rejected blocks.

## Consequences

- Every default can still be overridden: node flags in `node_config`, the C-Chain votes in `primary_network.c_chain_config`, and the L1 fees in `l1.genesis.config.feeConfig`.
- The C-Chain of a new devnet reaches the Mainnet values only after many blocks: about 1,400 for the gas target, 5,500 for the delay, and 118,000 for the price. The C-Chain builds blocks only for transactions, so a short-lived devnet runs close to the initial values. The package documents the votes, not a Mainnet-like C-Chain.
- The C-Chain votes are a snapshot. Mainnet validators can change their votes, and a contributor who updates the values reads them again from a Mainnet header (`docs/network-parameters.md`).
- A default L1 accepts at most 8M gas per block. A setup step that deploys a larger contract needs a fee config override. The first validators of an L1 register in one transaction, so a PoA L1 starts with at most about 60 validators (earlier about 79).

## Alternatives

- A check that rejects a P-Chain fee or staking flag that differs between the sections of nodes: it would stop a user from testing that mismatch on purpose.
- A `network_profile: mainnet | fuji` argument: a new argument group for values that the existing mappings already accept. The Fuji values are documented instead.
- The Builder Console Mainnet preset for the L1 (15M gas, denominator 48): a UI preset that can change with any release of the website, not a value in the pinned code.
- The Avalanche CLI default with constant prices (a target of 5 times the gas limit): it turns off the fee market that the devnet should let users test.
- An upgrade schedule that activates Helicon later, so that the C-Chain genesis could set the values: it breaks the rule of ADR 0002 that every upgrade is active from the first block.
