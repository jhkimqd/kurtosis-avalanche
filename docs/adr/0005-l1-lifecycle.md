# 0005. Follow the ACP-77 lifecycle; start a PoS L1 with bootstrap validators

Status: Accepted

## Context

Since the Etna upgrade (ACP-77), an L1 is created in steps: create a subnet and a blockchain, convert the subnet to an L1, and hand the validator set to a ValidatorManager contract. The conversion names the first validators. Those validators hold no stake in a staking contract, because the contract does not exist yet. The ValidatorManager also limits each change of the validator set to 20% of the total weight per churn period.

## Decision

`src/l1/launcher.star` follows the same steps as a real L1:

1. Create the subnet and the blockchain.
2. Start the nodes.
3. Convert the subnet to an L1.
4. Deploy and initialize the ValidatorManager (Proof of Authority).
5. Optional: deploy the bridge.
6. Proof of Stake only: deploy the staking manager, stake each permanent validator, and remove the first validators.
7. Verify with transactions.

A PoA L1 names its permanent validators at conversion. A PoS L1 names temporary bootstrap validators, so that every permanent validator is a staked one. For `N` permanent validators of weight `S`, the package starts `ceil(20 / N)` bootstrap validators of weight `N * S / 4`. This is the largest weight that the last removal allows, and with it the smallest count that the first join allows. `tests/test_launchers.py` checks every step for every `N`.

The ValidatorManager address is predicted before the contract exists, because the conversion transaction needs it: the EWOQ account deploys a library with its first L1 transaction and the manager with its second.

## Consequences

- The devnet exercises the same contracts and P-Chain transactions as a production L1, including the PoA to PoS migration.
- A PoS L1 with few validators is slow to start: one validator needs 20 bootstrap nodes, five need 4.
- The bootstrap nodes keep running for 65 seconds after their removal from the P-Chain. Without this wait, a defect of AvalancheGo v1.15.0 stops the permanent nodes from saving uptime data (ava-labs/avalanchego#6310, fixed upstream after v1.15.3). Remove the wait when the pinned release has the fix.
- A bootstrap node keeps its data in its container, so it leaves no volume behind.
- A genesis that gives the EWOQ account a nonce or code would move the manager address; `sanity_check.star` rejects it.
- The staking rules (stake limits, durations, reward rate) are fixed in `static_files/scripts/staking.sh`. They are not arguments yet.

## Alternatives

- Name the permanent validators at conversion for PoS: they would validate without a stake, which is not what a PoS L1 looks like.
- A larger churn limit: 20% is the maximum that the contract accepts.
