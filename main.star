"""Entry point of the package: `kurtosis run .` calls `run`."""

constants = import_module("./src/config/constants.star")
input_parser = import_module("./src/config/input_parser.star")
l1_launcher = import_module("./src/l1/launcher.star")
observability_launcher = import_module("./src/observability/launcher.star")
primary_network_launcher = import_module("./src/primary_network/launcher.star")
tools = import_module("./src/tools/launcher.star")


def run(plan, args={}):
    """Deploys a local Avalanche network: a Primary Network and one or more L1s.

    The Primary Network (P-, X-, and C-Chain) stands in for Avalanche Mainnet.
    Each L1 is a Subnet-EVM blockchain that the package registers on its P-Chain.

    Args:
        args: package arguments. `src/config/input_parser.star` defines every
            argument and its default; `examples/` holds ready-made files.
    Returns:
        The deployment manifest: endpoints, IDs, and contract addresses.
    """
    args = input_parser.parse(args)
    primary_validator_count = args["primary_network"]["validator_count"]
    l1_node_count = l1_launcher.node_count(args["l1"])

    # 1. Start the tools service and generate the genesis and all node keys.
    tools.launch(plan, args, primary_network_launcher.planned_rpc_url(args))
    network = tools.generate_network(
        plan,
        node_count=primary_validator_count + args["l1"]["count"] * l1_node_count,
        primary_validator_count=primary_validator_count,
    )

    # 2. Start the observability stack. It runs before the network, so that it
    #    records the whole deployment.
    observability = observability_launcher.launch(
        plan,
        args,
        primary_network_launcher.planned_nodes(args),
        [
            l1_launcher.planned(args, l1_index)
            for l1_index in range(args["l1"]["count"])
        ],
    )

    # 3. Start the Primary Network: the validators of the P-, X-, and C-Chain.
    primary = primary_network_launcher.launch(plan, args, network)

    # 4. Create each L1 and attach it to the Primary Network.
    l1_manifests = []
    for l1_index in range(args["l1"]["count"]):
        l1 = l1_launcher.launch(
            plan,
            args,
            network,
            primary,
            l1_index,
            first_node_index=primary_validator_count + l1_index * l1_node_count,
        )
        l1_manifests.append(l1.manifest)

    # 5. Publish the result: the manifest, and a snapshot of the tools state.
    manifest = {
        "primary_network": {
            "network_id": constants.NETWORK_ID,
            "rpc_url": primary.rpc_url,
            "p_chain_rpc_url": primary.p_chain_rpc_url,
            "x_chain_rpc_url": primary.x_chain_rpc_url,
            "c_chain_rpc_url": primary.c_chain_rpc_url,
            "c_chain_id": constants.C_CHAIN_ID,
        },
        "l1s": l1_manifests,
        # URL of each observability service that runs.
        "observability": {
            key: url
            for key, url in [
                ("prometheus_url", observability.prometheus_url),
                ("loki_url", observability.loki_url),
                ("alloy_url", observability.alloy_url),
                ("grafana_url", observability.grafana_url),
            ]
            if url
        },
        "args": args,
    }
    plan.render_templates(
        name="deployment-manifest",
        config={
            "deployment.json": struct(
                template="{{.content}}", data={"content": json.encode(manifest)}
            )
        },
    )
    plan.store_service_files(
        name="deployment-state", service_name=tools.SERVICE_NAME, src=tools.STATE_PATH
    )
    return manifest
