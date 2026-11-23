"""The Primary Network: the devnet's stand-in for Avalanche Mainnet.

Its validators run the three built-in chains:

  P-Chain  staking, validator sets, and the registry of every L1
  X-Chain  creation and transfer of assets
  C-Chain  EVM smart contracts
"""

constants = import_module("../config/constants.star")
node_launcher = import_module("../node/launcher.star")


def launch(plan, args, network):
    """Starts the Primary Network validators and waits until they are healthy.

    Returns:
        struct with
        bootstrap_peer: struct(node_id, ip_address) that later nodes sync from.
        rpc_url: base URL of the first validator; the API paths below extend it.
        p_chain_rpc_url, x_chain_rpc_url, c_chain_rpc_url: chain API endpoints.
        c_chain_ws_url: WebSocket endpoint of the C-Chain, for subscriptions.
        host: dict of the same URLs on this machine, through the fixed port
            of the first validator, or None when `rpc_port` is 0.
    """
    nodes = []
    bootstrap_peer = None
    for index in range(args["primary_network"]["validator_count"]):
        node = node_launcher.launch(
            plan,
            args,
            network,
            name=generate_name(index),
            role=constants.NODE_ROLE.primary,
            index=index,
            bootstrap_peer=bootstrap_peer,
            # The first validator serves the P-, X-, and C-Chain on a fixed port.
            host_port=node_launcher.host_rpc_port(args, 0) if index == 0 else None,
        )
        nodes.append(node)
        # The first validator starts alone; every later node syncs from it.
        if index == 0:
            bootstrap_peer = struct(
                node_id=network.bootstrap_node_id, ip_address=node.ip_address
            )

    # A node reports healthy once it has bootstrapped the P-, X-, and C-Chain.
    for node in nodes:
        plan.wait(
            service_name=node.name,
            description="Waiting for {} to bootstrap the P-, X-, and C-Chain".format(
                node.name
            ),
            recipe=PostHttpRequestRecipe(
                port_id=constants.NODE_HTTP_PORT_ID,
                endpoint="/ext/health",
                content_type="application/json",
                body=json.encode(
                    {"jsonrpc": "2.0", "id": 1, "method": "health.health", "params": {}}
                ),
                extract={"healthy": ".result.healthy"},
            ),
            field="extract.healthy",
            assertion="==",
            target_value=True,
            timeout="5m",
        )

    urls = _chain_urls(nodes[0].rpc_url, nodes[0].ws_url)
    return struct(
        bootstrap_peer=bootstrap_peer,
        rpc_url=urls["rpc_url"],
        p_chain_rpc_url=urls["p_chain_rpc_url"],
        x_chain_rpc_url=urls["x_chain_rpc_url"],
        c_chain_rpc_url=urls["c_chain_rpc_url"],
        c_chain_ws_url=urls["c_chain_ws_url"],
        host=(
            _chain_urls(nodes[0].host_rpc_url, nodes[0].host_ws_url)
            if nodes[0].host_rpc_url
            else None
        ),
    )


def _chain_urls(rpc_url, ws_url):
    """Returns the API endpoints of the P-, X-, and C-Chain on one node."""
    return {
        "rpc_url": rpc_url,
        "p_chain_rpc_url": rpc_url + "/ext/bc/P",
        "x_chain_rpc_url": rpc_url + "/ext/bc/X",
        "c_chain_rpc_url": rpc_url + "/ext/bc/C/rpc",
        "c_chain_ws_url": ws_url + "/ext/bc/C/ws",
    }


def generate_name(index):
    """Returns the service name of a Primary Network validator."""
    return "primary-{}".format(index)


def planned_nodes(args):
    """Returns the validators that `launch` will start, before any exists.

    The observability stack starts first and needs their names.

    Returns:
        A list of struct(name, role).
    """
    return [
        struct(name=generate_name(index), role=constants.NODE_ROLE.primary)
        for index in range(args["primary_network"]["validator_count"])
    ]
