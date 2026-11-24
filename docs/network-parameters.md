# Network parameters

This page compares the default parameters of the devnet with those of Avalanche Mainnet and Fuji. Fuji is the public test network. For each value it names the source, and for each difference it says why the devnet differs. The Primary Network of the devnet stands in for Mainnet (ADR 0002), so its defaults copy the Mainnet values where a devnet of a few nodes can use them. Every value is only a default: the package passes any other value through to AvalancheGo without a check, so a devnet can test any fee, block limit, or staking rule (ADR 0006).

## P-Chain and X-Chain

For any network ID other than Mainnet and Fuji, AvalancheGo starts from `LocalParams` (`genesis/genesis_local.go`). The package changes the values that differ from Mainnet through `DEFAULT_NODE_CONFIG` in `src/config/input_parser.star`. The Mainnet and Fuji values are `MainnetParams` and `FujiParams` in `genesis/genesis_mainnet.go` and `genesis/genesis_fuji.go` of the pinned AvalancheGo.

Every node checks P-Chain blocks against these flags, the L1 nodes included. To change one for the whole network, set it in the top-level `node_config`. A value in `primary_network.node_config` or `l1.node_config` alone makes the other nodes reject the P-Chain blocks of the network. The package accepts it, so that such a mismatch can be tested.

| Parameter | Devnet | Mainnet | Fuji | Flag |
| --- | --- | --- | --- | --- |
| L1 validator fee, minimum price | 512 nAVAX/s | 512 nAVAX/s | 512 nAVAX/s | `validator-fees-min-price` |
| L1 validator fee, price doubling time at capacity | 1 day | 1 day | 1 hour (`51937021`) | `validator-fees-excess-conversion-constant` |
| L1 validator fee, target and capacity | 10,000 and 20,000 validators | same | same | `validator-fees-target`, `validator-fees-capacity` |
| P-Chain dynamic fee | `LocalParams` | same as `LocalParams` | same as `LocalParams` | `dynamic-fees-*` |
| X-Chain transaction fee | 0.001 AVAX | 0.001 AVAX | 0.001 AVAX | `tx-fee` |
| X-Chain CreateAssetTx fee | 0.01 AVAX | 0.01 AVAX | 0.01 AVAX | `create-asset-tx-fee` |
| Minimum validator stake | 2,000 AVAX | 2,000 AVAX | 1 AVAX | `min-validator-stake` |
| Minimum delegator stake | 25 AVAX | 25 AVAX | 1 AVAX | `min-delegator-stake` |
| Minimum delegation fee | 2% | 2% | 2% | `min-delegation-fee` |
| Minimum stake duration after Helicon | **1 second** | 48 hours | 12 hours | `helicon-min-stake-duration` |
| Maximum stake duration | **10 years** | 1 year | 1 year | `max-stake-duration` |
| Reward minting period | **10 years** | 1 year | 1 year | `stake-minting-period` |
| Snowman sample size and quorum | **3 and 2** | 20 and 15 | 20 and 15 | `snow-sample-size`, `snow-*-quorum-size` |

The L1 validator fee price rises while more L1 validators are active than the target. With N active validators, the price doubles every 86,400 × 10,000 / (N − 10,000) seconds on Mainnet: once a day at the capacity of 20,000.

The package funds each L1 validator with 100 AVAX on the P-Chain. At the minimum price that balance lasts about 6 years.

### Differences on purpose

- **Stake durations.** Tests add and remove Primary Network validators within seconds. The genesis validators stake for ten years, so that a long-lived devnet keeps them. The minting period must be at least the maximum stake duration.
- **Snowman parameters.** A poll cannot sample 20 validators in a network of 2 to 5.
- **`proposervm-use-current-height`.** On Mainnet it is off. On the devnet, a change of an L1 validator set takes effect on the next L1 block instead of after a delay.
- **Upgrades.** Every network upgrade is active from the first block (`static_files/upgrade.json`).

## C-Chain

Since the Helicon upgrade the C-Chain has no fixed gas limit or block time. Each validator votes for three values when it builds a block, and every block moves each value a bounded step toward the votes (`vms/saevm/cchain/dynamic`):

- `gas-target`: the gas per second at which the gas price stays stable (ACP-176). The block gas limit is 20 times the target.
- `min-delay-target`: the minimum time between two blocks, in milliseconds (ACP-226).
- `min-price-target`: the lowest gas price, in wei (ACP-283).

The devnet validators vote for the Mainnet values (`DEFAULT_C_CHAIN_CONFIG` in `src/config/input_parser.star`).

| Value | Devnet vote | Mainnet | Fuji | A new chain starts at | Blocks from the start to the Mainnet value |
| --- | --- | --- | --- | --- | --- |
| Gas target | 4,000,000 gas/s | 4,000,000 gas/s | 1,600,000 gas/s | 1,000,000 gas/s | about 1,400 |
| Block gas limit | 80,000,000 | 80,000,000 | 32,000,000 | 20,000,000 | follows the target |
| Minimum block delay | 700 ms | 700 ms | 900 ms | 2,000 ms | about 5,500 |
| Minimum gas price | 7.5 gwei | 7.5 gwei | 10 wei | 1 wei | about 118,000 |

The genesis cannot set the three values: `vms/saevm/cchain/genesis.go` always writes the initial ones. A new devnet therefore starts at the initial values and reaches the Mainnet values only after the number of blocks in the last column. The C-Chain builds a block only when it has a transaction to include: after `examples/pos.yml` it holds about 11 blocks, and after `examples/poa.yml` none. A devnet therefore runs close to the initial values until it has carried many transactions. The price changes slowest: it doubles at most once per 3,600 blocks.

To vote like Fuji, set the three keys in `primary_network.c_chain_config`:

```yaml
primary_network:
  c_chain_config:
    gas-target: 1600000
    min-delay-target: 900
    min-price-target: 10
```

To keep the initial values, vote for them: `gas-target: 1000000`, `min-delay-target: 2000`, `min-price-target: 1`.

### Where the Mainnet and Fuji values come from

Validators can change their votes at any time, so the values are not in the AvalancheGo source. They were read from the latest block header of each network on 2026-11-24. Each header carries the current state of the three values as an exponent:

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",false]}' \
  https://api.avax.network/ext/bc/C/rpc |   # Fuji: https://api.avax-test.network/ext/bc/C/rpc
  jq '.result | {gasLimit, targetExponent, minDelayExcess, minPriceExponent}'
```

The functions of `vms/saevm/cchain/dynamic` turn the exponents into values:

| Value | Formula |
| --- | --- |
| Gas target, gas/s | 1,000,000 × e^(`targetExponent` / 2^25) |
| Minimum block delay, ms | e^(`minDelayExcess` / 2^20) |
| Minimum gas price, wei | e^(`minPriceExponent` / 415,828,534,307,635,077) |

## L1

An L1 has no Mainnet value: each L1 chooses its own fee config in its genesis, and the genesis is final once the L1 exists. The package starts from the Subnet-EVM default fee config (`DefaultFeeConfig` in `graft/subnet-evm/params/extras/config.go`), the only standard in the pinned code. It is also the C-Chain fee config from before ACP-176. Avalanche CLI starts from the same values (`StarterFeeConfig` of `avalanche-tooling-sdk-go`), then replaces the gas limit and the target with its throughput preset. The Builder Console preselects its Testnet preset. No tool therefore produces exactly this config by default. Set `l1.genesis.config.feeConfig` to use other values (`docs/config/l1-genesis.yml`).

| Field | Devnet (Subnet-EVM default) | Avalanche CLI, test and production defaults | Builder Console, Mainnet preset | Builder Console, Testnet preset |
| --- | --- | --- | --- | --- |
| `gasLimit` | 8,000,000 | 8,000,000 | 15,000,000 | 100,000,000 |
| `minBaseFee` | 25 gwei | 25 gwei | 25 gwei | 1 gwei |
| `targetGas` (per 10 s) | 15,000,000 | 40,000,000 | 15,000,000 | 100,000,000 |
| `baseFeeChangeDenominator` | 36 | 36 | 48 | 48 |
| `minBlockGasCost` | 0 | 0 | 0 | 0 |
| `maxBlockGasCost` | 1,000,000 | 1,000,000 | 1,000,000 | 0 |
| `blockGasCostStep` | 200,000 | 200,000 | 200,000 | 0 |
| Minimum block delay | 2,000 ms | 2,000 ms | 2,000 ms | 2,000 ms |

Sources:

- Avalanche CLI v1.9.7: `pkg/vm/evm_settings.go`, `pkg/vm/fees.go`, and `pkg/vm/evm_prompts.go`, and `StarterFeeConfig` in `vm/evm_settings.go` of `avalanche-tooling-sdk-go`. Its test and production defaults select "low throughput" with constant gas prices. That sets `gasLimit` to 8,000,000 (the prompt text says 12 million) and `targetGas` to 5 times the gas limit, so that the base fee never rises.
- Builder Console: `components/toolbox/components/genesis/FeeConfig.tsx` and `components/toolbox/console/layer-1/create/GenesisBuilder.tsx` in `ava-labs/builders-hub`.
- Minimum block delay: 0 for `initialMinDelayMS` selects the ACP-226 initial value of 2,000 ms (`vms/evm/acp226`). The Builder Console node setup also uses 2,000 ms for `min-delay-target`.

The Granite upgrade replaced the block gas cost with the ACP-226 minimum block delay. On this devnet the block gas cost is always 0, but Subnet-EVM still requires `targetBlockRate`, `minBlockGasCost`, `maxBlockGasCost`, and `blockGasCostStep` to be valid.

### Gas limit and the size of a PoA validator set

The ValidatorManager contract registers the first validators of an L1 in one transaction, `initializeValidatorSet`. On this devnet it used about 227,000 gas plus about 123,500 gas per validator. With a block gas limit of 8,000,000, a PoA L1 can therefore start with at most about 60 validators (`l1.validator_count`). For a larger set, raise `gasLimit`. A PoS L1 starts with at most 20 bootstrap validators and is not affected.

### Differences on purpose

The staking rules of a PoS L1 are test values (`static_files/scripts/staking.sh`): a minimum stake of 1 token, a minimum stake duration of 60 seconds, and no rewards. They let the setup stake and remove validators within a few minutes. An L1 chooses these rules when it deploys its staking manager, so no network-wide standard exists.
