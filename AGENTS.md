# kurtosis-avalanche

Kurtosis package for local Avalanche devnets: a Primary Network (P-, X-, and C-Chain) that stands in for Avalanche Mainnet, with one or more Avalanche L1s attached. Entry point: `main.star`. User documentation: `README.md`.

This file guides coding agents and human contributors. Read it before you change the repository.

## Quick start

```bash
kurtosis engine start
kurtosis run --enclave avalanche . --args-file examples/poa.yml   # 4 nodes and 2 explorers, about 1.5 minutes; or:
kurtosis run --enclave avalanche . --args-file examples/pos.yml   # 5 staked validators, bridge, Grafana, explorers
kurtosis enclave inspect avalanche                                # services and ports
kurtosis enclave rm -f avalanche                                  # remove the network
```

Use a new enclave for each run. The tools refuse to replay the state of one deployment onto another.

## Dev loop

```bash
kurtosis lint --format . && kurtosis lint .   # format and lint the Starlark (black)
kurtosis lint -c .                            # check the docstrings
python3 -m unittest discover -s tests         # unit tests (seconds)
bash scripts/check-package.sh                 # lint, then plan every arguments file (starts no node)
bash scripts/check-alloy.sh                   # load the Alloy pipelines in the pinned Alloy
bash scripts/build.sh                         # build the tools image; the build runs the Go tests
python3 scripts/gen-config-reference.py       # regenerate node.yml, l1-chain.yml, c-chain.yml
python3 scripts/gen-dashboards.py             # regenerate the Grafana dashboards
bash scripts/run.sh examples/poa.yml          # live run in a new enclave
bash scripts/check-devnet.sh <enclave>        # check a running devnet from the outside
bash scripts/check-observability.sh <enclave> # check its metrics, logs, and dashboards
```

The tests that read YAML need PyYAML and skip without it. A change is not verified while they skip. With `CI` set, a missing PyYAML is an error.

The generator needs Docker, the pinned node images, and an AvalancheGo checkout in `../avalanchego` that contains the pinned commit.

Run a live deployment before you report a change to `src/` or `tools/` as working. A dry run does not execute `lab`, so it cannot find a transaction or timing error.

## Repository map

| Path | Content |
| --- | --- |
| `main.star` | Entry point. Six steps: tools, observability, Primary Network, L1s, explorers, manifest. |
| `nightly.star` | Test entry point: deploy the network, then verify direct application messages between every pair of L1s. |
| `src/config/constants.star` | Network IDs, enums, pinned images, ports, limits. |
| `src/config/input_parser.star` | Every argument and its default; `parse()`. |
| `src/config/sanity_check.star` | Validation. Runs before any service starts. |
| `src/node/launcher.star` | Starts every AvalancheGo node. The role selects the image and the config. |
| `src/primary_network/launcher.star` | Primary Network validators. |
| `src/l1/launcher.star` | L1 lifecycle (ACP-77) and PoS bootstrap sizing. |
| `src/l1/signature_aggregator.star`, `src/l1/bridge.star` | Per-L1 support services. |
| `src/observability/launcher.star` | The observability stack. One file per service: `alloy.star` (collector), `prometheus.star` (metrics store), `loki.star` (log store), `grafana.star` (dashboards). |
| `src/explorer/launcher.star` | The optional Blockscout explorers and their PostgreSQL database. |
| `src/tools/launcher.star` | The tools service, the helpers that run `lab` in it, and the run of `describe-networks.sh`. |
| `tools/` | Go program `lab`: keys, genesis, transactions, checks. One file per concern; `main.go` lists the commands. |
| `static_files/` | Base L1 genesis, the shell scripts that run in the tools service (`static_files/scripts/`), the contract artifacts (`static_files/contracts/hashes.json` pins them), the Alloy pipelines (`static_files/observability/alloy/`), and the generated Grafana dashboards (`static_files/observability/grafana/dashboards/`). |
| `contracts/` | Sources of the two test tokens, the nightly message receiver, and the reproducible artifact build. |
| `examples/` | The two documented networks: `poa.yml`, `pos.yml`. |
| `.github/configs/` | Arguments files for CI coverage only. |
| `docs/config/` | Reference of the AvalancheGo options. |
| `docs/l1-lifecycle.md` | How the package activates an L1, step by step, and how to check it. |
| `docs/observability.md` | The observability stack: dashboards, labels, and limits. |
| `docs/explorer.md` | The block explorers: addresses, node changes, the P-Chain and X-Chain APIs, and limits. |
| `docs/adr/` | Architecture decision records. |
| `scripts/` | `run.sh` (deploy), `check-devnet.sh` (check a running devnet), `check-observability.sh` (check its observability stack), `check-package.sh` (lint and plan), `check-alloy.sh` (load the Alloy pipelines), `build.sh`, `check-contracts.sh`, `gen-config-reference.py`, `gen-dashboards.py`. |
| `tests/` | Python unit tests. `tests/starlark.py` loads the Starlark modules in Python. |

## Where to make a change

| Task | Files, in order |
| --- | --- |
| Add or change an argument | `input_parser.star` (default and comment) → `sanity_check.star` → `examples/pos.yml` → `README.md` table → `tests/test_config.py` |
| Change a default AvalancheGo flag | `DEFAULT_NODE_CONFIG` in `input_parser.star` → regenerate `docs/config/` |
| Take control of an AvalancheGo flag | `src/node/launcher.star` → `MANAGED_NODE_FLAGS` in `sanity_check.star` → regenerate `docs/config/` |
| Bump a node image | `IMAGES` in `constants.star` → the commit in `tools/Dockerfile` and the version in `tools/go.mod` → regenerate `docs/config/` and review its hand-written files → the version in `README.md`, `AGENTS.md`, and `examples/pos.yml` (a test compares them) → live run of both examples |
| Add a `lab` command | `tools/<concern>.go` → the command list in `tools/main.go` → the caller in `src/` |
| Add a service | `src/<name>/launcher.star` with `launch(plan, args, ...)` → `main.star` or `src/l1/launcher.star` → image in `IMAGES` → the planning function of the launcher (`planned_nodes`, `planned`), if the service serves metrics |
| Add or change a dashboard panel | `scripts/gen-dashboards.py` → `python3 scripts/gen-dashboards.py` → commit the JSON → live run → `bash scripts/check-observability.sh <enclave>`, and look at the panel with data |
| Change what Alloy collects | `static_files/observability/alloy/` → the target files in `src/observability/alloy.star` → `bash scripts/check-alloy.sh` → live run |
| Bump an observability image | `IMAGES` in `constants.star` (digest of the multi-platform index) → the version in `README.md` and `examples/pos.yml` → `bash scripts/check-alloy.sh` → live run of `examples/pos.yml` |
| Change a contract artifact | `contracts/` → `bash scripts/check-contracts.sh refresh` → review the diff |
| Add a CI-only network | `.github/configs/<name>.yml` → the matrix in `.github/workflows/integration.yml` |

`examples/pos.yml` must name every argument with its default, except `images`, which it shows as a comment. `examples/` holds exactly two files. The tests enforce both rules.

## Quick reference

| | |
| --- | --- |
| Network ID | `88888` (fixed; see ADR 0002) |
| C-Chain ID | `88888` |
| L1 chain ID | `77777`; L1 number `n` uses `77777 + n` |
| AvalancheGo | v1.15.0, commit `70bd6d063b7343fd2cd8217200aaf77b57f19f68` |
| Funded account (EWOQ) | `0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC` |
| EWOQ private key | `0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027` (public; devnet only) |
| ValidatorManager on every L1 | `0x17aB05351fC94a1a67Bf3f56DdbB941aE6c63E25` |
| RPC on the host (`rpc_port`) | P-, X-, C-Chain at http://127.0.0.1:29650 (`/ext/bc/C/rpc`), L1 `n` at port `29651 + n` (`/ext/bc/<blockchain-id>/rpc`) |
| Devnet description | `/opt/networks/<network>/` in the `tools` service (`primary-network`, `l1-<i>`), also the artifact `network-description`; written by `static_files/scripts/describe-networks.sh` |
| Grafana | `kurtosis port print <enclave> grafana http`; no login to look, `admin` / `admin` to edit |
| Explorers (default; `explorer: false` turns them off) | C-Chain at http://localhost:28000, L1 `n` at port `28000 + 2 × (n + 1)`; API on the next port |

Service names: `primary-<n>`, `l1-<i>-validator-<n>`, `l1-<i>-rpc-<n>`, `l1-<i>-bootstrap-<n>` (temporary, PoS setup only), `l1-<i>-aggregator`, `l1-<i>-relayer`, `alloy`, `prometheus`, `loki`, `grafana`, `explorer-db`, `c-chain-explorer-api`, `c-chain-explorer`, `l1-<i>-explorer-api`, `l1-<i>-explorer`, `tools`. All indexes start at 0.

Labels on every metric and log line of a node: `job` (`avalanche`), `node` (the service name), `role`, and `l1` (L1 nodes only). Logs add `logger` (the log file: `main`, `P`, `X`, `C`, or a blockchain ID) and `level`.

## Starlark conventions

These follow kurtosis-pos (`src/config/`, launcher contract) and kurtosis-cdk (`input_parser`).

- Name an import after its module: `constants`, `input_parser`, `node_launcher`, `l1_launcher`. The tools module is `tools`, because callers use its helpers (`tools.run`, `tools.read_json`).
- A launcher exports `launch(plan, args, ...)`. It returns what its callers need: a `struct` context for a node or a network, a URL for the aggregator. Callers read that value; they do not rebuild a URL or a name.
- Build a service name in one place: `generate_name()` or the launcher that owns the service.
- The observability stack starts before the network and scrapes by name. A launcher whose services it observes exports a planning function (`planned_nodes`, `planned`) that returns those services from the arguments alone. Keep it equal to what `launch` starts; a test compares them.
- Compare against `constants.VALIDATOR_MANAGEMENT.*` and `constants.NODE_ROLE.*`, never against a raw string.
- Keep every image in `constants.IMAGES`, pinned by digest, with the version in a comment.
- Keep every default in `input_parser.star`. A launcher does not call `.get(key, default)` on the arguments.
- Validate in `sanity_check.star` with `fail()`. Name the argument and the accepted values in the message.
- Prefix a module-private function with `_`.
- Pass a command to `ExecRecipe` as a list of arguments. Do not build a shell string from user input.
- Stay within the syntax that Starlark and Python share, so that `tests/starlark.py` can load the module (ADR 0008).
- Give every `plan.exec` and `plan.wait` a `description` that states what happens in plain words.

## Go conventions (`tools/`)

- `lab` signs only for network `88888` (`localOnly` in `rpc.go`) and only where `LAB_INSTANCE` is set, which is the tools service (`main.go`). Do not weaken either check.
- Every setup transaction goes through `issue` (P-Chain) or `evmTxAs` (EVM). Both write a journal before they send, so a repeated command resends the same bytes. Only the test transfers of `lab run` have no journal.
- Give each journal a stable name. A new step needs a new name.
- Run `gofmt`. The image build runs `go test ./...`; CI adds `-race` and `go vet`.

## Comments and documentation

- Write for a reader who is new to Avalanche. Explain the Avalanche term the first time a file uses it.
- Use short, active sentences and one term for one thing: "Primary Network", "L1", "validator", "RPC node", "bootstrap validator".
- A module starts with a docstring that says what it deploys. A public function documents its arguments and its return value.
- Section headers in Starlark and YAML use this form: `# ── Name ───`.
- A comment states what the code does or why. It does not tell the history of a change.
- In an arguments file, a comment above a key says what the key does, its unit, and its limits.
- `docs/config/node.yml`, `l1-chain.yml`, and `c-chain.yml` are generated. Change `scripts/gen-config-reference.py`, not the files. The other files in `docs/config/` are written by hand from the upstream Go sources; cite the source file.
- The dashboards in `static_files/observability/grafana/dashboards/` are generated. Change `scripts/gen-dashboards.py`, not the files. Give every panel a description that says what the panel shows and how to read it. Use only a metric that you saw on a live devnet.
- Keep `README.md` short: what the package does, how to run it, how to configure it. Put detail in `docs/`.
- State only what you verified against the code, the pinned upstream commit, or a live run.

## Verification before you finish

1. `kurtosis lint .` reports nothing.
2. `python3 -m unittest discover -s tests` passes with PyYAML installed.
3. `bash scripts/check-package.sh` plans every arguments file.
4. `bash scripts/build.sh` passes if `tools/` changed. `bash scripts/check-alloy.sh` passes if `static_files/observability/alloy/` changed.
5. `bash scripts/run.sh examples/poa.yml` passes if `src/` or `tools/` changed. Also run `examples/pos.yml` if the change touches staking, the bridge, node config, or the observability stack; then `bash scripts/check-observability.sh <enclave>` passes. Both examples run the explorers; then `bash scripts/check-devnet.sh <enclave>` passes.
6. Remove the enclaves that you started.

## Decisions and commits

- Read `docs/adr/` before you change the architecture. An accepted ADR is a constraint.
- Write a new ADR when a change adds a service, an argument group, a trust boundary, or a dependency, or when it reverses an earlier decision. Copy `docs/adr/template.md`. Never edit the decision of an accepted ADR; add a new ADR that supersedes it.
- Use Conventional Commits: `feat`, `fix`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, with an optional scope such as `feat(l1):`. One logical change per commit, with its tests and documentation.
- Do not commit `.build/`, `artifacts/`, or a downloaded `deployment-state`. The state holds every node key.

## Out of scope

- A connection to Fuji or Mainnet. The package is a closed local network.
- Production key handling or remote BLS signing.
