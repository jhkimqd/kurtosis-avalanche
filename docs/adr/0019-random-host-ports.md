# 0019. Publish every port on a random host port, and print the addresses with a script

Status: Accepted

## Context

ADR 0015 published the first node of each chain on fixed host ports (`rpc_port`, 29650 and up), and ADR 0014 published the web app and the API of each explorer on fixed host ports (`explorer_port`, 28000 and up). Fixed ports have costs:

- A second devnet on the same machine fails to start until the user moves both ranges, and any other program on those ports breaks the deployment.
- The package wrote host addresses into the deployment manifest and into `/opt/networks` of the tools service. Those addresses are guesses made inside the enclave: the Starlark plan and the tools service cannot see which host ports Kurtosis actually published.
- `sanity_check.star` had to validate two port ranges and their overlap.

Kurtosis publishes every port on a random host port unless a service names one. `kurtosis port print <enclave> <service> <port-id>` prints the published address, but not the chain path (`/ext/bc/C/rpc`) or an L1's blockchain ID, which are in the deployment manifest.

The Blockscout web app (frontend v2.3.5) needs the address of its API before it starts. It hands the address to the browser in `/assets/envs.js`, which its entrypoint writes from the `NEXT_PUBLIC_API_*` variables. The browser then calls the API and opens a WebSocket at `/socket` directly. Its environment validator rejects a relative font URL.

## Decision

- Remove the arguments `rpc_port` and `explorer_port`. No service names a host port; Kurtosis picks each one.
- The manifest and `/opt/networks` hold only the addresses inside the enclave. The manifest names the service and port ID of each explorer instead of a URL.
- `helpers/endpoints.sh <enclave>` joins the manifest with `kurtosis port print` and prints the host addresses: the RPC and WebSocket URL of each chain, each explorer, and Grafana; `--json` prints them as one object. `helpers/check-devnet.sh` reads its host addresses from that script.
- Each explorer gets a third service, `<chain>-explorer`: nginx (pinned in `IMAGES["nginx"]`) that sends `/api` and `/socket` to `<chain>-explorer-api` and every other path to the web app, now `<chain>-explorer-web`. The browser opens one address.
- The web app starts with the addresses inside the enclave, which its server uses. Its command adds four lines to `/assets/envs.js` that replace the host and port of the app and of the API with `window.location`, so the browser calls the API through the proxy at the address of the page.
- The web app's fonts are an empty `data:` stylesheet, so it loads nothing from Google Fonts and needs no address of its own.

This supersedes ADR 0015, and the fixed host ports of ADR 0014 (`explorer_port`), which ADR 0017 also names.

## Consequences

- Any number of devnets run side by side, each in its own enclave, with no argument to change.
- An address changes with every deployment, and can change when its service restarts. A wallet or a script reads it again from `helpers/endpoints.sh`.
- Each explorer runs one more container, limited to `EXPLORER_PROXY_MAX_MEMORY` (64 MB).
- A user who opens `<chain>-explorer-web` directly sees pages without data, because the web app looks for the API at the address of the page. The documentation and `helpers/endpoints.sh` name only the proxy.
- `/assets/envs.js` keeps its upstream format. A Blockscout frontend that stops reading `window.__envs` breaks the explorers; `helpers/check-devnet.sh` checks the file and the WebSocket through the proxy.

## Alternatives

- Keep the fixed ports and make them optional: the code, the validation, and two sets of documentation stay for one convenience, and the default still collides with a second devnet.
- The Next.js API proxy of the frontend (`NEXT_PUBLIC_USE_NEXT_JS_PROXY`): it proxies HTTP calls but not the WebSocket of the live updates.
- Let the tools service or a post-run script reconfigure the web app with the published port: the plan cannot read a published port, and a step outside `kurtosis run` makes the deployment depend on a wrapper.
