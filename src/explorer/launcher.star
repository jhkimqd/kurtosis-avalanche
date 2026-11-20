"""Optional block explorer: one Blockscout explorer for each EVM chain.

  explorer-db                PostgreSQL: one database per explorer
  c-chain-explorer-api       indexes the C-Chain and serves the explorer API
  c-chain-explorer           the web app of the C-Chain explorer
  l1-<i>-explorer-api        the same for each L1
  l1-<i>-explorer

The C-Chain and every L1 are EVM chains. The P-Chain and the X-Chain are not;
no explorer covers them. Use their APIs instead: docs/explorer.md.

The indexer reads blocks, receipts, and logs, and replays each transaction with
`debug_traceTransaction` to find its internal calls: calls from one contract
to another, such as those of the bridge or the staking manager.
"""

constants = import_module("../config/constants.star")

DB_SERVICE_NAME = "explorer-db"
DB_USER = "blockscout"
# The devnet has no secret to protect (ADR 0002). Kurtosis publishes the
# database port on the host, like every other port.
DB_PASSWORD = "blockscout"

# Upper bound of the database connections of one explorer: the pool of the
# indexer, the pool of the API, and one connection that listens for change
# notifications (Blockscout 9.0.2 opens no other pool with these settings).
INDEXER_POOL_SIZE = 20
API_POOL_SIZE = 10
CONNECTIONS_PER_EXPLORER = INDEXER_POOL_SIZE + API_POOL_SIZE + 1

# Path on the web app of the stylesheet that replaces Google Fonts.
FONTS_PATH = "/devnet"

# Blockscout signs session cookies with this key; it has no other use here.
# It must be at least 64 bytes long.
SECRET_KEY_BASE = (
    "kurtosis-avalanche-devnet-explorer-0000000000000000000000000000000000"
)


def launch(plan, args, primary, l1_manifests):
    """Starts the database and an explorer for the C-Chain and for each L1.

    Each explorer indexes its chain from block 0. The function returns when
    every explorer reports its indexing finished: see `_wait_until_indexed`.

    Args:
        primary: context of the Primary Network (src/primary_network/launcher.star).
        l1_manifests: the `manifest` of each L1 (src/l1/launcher.star).
    Returns:
        A list with one dict per chain: `chain` (`c-chain` or the L1 name),
        `evm_chain_id`, `url` (the web app), and `api_url`. Both URLs are
        addresses on the host that runs Kurtosis.
    """
    chains = [
        struct(
            name="c-chain",
            title="Avalanche C-Chain (devnet)",
            short_title="C-Chain",
            evm_chain_id=constants.C_CHAIN_ID,
            currency="AVAX",
            rpc_url=primary.c_chain_rpc_url,
            ws_url=primary.c_chain_ws_url,
        )
    ]
    for l1 in l1_manifests:
        chains.append(
            struct(
                name=l1["name"],
                title="Avalanche L1 {} (devnet)".format(l1["name"]),
                short_title=l1["name"],
                evm_chain_id=l1["evm_chain_id"],
                # With the bridge, the native token of an L1 is CASH that the
                # bridge minted. Without it, the token has no name.
                currency="CASH" if args["bridge"] else "TOKEN",
                # The first RPC node serves the explorer. It does not validate,
                # so the indexer does not slow block production.
                rpc_url=l1["rpc_urls"][0],
                ws_url=l1["ws_urls"][0],
            )
        )

    db_url = _launch_database(plan, args, len(chains))
    fonts = plan.render_templates(
        name="explorer-fonts",
        config={
            # Empty: the web app uses the fonts of the browser.
            "fonts.css": struct(
                template="/* No web font: the devnet is offline. */\n", data={}
            )
        },
    )
    explorers = []
    for chain_index, chain in enumerate(chains):
        web_port, api_port = host_ports(args, chain_index)
        _launch_api(plan, args, chain, db_url, api_port)
        _launch_web(plan, args, chain, web_port, api_port, fonts)
        explorers.append(
            {
                "chain": chain.name,
                "evm_chain_id": chain.evm_chain_id,
                "url": "http://localhost:{}".format(web_port),
                "api_url": "http://localhost:{}/api/v2".format(api_port),
            }
        )

    # Wait last: the explorers index in parallel.
    for chain in chains:
        _wait_until_indexed(plan, chain)
    return explorers


def host_ports(args, chain_index):
    """Returns the host ports of the web app and of the API of one explorer.

    The browser loads the web app, then calls the API and opens a WebSocket to
    it directly. Both addresses must be known before the web app starts, so
    Kurtosis publishes them on fixed host ports instead of random ones.
    Explorer number i (the C-Chain is 0, L1 number n is n + 1) takes the ports
    `explorer_port + 2 * i` and `explorer_port + 2 * i + 1`.
    """
    web_port = args["explorer_port"] + 2 * chain_index
    return web_port, web_port + 1


def api_name(chain_name):
    """Returns the service name of the indexer and API of one chain."""
    return chain_name + "-explorer-api"


def web_name(chain_name):
    """Returns the service name of the web app of one chain."""
    return chain_name + "-explorer"


def _launch_database(plan, args, chain_count):
    """Starts PostgreSQL and returns the URL prefix of its databases."""
    plan.add_service(
        name=DB_SERVICE_NAME,
        config=ServiceConfig(
            image=args["images"]["postgres"],
            ports={
                "postgresql": PortSpec(
                    number=constants.EXPLORER_DB_PORT_NUMBER,
                    application_protocol="postgresql",
                    wait="1m",
                )
            },
            env_vars={
                "POSTGRES_USER": DB_USER,
                "POSTGRES_PASSWORD": DB_PASSWORD,
            },
            cmd=[
                "postgres",
                # Each explorer opens up to CONNECTIONS_PER_EXPLORER; the rest
                # is a margin for maintenance and for `psql`.
                "-c",
                "max_connections={}".format(
                    CONNECTIONS_PER_EXPLORER * chain_count + 20
                ),
            ],
            max_memory=constants.EXPLORER_DB_BASE_MEMORY
            + constants.EXPLORER_DB_CHAIN_MEMORY * chain_count,
        ),
    )
    plan.wait(
        service_name=DB_SERVICE_NAME,
        description="Waiting for the explorer database to accept connections",
        recipe=ExecRecipe(
            command=["pg_isready", "--username", DB_USER, "--host", "127.0.0.1"]
        ),
        field="code",
        assertion="==",
        target_value=0,
        timeout="1m",
    )
    return "postgresql://{}:{}@{}:{}".format(
        DB_USER, DB_PASSWORD, DB_SERVICE_NAME, constants.EXPLORER_DB_PORT_NUMBER
    )


def _launch_api(plan, args, chain, db_url, host_port):
    """Starts the Blockscout indexer and API of one chain."""
    name = api_name(chain.name)
    plan.add_service(
        name=name,
        config=ServiceConfig(
            image=args["images"]["blockscout"],
            ports={
                "http": PortSpec(
                    number=constants.EXPLORER_API_PORT_NUMBER,
                    application_protocol="http",
                    # The first start creates the database schema.
                    wait="3m",
                )
            },
            public_ports={"http": PortSpec(number=host_port)},
            # Create the database of this chain if it does not exist, apply the
            # schema migrations, then start.
            cmd=[
                "sh",
                "-c",
                'bin/blockscout eval "Elixir.Explorer.ReleaseTasks.create_and_migrate()" && exec bin/blockscout start',
            ],
            env_vars={
                # ── Chain ───
                # Subnet-EVM and the C-Chain answer like go-ethereum.
                "ETHEREUM_JSONRPC_VARIANT": "geth",
                "ETHEREUM_JSONRPC_HTTP_URL": chain.rpc_url,
                "ETHEREUM_JSONRPC_TRACE_URL": chain.rpc_url,
                # New blocks arrive by subscription.
                "ETHEREUM_JSONRPC_WS_URL": chain.ws_url,
                "CHAIN_ID": str(chain.evm_chain_id),
                "COIN": chain.currency,
                "COIN_NAME": chain.currency,
                # Internal transactions: the built-in call tracer of the node.
                "INDEXER_INTERNAL_TRANSACTIONS_TRACER_TYPE": "call_tracer",
                # The genesis block has no transaction to trace.
                "TRACE_FIRST_BLOCK": "1",
                # Report `finished_indexing` only when no block lacks its
                # internal transactions. The upstream default tolerates 1000.
                "API_INTERNAL_TRANSACTIONS_INDEXING_FINISHED_THRESHOLD": "1",
                # ── Database ───
                "DATABASE_URL": "{}/{}".format(db_url, _database_name(chain.name)),
                "ECTO_USE_SSL": "false",
                "POOL_SIZE": str(INDEXER_POOL_SIZE),
                "POOL_SIZE_API": str(API_POOL_SIZE),
                # ── Server ───
                "PORT": str(constants.EXPLORER_API_PORT_NUMBER),
                "SECRET_KEY_BASE": SECRET_KEY_BASE,
                # ── Features that a devnet cannot use ───
                # Pending transactions: the L1 nodes serve no `txpool_*`
                # methods by default, and a devnet block follows a
                # transaction within seconds.
                "INDEXER_DISABLE_PENDING_TRANSACTIONS_FETCHER": "true",
                # Block rewards: Avalanche pays none.
                "INDEXER_DISABLE_BLOCK_REWARD_FETCHER": "true",
                # Market prices and contract verification come from the
                # internet; the devnet is offline.
                "DISABLE_MARKET": "true",
                "MICROSERVICE_SC_VERIFIER_ENABLED": "false",
                # The daily transaction chart needs the stats service, which
                # the package does not run.
                "TXS_STATS_ENABLED": "false",
                "ACCOUNT_ENABLED": "false",
                "RE_CAPTCHA_DISABLED": "true",
                "API_RATE_LIMIT_DISABLED": "true",
                # ── Freshness ───
                # Counters such as the number of addresses or of token holders
                # are cached for up to 2 hours upstream. The index of a devnet
                # is small, so recount every minute.
                "CACHE_ADDRESS_COUNT_PERIOD": "1m",
                "CACHE_ADDRESS_TRANSACTIONS_COUNTER_PERIOD": "1m",
                "CACHE_BLOCK_COUNT_PERIOD": "1m",
                "CACHE_TOKEN_HOLDERS_COUNTER_PERIOD": "1m",
                "CACHE_TOKEN_TRANSFERS_COUNTER_PERIOD": "1m",
                "CACHE_TRANSACTIONS_24H_STATS_PERIOD": "1m",
                "CACHE_TXS_COUNT_PERIOD": "1m",
                # The list of all internal transactions needs a database index
                # that a background migration builds; check for it every 10
                # seconds instead of every 10 minutes.
                "MIGRATION_HEAVY_INDEX_OPERATIONS_CHECK_INTERVAL": "10s",
                # ── CPU ───
                # The Erlang VM keeps idle scheduler threads spinning, which
                # costs a part of a core per explorer. Let them sleep.
                "ERL_FLAGS": "+sbwt none +sbwtdcpu none +sbwtdio none",
            },
            max_memory=constants.EXPLORER_API_MAX_MEMORY,
        ),
    )


def _launch_web(plan, args, chain, host_port, api_host_port, fonts):
    """Starts the Blockscout web app of one chain.

    The web app runs in the browser. It reaches the API at the published host
    port of the API service; the API allows requests from any origin.
    """
    fonts_url = "http://localhost:{}{}".format(host_port, FONTS_PATH + "/fonts.css")
    plan.add_service(
        name=web_name(chain.name),
        config=ServiceConfig(
            image=args["images"]["blockscout_frontend"],
            ports={
                "http": PortSpec(
                    number=constants.EXPLORER_WEB_PORT_NUMBER,
                    application_protocol="http",
                    wait="2m",
                )
            },
            public_ports={"http": PortSpec(number=host_port)},
            # The web app serves the files of /app/public.
            files={"/app/public" + FONTS_PATH: fonts},
            env_vars={
                "PORT": str(constants.EXPLORER_WEB_PORT_NUMBER),
                # The addresses that the browser uses: the published ports.
                "NEXT_PUBLIC_APP_PROTOCOL": "http",
                "NEXT_PUBLIC_APP_HOST": "localhost",
                "NEXT_PUBLIC_APP_PORT": str(host_port),
                "NEXT_PUBLIC_API_PROTOCOL": "http",
                "NEXT_PUBLIC_API_HOST": "localhost",
                "NEXT_PUBLIC_API_PORT": str(api_host_port),
                "NEXT_PUBLIC_API_WEBSOCKET_PROTOCOL": "ws",
                # The chain.
                "NEXT_PUBLIC_NETWORK_NAME": chain.title,
                "NEXT_PUBLIC_NETWORK_SHORT_NAME": chain.short_title,
                "NEXT_PUBLIC_NETWORK_ID": str(chain.evm_chain_id),
                "NEXT_PUBLIC_NETWORK_CURRENCY_NAME": chain.currency,
                "NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL": chain.currency,
                "NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS": "18",
                "NEXT_PUBLIC_IS_TESTNET": "true",
                # No ads, and no chart that needs the separate stats service.
                "NEXT_PUBLIC_AD_BANNER_PROVIDER": "none",
                "NEXT_PUBLIC_AD_TEXT_PROVIDER": "none",
                "NEXT_PUBLIC_HOMEPAGE_CHARTS": "[]",
                # Load the fonts from the web app, not from Google Fonts.
                "NEXT_PUBLIC_FONT_FAMILY_HEADING": json.encode(
                    {"name": "sans-serif", "url": fonts_url}
                ),
                "NEXT_PUBLIC_FONT_FAMILY_BODY": json.encode(
                    {"name": "sans-serif", "url": fonts_url}
                ),
                # Fetch no NFT image from public IPFS gateways.
                "NEXT_PUBLIC_HELIA_VERIFIED_FETCH_ENABLED": "false",
                # ── Features that show wrong data on Avalanche ───
                # The gas tracker predicts the next base fee with the Ethereum
                # rule, which Avalanche does not follow.
                "NEXT_PUBLIC_GAS_TRACKER_ENABLED": "false",
                # Every block names 0x0100…0000, the address that receives
                # the fees, as its miner, with a reward of 0.
                "NEXT_PUBLIC_VIEWS_BLOCK_HIDDEN_FIELDS": json.encode(
                    ["miner", "total_reward"]
                ),
                # The advanced filter shows reverted transactions as plain
                # transfers and gives internal calls a fee.
                "NEXT_PUBLIC_ADVANCED_FILTER_ENABLED": "false",
                # The REST API page loads its specification from GitHub. The
                # JSON-RPC and Etherscan-style API pages need nothing.
                "NEXT_PUBLIC_API_DOCS_TABS": json.encode(["eth_rpc_api", "rpc_api"]),
            },
            max_memory=constants.EXPLORER_WEB_MAX_MEMORY,
        ),
    )


def _wait_until_indexed(plan, chain):
    """Waits until the explorer of a chain has indexed blocks and internal calls.

    Blockscout reports `finished_indexing` once it holds at least 99% of the
    blocks and no block that it holds, from block 1 on, lacks its internal
    transactions (see TRACE_FIRST_BLOCK and the threshold in `_launch_api`).
    A node that cannot trace keeps the value false, and the deployment fails
    here instead of showing an explorer without them. An empty index also
    reports finished, so the first wait asks for a block.
    """
    plan.wait(
        service_name=api_name(chain.name),
        description="Waiting for the explorer of {} to index its first block".format(
            chain.short_title
        ),
        recipe=GetHttpRequestRecipe(
            port_id="http",
            endpoint="/api/v2/main-page/blocks",
            extract={"count": "length"},
        ),
        field="extract.count",
        assertion=">=",
        target_value=1,
        timeout="5m",
    )
    plan.wait(
        service_name=api_name(chain.name),
        description="Waiting for the explorer of {} to finish indexing blocks and internal transactions".format(
            chain.short_title
        ),
        recipe=GetHttpRequestRecipe(
            port_id="http",
            endpoint="/api/v2/main-page/indexing-status",
            extract={
                "done": ".finished_indexing_blocks and .finished_indexing",
            },
        ),
        field="extract.done",
        assertion="==",
        target_value=True,
        timeout="5m",
    )


def _database_name(chain_name):
    """Returns the database of one chain. PostgreSQL names take no hyphen."""
    return "blockscout_" + chain_name.replace("-", "_")
