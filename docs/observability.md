# Observability

The package can run a stack that collects the metrics and logs of the devnet and shows them in Grafana. Three arguments switch it, all `true` by default:

| Argument | Services | What you get |
| --- | --- | --- |
| `metrics` | `alloy`, `prometheus` | Metrics of every node, ICM relayer, and signature aggregator. |
| `logs` | `alloy`, `loki` | Log lines of every node. |
| `dashboards` | `grafana` | Dashboards for whatever is collected. Needs `metrics` or `logs`. |

Grafana Alloy is the collector. It scrapes each service every 5 seconds and sends the samples to Prometheus, which keeps 2 hours. It reads the log files of each node and sends the lines to Loki, which keeps 24 hours.

The stack starts before the Primary Network. It records the deployment itself, and it keeps running when a later step of the deployment fails.

## Open Grafana

```sh
kurtosis port print avalanche grafana http
```

Open the printed address. No login is needed to look at the dashboards. To edit a dashboard or to use Explore, sign in as `admin` with the password `admin`.

Kurtosis publishes the Grafana port on every network interface of the host. The devnet holds no secret, but do not run it on a network that you do not trust.

## Dashboards

| Dashboard | Use it to |
| --- | --- |
| Overview | See whether the devnet is healthy. The top row counts what is wrong: a green 0 is good, a red number is the count of nodes with the problem, and `no data` means that the metric is missing. |
| L1 | Follow one L1: consensus, CPU and memory of its nodes, messages, and the EVM (blocks, gas, transaction pool). It follows the production L1 dashboard. |
| Primary Network | Follow the P-, X-, and C-Chain: consensus, staking, C-Chain execution, and the network between the validators. |
| Interchain messaging | Follow the signature aggregators and, with `bridge`, the ICM relayers. |
| Logs | Read and search the logs of every node, and count errors and warnings. |

The (i) of each panel says what the panel shows and how to read it.

An EVM chain builds a block only when it has transactions. After the deployment the graphs of an L1 are therefore flat until you send transactions:

```sh
kurtosis service exec avalanche tools 'lab run http://l1-0-rpc-0:9650/ext/bc/<blockchain-id>/rpc 20'
```

The command sends 20 transfers, one after the other, and takes about 40 seconds.

`kurtosis files download avalanche deployment-manifest` gives the manifest with the RPC URL of each L1.

## Labels

Metrics and logs of a node carry the same labels, so a query for one works for the other.

| Label | Value | On |
| --- | --- | --- |
| `job` | `avalanche` for a node; `icm-relayer`, `signature-aggregator` | Metrics and logs |
| `node` | Service name, for example `l1-0-validator-1` | Metrics and logs of a node |
| `role` | `primary`, `validator`, `rpc`; also `bootstrap` on logs | Metrics and logs of a node |
| `l1` | `l1-0`, `l1-1`, ...; absent on a Primary Network validator | Metrics and logs |
| `chain` | `P`, `X`, `C`, or the blockchain ID of an L1. AvalancheGo sets it. | Metrics of one chain |
| `logger` | The log file: `main`, `P`, `X`, `C`, a blockchain ID, or `vm-factory` | Logs |
| `level` | `fatal`, `error`, `warn`, `info`, `debug`, `trace`, `verbo` | Logs |

An L1 node follows only the P-Chain and the chain of its own L1. To select the chain of an L1 without its blockchain ID, use `{l1="l1-0", chain!~"P|X|C|all"}`.

Metric names to start from: `avalanche_snowman_*` (consensus), `avalanche_network_*` (peers), `avalanche_subnetevm_vm_eth_*` (the EVM of an L1), `avalanche_evm_*` (the C-Chain), `avalanche_platformvm_*` (the P-Chain), `app_*` (relayer), and `signature_aggregator_*`.

## Check the stack

```sh
bash scripts/check-observability.sh avalanche
```

The script reads the arguments of the devnet from its manifest and checks what they enabled: every node, relayer, and signature aggregator is scraped; Loki holds lines of every node, with a level and at the time that the line states; every query of every dashboard returns data; Grafana reaches its datasources and has every dashboard. CI runs it after each deployment.

## Change a dashboard

The dashboards are generated. Change `scripts/gen-dashboards.py`, then run:

```sh
python3 scripts/gen-dashboards.py
```

Commit the script and the JSON files together; a test compares them. A change that you save in the Grafana UI is lost when the enclave is removed.

## Limits

- **Docker only.** The nodes and Alloy share one volume for the log files. Kurtosis gives two services the same volume when they name the same persistent directory key. Its documentation does not promise this, and the Kubernetes backend does not allow it.
- **Node logs only.** The relayer and the signature aggregator write no log files. Read their logs with `kurtosis service logs avalanche l1-0-relayer`.
- **`log-dir` is fixed.** The package sets it for every node; `node_config` cannot change it. The log format can change: Alloy reads the default format and `log-format: json`.
- **A line without a time keeps its read time.** A stack trace has no time of its own. Alloy gives it the time at which Alloy read it, which is the right time while Alloy follows the file.
- **Memory.** Alloy and Prometheus hold every metric series of every node. Their memory limits grow with the node count (`ALLOY_NODE_MEMORY` and `PROMETHEUS_NODE_MEMORY` in `src/config/constants.star`). With two L1s and 15 nodes, Alloy used 170 MB, Prometheus 90 MB, Loki 135 MB, and Grafana 250 MB. Larger networks were not measured.
