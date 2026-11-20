# How the package activates an L1

An Avalanche L1 is active when three things are true:

- The P-Chain of the Primary Network lists the L1 and its validators.
- A ValidatorManager contract on the L1 controls who may validate.
- The validators produce blocks.

The package reaches this state in the same steps as a real L1 (ACP-77). `src/l1/launcher.star` runs the steps. Most steps call one or more commands of the Go tool `lab` in the `tools` service. The Kurtosis output shows a line for each.

## The steps

| Step | Line in the Kurtosis output | Where | What happens | `lab` command |
| --- | --- | --- | --- | --- |
| 1 | Creating the subnet and blockchain | P-Chain | `CreateSubnetTx` creates a subnet that the EWOQ account owns. `CreateChainTx` creates a Subnet-EVM blockchain in it, with the L1 genesis. | `create` |
| 2 | Adding service `l1-<i>-...` | Enclave | The first validators and the RPC nodes start. They track the subnet. | |
| 3 | Converting to an L1 | P-Chain | `ConvertSubnetToL1Tx` names the first validators, their weight, and the address of the future ValidatorManager. It gives each validator 100 AVAX, from which the P-Chain takes its continuous fee. The chain can now build blocks. | `convert` |
| 4 | Deploying the ValidatorManager | L1 | The EWOQ account deploys the `ValidatorMessages` library and the `ValidatorManager`, then calls `initialize` and `initializeValidatorSet`. The last call carries a Warp message from the P-Chain that proves the conversion. | `manager` |
| 5 | Deploying the ICM messenger and bridge contracts | C-Chain and L1 | Only with `bridge: true`. See [The bridge](#the-bridge). | `bridge-deploy`, `bridge-activate` |
| 6 | Staking a validator; removing the bootstrap validators | L1 and P-Chain | Only with Proof of Stake. See [Proof of Stake](#proof-of-stake). | `migrate`, `finalize-pos` |
| 7 | Bridging tokens; sending test transfers; checking that the RPC nodes agree | C-Chain and L1 | The package tests the result. | `bridge-smoke`, `run`, `verify-rpcs` |

After step 4 the L1 is an active Proof of Authority L1: the owner of the ValidatorManager, the EWOQ account, adds and removes validators. `examples/poa.yml` stops here and goes to step 7.

A Warp message is a message that the validators of one chain sign together with their BLS keys. Another chain accepts it when validators with 67% of the stake have signed. The `l1-<i>-aggregator` service collects these signatures.

## Proof of Stake

A validator named in step 3 holds no stake, because the staking contract does not exist yet. A Proof of Stake L1 therefore starts with temporary bootstrap validators (`l1-<i>-bootstrap-<n>`) and replaces them:

1. `lab migrate` deploys a reward calculator and the staking manager: `NativeTokenStakingManager`, or `ERC20TokenStakingManager` with the `StakingToken` (STAKE). It transfers the ownership of the ValidatorManager to the staking manager. From now on only a stake adds a validator.
2. For each permanent validator, `lab migrate` registers it:
   - `initiateValidatorRegistration` on the L1 locks a stake of 1 token and sends a Warp message.
   - `RegisterL1ValidatorTx` carries the message to the P-Chain and gives the validator a fee balance of 100 AVAX.
   - `completeValidatorRegistration` returns the confirmation of the P-Chain to the L1.
3. For each bootstrap validator, `lab finalize-pos` removes it:
   - `initiateValidatorRemoval` on the L1 sends a Warp message.
   - `SetL1ValidatorWeightTx` carries it to the P-Chain and sets the weight to 0.
   - `completeValidatorRemoval` returns the confirmation to the L1.
4. `lab finalize-pos` checks that the P-Chain lists exactly the staked validators.
5. The package waits 65 seconds and then removes the bootstrap nodes. The wait avoids a defect of AvalancheGo v1.15.0: a node that loses the connection to a validator too soon after its removal can no longer save its uptime data. `_wait_for_uptime_trackers` in `src/l1/launcher.star` has the details.

The ValidatorManager lets the validator set change by at most 20% of its total weight per second. The number and the weight of the bootstrap validators follow from this limit: see the comment "PoS bootstrap validators" in `src/l1/launcher.star`.

## The bridge

With `bridge: true`, the package connects the C-Chain and the L1 with Avalanche ICM:

1. `lab bridge-deploy` deploys a `TeleporterMessenger` and a `TeleporterRegistry` on both chains. On the C-Chain it deploys the `CashToken` (CASH) and an `ERC20TokenHome`. On the L1 it deploys a `NativeTokenRemote`, which the L1 genesis allows to mint the native token. All L1s share one `CashToken` and one `ERC20TokenHome`, so tokens can move from one L1 to another through the home (a multi-hop transfer).
2. The `l1-<i>-relayer` service starts. It delivers the messages between the two chains.
3. `lab bridge-activate` registers the L1 side with the C-Chain side, and locks CASH on the C-Chain as collateral for the native tokens that the L1 genesis created.

   The collateral does not make the genesis tokens redeemable. The `ERC20TokenHome` releases to a remote's senders at most the amount that was bridged to that remote (`getTransferredBalance`). A larger send from the L1 burns the native tokens on the L1, and its message then fails on the C-Chain (`MessageExecutionFailed` in the `TeleporterMessenger`). Teleporter keeps the failed message, so `retryMessageExecution` can deliver it once the balance allows.
4. `lab bridge-smoke` sends 7 CASH from the C-Chain to a new account on the L1 and spends them there as gas.

## Check a running devnet

This section checks the network. For its metrics, logs, and dashboards, see the [observability guide](observability.md) and `scripts/check-observability.sh`.

`scripts/check-devnet.sh` repeats the important checks from outside the enclave, with `curl` and Foundry's `cast`. It needs Docker, the Kurtosis CLI, `curl`, and `jq`.

```sh
bash scripts/check-devnet.sh avalanche
```

The output of the Proof of Stake example, shortened:

```text
Primary Network
  ok    network ID: 88888
  ok    primary-0 has bootstrapped the P-Chain: true
  ok    primary-0 has bootstrapped the X-Chain: true
  ok    primary-0 has bootstrapped the C-Chain: true
  ...
  ok    validators on the P-Chain: 3
  ok    P-Chain height: 17
  ok    X-Chain balance of the EWOQ account: 30000000000000000 nAVAX
C-Chain
  ok    chain ID: 88888
  ok    transfer of 1 wei, receipt status: 0x1
  ok    balance of the recipient, in wei: 1
  ok    contract deployment at 0xe3573540ab8a1c4c754fd958dc1db39bbe81b208, receipt status: 0x1
  ok    contract call symbol(): "CASH"
  ok    contract transaction transfer(), receipt status: 0x1
  ok    contract state balanceOf(recipient): 5
  ok    new blocks: height 11 -> 14
l1-0 (native-pos), blockchain mhCk7MYMoNMvRNEyq1J8xci8Td9yd76D49UmCMsZmEGXWqoJf
  ok    P-Chain: the subnet is converted to an L1 (isPermissioned): false
  ok    P-Chain: address of the ValidatorManager: 0x17ab05351fc94a1a67bf3f56ddbb941ae6c63e25
  ok    P-Chain: registered validators of the L1: 5
  ok    P-Chain: validators with weight and a fee balance: 5
  ok    ValidatorManager is deployed at 0x17aB05351fC94a1a67Bf3f56DdbB941aE6c63E25
  ok    owner of the ValidatorManager: 0x789a5fdac2b37fcd290fb2924382297a6ae65860
  ok    chain ID: 77777
  ok    transfer of 1 wei, receipt status: 0x1
  ok    balance of the recipient, in wei: 1
  ok    contract deployment at 0x20bc04ad10b6300f542e694f8c3ab44db8caac65, receipt status: 0x1
  ok    contract call symbol(): "CASH"
  ok    contract transaction transfer(), receipt status: 0x1
  ok    contract state balanceOf(recipient): 5
  ok    new blocks: height 57 -> 60
  ok    l1-0-validator-0 holds block 60: 0x303297799cdc20e979d3aff11be065441bf6e7dc8c88a268272b0825f13f0350
  ...
  ok    l1-0-validator-4 holds block 60: 0x303297799cdc20e979d3aff11be065441bf6e7dc8c88a268272b0825f13f0350
  ok    l1-0-rpc-0 holds block 60: 0x303297799cdc20e979d3aff11be065441bf6e7dc8c88a268272b0825f13f0350
All checks passed
```

A chain builds a block only when it has transactions, so the height of an idle chain does not change. The script sends transactions and then checks that the height grew.

### Check by hand

Find the local port of a node and the IDs of the L1:

```sh
kurtosis port print avalanche primary-0 rpc      # for example http://127.0.0.1:32950
kurtosis port print avalanche l1-0-rpc-0 rpc
kurtosis files download avalanche deployment-manifest ./manifest
jq '.l1s[0] | {subnet_id, blockchain_id, validator_manager_address}' manifest/deployment.json
```

Ask the P-Chain about the L1. `isPermissioned: false` and a `managerAddress` show that the subnet is an L1. The second call lists its validators with their weight and fee balance.

```sh
PRIMARY=http://127.0.0.1:32950
curl -s -X POST -H 'content-type: application/json' $PRIMARY/ext/bc/P \
  --data '{"jsonrpc":"2.0","id":1,"method":"platform.getSubnet","params":{"subnetID":"<subnet_id>"}}'
curl -s -X POST -H 'content-type: application/json' $PRIMARY/ext/bc/P \
  --data '{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{"subnetID":"<subnet_id>"}}'
```

Send a transaction and deploy a contract with [Foundry](https://getfoundry.sh/). The EWOQ key is in [README.md](../README.md#endpoints-and-accounts).

```sh
L1=http://127.0.0.1:<port of l1-0-rpc-0>/ext/bc/<blockchain_id>/rpc
cast block-number --rpc-url $L1
cast send --rpc-url $L1 --private-key <EWOQ key> --value 1ether 0x000000000000000000000000000000000000dEaD
cast send --rpc-url $L1 --private-key <EWOQ key> --create $(jq -r .bytecode.object static_files/contracts/CashToken.json)
```

## The record of a deployment

`lab` writes each signed setup transaction to a journal file before it sends it. The `deployment-state` artifact holds these journals, the genesis files, and the node keys:

```sh
kurtosis files download avalanche deployment-state ./state
ls state          # c-chain  l1-0  network
ls state/l1-0     # subnet.journal.json, chain.journal.json, conversion.journal.json, ...
```

The state contains every private key of the devnet. Do not publish it if you reuse a key.
