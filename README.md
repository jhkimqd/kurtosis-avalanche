# kurtosis-avalanche

A [Kurtosis](https://docs.kurtosis.com/) package for local Avalanche devnets. It starts a **Primary Network** (P-, X-, and C-Chain) and one or more **Avalanche L1s**: Subnet-EVM blockchains with their own validators.

The package registers each L1 and its validators, supports Proof of Authority and Proof of Stake, and can add a token bridge and an observability stack: metrics, logs, and Grafana dashboards.

> For local development and testing only. Funded accounts use public private keys. Never use these keys for real funds.

## Network architecture

The default Proof of Stake network ([examples/pos.yml](examples/pos.yml)) after setup. Each box is a container; temporary bootstrap validators are removed during setup.

```mermaid
flowchart TB
    subgraph enclave["Kurtosis enclave"]
        direction TB
        subgraph primary["Primary Network: P-, X-, and C-Chain"]
            direction LR
            P0["primary-0"]
            P1["primary-1"]
            P2["primary-2"]
            P0 ~~~ P1 ~~~ P2
        end
        subgraph l1["Avalanche L1"]
            direction TB
            subgraph validators["Subnet-EVM validators"]
                direction LR
                V0["l1-0-validator-0"]
                V1["l1-0-validator-1"]
                V2["l1-0-validator-2"]
                V3["l1-0-validator-3"]
                V4["l1-0-validator-4"]
                V0 ~~~ V1 ~~~ V2 ~~~ V3 ~~~ V4
            end
            subgraph services["RPC and messaging"]
                direction LR
                R["l1-0-rpc-0<br/>RPC node"]
                A["l1-0-aggregator<br/>Signature aggregator"]
                B["l1-0-relayer<br/>ICM relayer"]
                R ~~~ A ~~~ B
            end
            validators ~~~ services
        end
        subgraph support["Support services"]
            direction LR
            T["tools<br/>Setup and checks"]
            C["alloy<br/>Collector"]
            M["prometheus<br/>Metrics store"]
            L["loki<br/>Log store"]
            G["grafana<br/>Dashboards"]
            T ~~~ C ~~~ M ~~~ L ~~~ G
        end
        primary ---|"registered on P-Chain"| l1
        l1 ~~~ support
    end
```

## Requirements

- A running [Docker](https://docs.docker.com/get-docker/) runtime.
- The [Kurtosis CLI](https://docs.kurtosis.com/install) with its default Docker backend. CI uses version 1.18.2.
- Enough CPU, memory, and disk for your chosen topology. More validators and L1s require more resources.

The first run downloads images and builds the tools image from source. Default images are pinned by digest in [constants.star](src/config/constants.star):

| Component | Version |
| --- | --- |
| AvalancheGo, for the Primary Network | v1.15.0 |
| AvalancheGo with Subnet-EVM, for the L1 nodes | v1.15.0 |
| Signature aggregator | v0.6.0 |
| ICM relayer | v1.8.2 |
| Alloy | v1.22.0 |
| Grafana | v13.3.1 |
| Loki | v3.7.10 |
| Prometheus | v3.2.1 |

## Quick start

Clone this repository and run these commands from its directory:

```sh
kurtosis engine start
kurtosis run --enclave avalanche . --args-file examples/poa.yml
kurtosis enclave inspect avalanche
```

Choose an example or supply your own arguments file:

| File | Network |
| --- | --- |
| [examples/poa.yml](examples/poa.yml) | A minimal Proof of Authority network. |
| [examples/pos.yml](examples/pos.yml) | Proof of Stake with a token bridge and the observability stack. Shows every argument with its default. |

Use a fresh enclave name for each deployment. To remove the network:

```sh
kurtosis enclave rm -f avalanche
```

## Configure

Pass your YAML file with `--args-file`. Without one, the package uses the defaults shown in `examples/pos.yml`.

| Argument | Meaning |
| --- | --- |
| `primary_network.validator_count` | Number of Primary Network validators. |
| `l1.count` | Number of L1s. All L1s use the same configuration. |
| `l1.validator_management` | `poa`, `native-pos` (stake the L1's native token), or `erc20-pos` (stake an ERC-20 token). |
| `l1.validator_count`, `l1.rpc_count` | Validators and non-validating RPC nodes per L1. |
| `l1.chain_id` | EVM chain ID of the first L1; each subsequent L1 increments it by one. |
| `bridge` | Deploy a token bridge between the C-Chain and each L1. |
| `metrics` | Collect metrics: Alloy scrapes every node, relayer, and signature aggregator; Prometheus stores the samples. |
| `logs` | Collect logs: every node writes its log files to a shared volume; Alloy reads them and Loki stores the lines. |
| `dashboards` | Run Grafana with dashboards for the collected metrics and logs. |
| `images` | Override service images. |

The remaining arguments configure AvalancheGo and Subnet-EVM. The reference files explain each option and its default:

| Argument | Reference |
| --- | --- |
| `node_config`, `primary_network.node_config`, `l1.node_config` | [Node flags](docs/config/node.yml) |
| `l1.genesis` | [L1 genesis: gas fees, token supply, precompiles](docs/config/l1-genesis.yml) |
| `l1.subnet_config` | [L1 consensus and privacy](docs/config/l1-subnet.yml) |
| `l1.chain_config` | [L1 APIs, caches, and pruning](docs/config/l1-chain.yml) |
| `primary_network.c_chain_config` | [C-Chain settings](docs/config/c-chain.yml) |
| `primary_network.p_chain_config`, `primary_network.x_chain_config` | [P-Chain and X-Chain settings](docs/config/p-x-chain.yml) |

Unknown arguments and options managed by the package, such as ports and key paths, are rejected. See the [L1 lifecycle guide](docs/l1-lifecycle.md) for deployment details.

## Observe

With the default arguments, as in `examples/pos.yml`, the package starts Grafana before the network, so the dashboards show the deployment as it happens. `examples/poa.yml` turns the stack off; that takes `metrics`, `logs`, and `dashboards` all set to `false`. Open the address that this command prints; no login is needed:

```sh
kurtosis port print avalanche grafana http
```

Grafana opens on an overview of the devnet. Further dashboards cover one L1, the Primary Network, interchain messaging, and the logs of every node. See the [observability guide](docs/observability.md) for the dashboards, the labels, and the limits.

## Endpoints and accounts

`kurtosis enclave inspect avalanche` lists services and their published ports. Use a node's `rpc` port with the paths below. The deployment output prints each L1's blockchain ID.

| Chain | RPC path | EVM chain ID |
| --- | --- | --- |
| P-Chain | `/ext/bc/P` | Not applicable |
| X-Chain | `/ext/bc/X` | Not applicable |
| C-Chain | `/ext/bc/C/rpc` | `88888` |
| L1 | `/ext/bc/<blockchain-id>/rpc` on an `l1-<i>-rpc-<n>` node | `77777` for the first L1 by default |

The Avalanche network ID is `88888`. The public development account, EWOQ, is funded on every chain:

| Account field | Value |
| --- | --- |
| Private key | `0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027` |
| C-Chain and L1 address | `0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC` |
| P-Chain address | `P-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p` |
| X-Chain address | `X-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p` |
