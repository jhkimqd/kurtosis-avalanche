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
