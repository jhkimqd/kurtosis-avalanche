# 0016. Describe each network in the tools service with a shell script

Status: Accepted

## Context

A user had to call `platform.getBlockchains` to learn the blockchain ID of an L1, and read the Go sources to find the development keys that the package signs with. The tools service already holds the state of every deployment, and a user can open a shell in it with `kurtosis service exec`.

The Go program `lab` signs and journals transactions (ADR 0004). A description reads the network and writes files; it signs nothing. In Go, a change to it needs a rebuild of the tools image. The pinned base image of the tools service, Debian 12, has bash but neither curl nor jq.

## Decision

At the end of a deployment, the package runs `static_files/scripts/describe-networks.sh` in the tools service. It reads the deployment manifest, the P-Chain, and the state of the Go tools, and writes one directory per network under `/opt/networks`: `primary-network/` and one per L1, named like its services (`l1-0`). Each holds only JSON files: `network.json`, `validators.json`, `genesis.json`, and `accounts.json`; the Primary Network adds `blockchains.json`, an L1 adds `subnet.json`. The package also stores the directory as the files artifact `network-description`.

The tools image installs curl and jq from the Debian snapshot that its base image names in its sources (`snapshot.debian.org`, 2026-11-04), so a rebuild installs the same versions.

## Consequences

- A user reads the IDs, URLs, and keys of a network from one directory, without an API call.
- The script runs from `/fixtures/scripts/`, mounted from `static_files/`; a user can change it and run it again without a rebuild. It is a snapshot: it does not follow later changes on the network until it runs again.
- The script knows the public development keys of the bridge as constants. A change to `devKey` in `tools/bridge.go` must change the script too. It reads the relayer key from the relayer configuration that the Go tools write.
- An image build needs `snapshot.debian.org`.

## Alternatives

- A `lab describe` command: a change needs a Go build, and the description needs none of the signing code.
- One directory for all networks: a user who works with one L1 must pick its entries out of shared files.
- A `README.md` in each directory that repeats the JSON files as tables: a second copy of the same facts, in a form that scripts cannot read.
- curl and jq from the live Debian mirror: a rebuild would install whatever version is current.
