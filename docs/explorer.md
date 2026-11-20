# Block explorer

The package can run a [Blockscout](https://github.com/blockscout/blockscout) block explorer for each EVM chain of the devnet: the C-Chain and every L1. The explorer is a lightweight proof of concept, not a production explorer. It shows blocks, transactions, the internal calls of each transaction (one contract calling another), the raw call trace, event logs, token transfers, ERC-20 and ERC-721 tokens with their holders, and account balances. "Limits" below lists what it does not do.

The explorer is off by default. Turn it on in your arguments file:

```yaml
explorer: true
```

ADR 0014 explains the choice of Blockscout and of its version.

## Open an explorer

The deployment output lists each explorer under `explorers`, with the address of its web app and of its API:

| Chain | Web app | API |
| --- | --- | --- |
| C-Chain | http://localhost:28000 | http://localhost:28001/api/v2 |
| L1 number n | http://localhost:28000 + 2 × (n + 1) | the next port |

With two L1s, `l1-0` opens at port 28002 and `l1-1` at port 28004. Open the address in a browser on the machine that runs Kurtosis. The web app calls the API at `localhost`, so it does not work from another machine.

`explorer_port` sets the first port. Each explorer takes two ports in a row. To run a second devnet with explorers on the same machine, give it another `explorer_port`, for example 28100. A deployment fails when one of its ports is in use.

## Services

| Service | Image | What it does |
| --- | --- | --- |
| `explorer-db` | PostgreSQL 17 | Stores the index of every explorer, one database per chain. |
| `c-chain-explorer-api`, `l1-<i>-explorer-api` | Blockscout 9.0.2 | Reads the chain from a node, writes the index, and serves the API. |
| `c-chain-explorer`, `l1-<i>-explorer` | Blockscout frontend v2.3.5 | The web app. |

The C-Chain explorer reads `primary-0`. The explorer of an L1 reads its first RPC node, `l1-<i>-rpc-0`, which does not validate.

The explorers start after the L1s and index each chain from block 0, so they show the whole deployment: the ValidatorManager, the staking manager and each stake, and the bridge. The deployment waits until each explorer reports its indexing finished. Blockscout reports that when it holds at least 99% of the blocks of the chain and no block that it holds lacks its internal calls.

## What the package changes on the nodes

With `explorer: true`, the package changes the chain config of the C-Chain and of the L1s:

| Option | Value | Why |
| --- | --- | --- |
| `pruning-enabled` (C-Chain and L1) | `false` | The explorer reads balances at old blocks and replays old transactions. A pruned node keeps only recent state. |
| `eth-apis` (L1) | the Subnet-EVM default plus `debug-tracer` | The explorer replays each transaction with `debug_traceTransaction` to find its internal calls. The C-Chain serves these methods by default. |

Your own `c_chain_config` and `l1.chain_config` still apply. The package rejects a value that would hide data from the explorer: `pruning-enabled: true`, an `eth-apis` list without `debug-tracer`, or a C-Chain `apis` list without `trace`.

## The P-Chain and the X-Chain

The P-Chain and the X-Chain are not EVM chains, and no maintained open-source explorer covers them. Ask a node directly; `kurtosis port print` finds its address:

```sh
node=$(kurtosis port print avalanche primary-0 rpc)
# call <path> <method> <params>
call() { curl -s -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "$node$1" | jq .result; }

call /ext/bc/P platform.getHeight '{}'
call /ext/bc/P platform.getCurrentValidators '{}'                              # Primary Network validators
call /ext/bc/P platform.getCurrentValidators '{"subnetID":"<subnet-id>"}'      # validators of an L1
call /ext/bc/P platform.getSubnet '{"subnetID":"<subnet-id>"}'                 # the L1 and its ValidatorManager
call /ext/bc/P platform.getTx '{"txID":"<tx-id>","encoding":"json"}'
call /ext/bc/X avm.getBalance '{"address":"X-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p","assetID":"AVAX"}'
```

The deployment output holds the subnet ID and the blockchain ID of each L1.

## What works, and what is off

A review compared the explorer with the nodes on both chains: receipts, `eth_getBalance` at old blocks, `debug_traceTransaction`, `totalSupply`, and `balanceOf`. These features matched:

| Feature | Where |
| --- | --- |
| Blocks and transactions, with status, gas, fee, value, and the revert reason | Home page, Blocks, Transactions |
| New blocks and transactions without a reload | Home page |
| Internal calls, including calls that revert and contracts that a contract creates | Transaction, block, and address pages: "Internal txns" |
| The raw call trace, byte for byte as `debug_traceTransaction` returns it | Transaction page: "Raw trace" |
| Event logs, with raw topics and data | Transaction and address pages: "Logs" |
| ERC-20 and ERC-721 transfers, holders, and total supply | Transaction page: "Token transfers"; Tokens |
| Account balances and their history | Address page |
| Search by transaction hash, address, block number or hash, token name or symbol | Search box |

The package turns these off, because they show wrong data on Avalanche or need the internet:

| Feature | Why it is off |
| --- | --- |
| Gas tracker and the gas price in the top bar | Blockscout predicts the next base fee with the Ethereum rule, which Avalanche does not follow. |
| Miner and reward of a block | Every block names 0x0100000000000000000000000000000000000000, the address that receives the fees, with a reward of 0. |
| Advanced filter | It shows a reverted transaction as a plain transfer and gives internal calls a fee. |
| REST API documentation | It loads its specification from GitHub. The JSON-RPC and Etherscan-style API pages stay. |
| Prices, charts, contract verification service, accounts, and NFT images from IPFS | They need the internet or other services. |

The package also serves the web app's fonts itself, so a page loads nothing from the internet, and it refreshes the counters on the home page and on token pages every minute instead of every one or two hours.

## Limits

These remain, and Blockscout 9.0.2 has no setting to hide them:

- **Native tokens minted on an L1.** The bridge mints the L1's native token through the NativeMinter precompile. Blockscout does not see the recipient of such a mint, so the recipient's balance stays wrong in the explorer until the account sends a transaction. The node holds the right balance.
- **Genesis balances.** Blockscout does not import the genesis allocations. An account funded at genesis shows its whole balance as a change at its first transaction, and is missing from the top accounts until then.
- **The "State" tab of a transaction.** The balance change of 0x0100…0000 shows only the priority fee, although that address receives the whole fee. On the C-Chain, the very large balance of the EWOQ account is rounded in the last digits.
- **Contract verification.** "Verify contract" stays in the menu but cannot work offline: it downloads compilers. Contracts are therefore not verified; the explorer shows bytecode and undecoded logs. The ABIs of the package's contracts are in `static_files/contracts/`.
- **Empty tabs.** "Pending" on the transactions page is always empty: the explorer does not read the transaction pool. "Forked" and "Uncles" on the blocks page are always empty: Avalanche has neither.
- **Gas target.** A block shows its gas use against half of its gas limit, the Ethereum target. Avalanche sets fees differently.
- The explorer of an L1 shows the native token as CASH with `bridge: true`, because the bridge mints it, and as TOKEN without the bridge.

## Resources

Measured on `examples/pos.yml` with `explorer: true`, after the deployment and `scripts/check-devnet.sh`:

| Service | Memory used | Limit |
| --- | --- | --- |
| `<chain>-explorer-api` | 370 MB | 1 GB |
| `<chain>-explorer` | 180 MB | 512 MB |
| `explorer-db`, for two chains | 250 MB | 384 MB + 128 MB per chain |

Each chain adds about 600 MB. The three images take about 1.3 GB of disk.

## Check the explorers

`bash scripts/check-devnet.sh <enclave>` sends transactions on each chain. With explorers, it then checks that each explorer has indexed those transactions and every internal call, and that each web app answers.

Read the log of an explorer with `kurtosis service logs <enclave> c-chain-explorer-api`. A log line with `-32601` says that the node does not serve a method that the explorer needs.
