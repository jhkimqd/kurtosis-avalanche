# 0015. Publish the first node of each chain on a fixed host port

Status: Superseded by [0019](0019-random-host-ports.md)

## Context

Kurtosis publishes each port of a service on a random port of the host unless the service names one (`public_ports`). Every node publishes its API port, `rpc` (9650), so the C-Chain RPC of a devnet was at an address such as `http://127.0.0.1:33236/ext/bc/C/rpc`, with a new port in each enclave. A user had to run `kurtosis port print` and add the chain path before a wallet, `cast`, or a script could connect, and again after each new deployment.

Kurtosis 1.18 accepts a `url` on a `PortSpec`, but neither `kurtosis enclave inspect` nor `kurtosis port print` shows it, so it cannot carry the chain path to the user.

## Decision

Add the integer argument `rpc_port`, 29650 by default. The first Primary Network validator, `primary-0`, publishes its `rpc` port on `rpc_port`; it serves the P-, X-, and C-Chain. The first RPC node of L1 number `n`, `l1-<n>-rpc-0`, publishes it on `rpc_port + 1 + n`. Every other node keeps a random port. `rpc_port: 0` gives every node a random port, as before.

The deployment manifest adds the URLs on the host under `primary_network.host` and `l1s[n].host`. `sanity_check.star` rejects a range that leaves 1024–65535 or overlaps the explorer ports.

The default sits above the explorer ports (28000 and up) and away from 9650, the default port of AvalancheGo, so that the devnet does not collide with a local AvalancheGo node.

## Consequences

- The C-Chain RPC is `http://127.0.0.1:29650/ext/bc/C/rpc` in every deployment, and the first L1 is on port 29651. A wallet network or a script keeps working across deployments; only an L1's blockchain ID changes.
- Two devnets on one host need different `rpc_port` values, or `0`. A port that is in use fails the deployment when the node starts.
- The fixed ports reach one node per chain. A test that targets another node still reads its port with `kurtosis port print`.

## Alternatives

- Random ports only: the address changes with every deployment, and `kurtosis port print` shows no chain path.
- A reverse proxy that maps a port to each chain path: one more service and image, and the host port must still be fixed to stay the same.
- 9650 as the default: tools that default to the AvalancheGo port would work unchanged, but the devnet would fail to start next to a local AvalancheGo node.
