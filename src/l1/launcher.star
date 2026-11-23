"""One Avalanche L1: a Subnet-EVM blockchain with its own validators.

The steps follow the L1 lifecycle of ACP-77:

  1. Create a subnet and its blockchain on the P-Chain.
  2. Start nodes that track the subnet.
  3. Convert the subnet to an L1. This names the first validators and the
     ValidatorManager contract that controls the validator set from then on.
  4. Deploy and initialize the ValidatorManager on the L1.
  5. Optional: deploy the token bridge.
  6. PoS only: move the validator set from the first validators to staked ones.
  7. Verify the L1 with test transactions.
"""

constants = import_module("../config/constants.star")
bridge = import_module("./bridge.star")
node_launcher = import_module("../node/launcher.star")
signature_aggregator = import_module("./signature_aggregator.star")
tools = import_module("../tools/launcher.star")


def launch(plan, args, network, primary, l1_index, first_node_index):
    """Deploys one L1 and returns its context.

    Args:
        args: parsed package arguments.
        network: struct from `tools.generate_network`.
        primary: context of the Primary Network (src/primary_network/launcher.star).
        l1_index: number of this L1, starting at 0.
        first_node_index: first generated node identity reserved for this L1.
    Returns:
        struct(manifest): a dict of the L1's IDs, contract addresses, and the
        RPC and WebSocket URLs of its RPC nodes. With a fixed `rpc_port`,
        `host` holds the URLs of the first RPC node on this machine.
    """
    l1_args = args["l1"]
    name = generate_name(l1_index)
    evm_chain_id = l1_args["chain_id"] + l1_index
    mode = l1_args["validator_management"]
    is_pos = mode != constants.VALIDATOR_MANAGEMENT.poa
    # `lab` keeps the journals and results of this L1 in its own directory.
    state_path = "{}/{}".format(tools.STATE_PATH, name)

    # Node identities of this L1, in the order of `node_count`.
    validator_count = l1_args["validator_count"]
    rpc_count = l1_args["rpc_count"]
    validator_indexes = [first_node_index + i for i in range(validator_count)]
    rpc_indexes = [validator_indexes[-1] + 1 + i for i in range(rpc_count)]
    bootstrap_indexes = [
        rpc_indexes[-1] + 1 + i
        for i in range(bootstrap_validator_count(validator_count) if is_pos else 0)
    ]

    # 1. Create the subnet and the blockchain. The blockchain ID is the hash
    #    of the transaction, so it is known only now.
    tools.run(
        plan,
        "Creating the subnet and blockchain of {} on the P-Chain".format(name),
        [
            "lab",
            "create",
            primary.rpc_url,
            state_path,
            tools.STATIC_FILES_PATH + "/l1-genesis.json",
            str(evm_chain_id),
            json.encode(l1_args["genesis"]),
            json.encode(args["bridge"]),
            json.encode(l1_args["chain_config"]),
            json.encode(l1_args["subnet_config"]),
        ],
    )
    ids = tools.read_json(
        plan,
        state_path + "/chain.json",
        {"subnet_id": ".subnet_id", "blockchain_id": ".blockchain_id"},
    )
    l1 = struct(
        subnet_id=ids["subnet_id"],
        blockchain_id=ids["blockchain_id"],
        # AvalancheGo finds the chain config and the subnet config by ID. Only
        # `lab create` knows the IDs, so it wrote the files with their names.
        config_artifact=plan.store_service_files(
            name=name + "-config",
            service_name=tools.SERVICE_NAME,
            src=state_path + "/config",
        ),
    )

    # 2. Start the first validators and the RPC nodes. A PoA L1 starts with its
    #    permanent validators. A PoS L1 starts with temporary bootstrap
    #    validators, because a validator named at conversion holds no stake.
    def launch_node(role, number, index):
        # The first RPC node serves the L1 on a fixed port of this machine.
        is_first_rpc = role == constants.NODE_ROLE.rpc and number == 0
        return node_launcher.launch(
            plan,
            args,
            network,
            name=node_name(name, role, number),
            role=role,
            index=index,
            bootstrap_peer=primary.bootstrap_peer,
            l1=l1,
            host_port=(
                node_launcher.host_rpc_port(args, l1_index + 1)
                if is_first_rpc
                else None
            ),
        )

    if is_pos:
        initial_role = constants.NODE_ROLE.bootstrap
        initial_indexes = bootstrap_indexes
        initial_weight = bootstrap_validator_weight(validator_count)
    else:
        initial_role = constants.NODE_ROLE.validator
        initial_indexes = validator_indexes
        initial_weight = constants.POA_VALIDATOR_WEIGHT
    initial_nodes = [
        launch_node(initial_role, number, index)
        for number, index in enumerate(initial_indexes)
    ]
    rpc_nodes = [
        launch_node(constants.NODE_ROLE.rpc, number, index)
        for number, index in enumerate(rpc_indexes)
    ]
    rpc_urls = [
        "{}/ext/bc/{}/rpc".format(node.rpc_url, l1.blockchain_id) for node in rpc_nodes
    ]
    ws_urls = [
        "{}/ext/bc/{}/ws".format(node.ws_url, l1.blockchain_id) for node in rpc_nodes
    ]
    rpc_url = rpc_urls[0]

    # 3. Convert the subnet to an L1. The chain produces blocks from here on.
    tools.run(
        plan,
        "Converting {} to an L1 with {} validators".format(name, len(initial_indexes)),
        [
            "lab",
            "convert",
            primary.rpc_url,
            state_path,
            "self",  # The ValidatorManager lives on the L1 itself.
            constants.VALIDATOR_MANAGER_ADDRESS,
            tools.NETWORK_PATH,
            str(initial_weight),
        ]
        + [str(index) for index in initial_indexes],
    )
    _wait_for_rpc(plan, name, rpc_url, evm_chain_id)

    # 4. Deploy the ValidatorManager and load the first validator set into it.
    #    The first validators of the L1 sign a Warp message from the P-Chain
    #    that proves the conversion.
    aggregator_url = signature_aggregator.launch(
        plan, args, name, l1.subnet_id, primary.rpc_url
    )
    tools.run(
        plan,
        "Deploying the ValidatorManager of {}".format(name),
        ["lab", "manager", primary.rpc_url, rpc_url, state_path, aggregator_url],
    )
    manifest = {
        "name": name,
        "subnet_id": l1.subnet_id,
        "blockchain_id": l1.blockchain_id,
        "evm_chain_id": evm_chain_id,
        "rpc_urls": rpc_urls,
        "ws_urls": ws_urls,
        "validator_management": mode,
        "validator_manager_address": constants.VALIDATOR_MANAGER_ADDRESS,
    }
    if rpc_nodes[0].host_rpc_url:
        manifest["host"] = {
            "rpc_url": "{}/ext/bc/{}/rpc".format(
                rpc_nodes[0].host_rpc_url, l1.blockchain_id
            ),
            "ws_url": "{}/ext/bc/{}/ws".format(
                rpc_nodes[0].host_ws_url, l1.blockchain_id
            ),
        }

    # 5. Deploy the token bridge between the C-Chain and the L1.
    if args["bridge"]:
        manifest["bridge"] = bridge.launch(
            plan, args, name, state_path, primary.rpc_url, rpc_url
        )

    # 6. Move a PoS L1 to staked validators.
    validator_nodes = initial_nodes
    if is_pos:
        validator_nodes = []
        for number, index in enumerate(validator_indexes):
            node = launch_node(constants.NODE_ROLE.validator, number, index)
            validator_nodes.append(node)
            # The first call also deploys the staking manager and hands it the
            # ownership of the ValidatorManager. Each call stakes one validator.
            tools.run(
                plan,
                "Staking {} as a validator".format(node.name),
                [
                    "lab",
                    "migrate",
                    primary.rpc_url,
                    rpc_url,
                    state_path,
                    aggregator_url,
                    str(index),
                    mode,
                ],
            )
        tools.run(
            plan,
            "Removing the bootstrap validators of {}".format(name),
            [
                "lab",
                "finalize-pos",
                primary.rpc_url,
                rpc_url,
                state_path,
                aggregator_url,
                mode,
            ]
            + [str(index) for index in validator_indexes],
        )
        _wait_for_uptime_trackers(plan, name)
        for node in initial_nodes:
            plan.remove_service(name=node.name)
        manifest["staking_manager_address"] = tools.read_json(
            plan, state_path + "/staking.json", {"address": ".staking"}
        )["address"]

    # 7. Verify: bridge a token, send transfers, compare the RPC nodes.
    if args["bridge"]:
        bridge.verify(plan, name, state_path, primary.rpc_url, rpc_url)
    tools.run(
        plan,
        "Sending {} test transfers on {}".format(
            constants.SMOKE_TRANSACTION_COUNT, name
        ),
        ["lab", "run", rpc_url, str(constants.SMOKE_TRANSACTION_COUNT)],
    )
    for url in rpc_urls:
        _wait_for_rpc(plan, name, url, evm_chain_id)
    tools.run(
        plan,
        "Checking that the RPC nodes of {} agree".format(name),
        ["lab", "verify-rpcs"] + rpc_urls,
    )

    return struct(manifest=manifest)


def generate_name(l1_index):
    """Returns the name of an L1, which also starts the names of its services."""
    return "l1-{}".format(l1_index)


def node_name(l1_name, role, number):
    """Returns the service name of one node of an L1."""
    return "{}-{}-{}".format(l1_name, role, number)


def planned(args, l1_index):
    """Returns the services that `launch` will start, before any exists.

    The observability stack starts first and needs their names.

    Returns:
        struct with
        name: name of the L1.
        nodes: the permanent validators and RPC nodes, each a struct(name, role).
        bootstrap_nodes: the temporary validators of a PoS L1, in the same form.
        metrics_targets: the support services that serve metrics, each a
            struct(job, address) with a job of `constants.METRICS_JOB`.
    """
    l1_args = args["l1"]
    name = generate_name(l1_index)
    validator_count = l1_args["validator_count"]

    def nodes(role, count):
        return [
            struct(name=node_name(name, role, number), role=role)
            for number in range(count)
        ]

    is_pos = l1_args["validator_management"] != constants.VALIDATOR_MANAGEMENT.poa
    metrics_targets = [
        struct(
            job=constants.METRICS_JOB.signature_aggregator,
            address=signature_aggregator.metrics_address(name),
        )
    ]
    if args["bridge"]:
        metrics_targets.append(
            struct(
                job=constants.METRICS_JOB.icm_relayer,
                address=bridge.metrics_address(name),
            )
        )
    return struct(
        name=name,
        nodes=nodes(constants.NODE_ROLE.validator, validator_count)
        + nodes(constants.NODE_ROLE.rpc, l1_args["rpc_count"]),
        bootstrap_nodes=nodes(
            constants.NODE_ROLE.bootstrap,
            bootstrap_validator_count(validator_count) if is_pos else 0,
        ),
        metrics_targets=metrics_targets,
    )


def node_count(l1_args):
    """Returns how many node identities one L1 needs, temporary nodes included."""
    count = l1_args["validator_count"] + l1_args["rpc_count"]
    if l1_args["validator_management"] != constants.VALIDATOR_MANAGEMENT.poa:
        count += bootstrap_validator_count(l1_args["validator_count"])
    return count


# ── PoS bootstrap validators ─────────────────────────────────────────────────
#
# The validators named at conversion hold no stake, so a PoS L1 replaces them:
# each permanent validator stakes and joins, then each bootstrap validator
# leaves. The ValidatorManager limits every such change to 20% of the total
# weight (the churn limit, set in tools/manager.go). The two functions below
# pick the smallest bootstrap set that keeps every step within that limit. For
# N permanent validators of weight S, K bootstrap validators of weight W must
# satisfy:
#
#   first join:   S <= 20% of K * W          so  K * W >= 5 * S
#   last removal: W <= 20% of (N * S + W)    so  W <= N * S / 4
#
# W = N * S / 4 and K = ceil(20 / N) satisfy both: 20 nodes for one validator,
# 4 nodes for five validators, 1 node for twenty or more.


def bootstrap_validator_count(validator_count):
    """Returns the number of temporary bootstrap validators of a PoS L1."""
    return (20 + validator_count - 1) // validator_count


def bootstrap_validator_weight(validator_count):
    """Returns the P-Chain weight of each bootstrap validator of a PoS L1."""
    return validator_count * constants.POS_VALIDATOR_WEIGHT // 4


def _wait_for_uptime_trackers(plan, l1_name):
    """Waits until each node has dropped the removed bootstrap validators.

    Subnet-EVM tracks the uptime of each validator. It reads the validator set
    from the P-Chain once per minute; no API shows when it has done so.
    AvalancheGo v1.15.0 has a defect: if a validator disconnects after the
    P-Chain removed it, but before the node read that change, the node can no
    longer save its uptime data, and it logs "failed to sync uptime tracker"
    every minute. The bootstrap nodes therefore keep running for one more
    period. Upstream fixed the defect after v1.15.3
    (ava-labs/avalanchego#6310); remove this wait when the pinned release
    contains the fix.
    """
    tools.run(
        plan,
        "Waiting {} seconds until the nodes of {} have dropped the removed validators".format(
            constants.UPTIME_TRACKER_SYNC_SECONDS, l1_name
        ),
        ["sleep", str(constants.UPTIME_TRACKER_SYNC_SECONDS)],
    )


def _wait_for_rpc(plan, l1_name, rpc_url, evm_chain_id):
    tools.run(
        plan,
        "Waiting for {} to serve chain ID {} of {}".format(
            rpc_url, evm_chain_id, l1_name
        ),
        ["lab", "wait", rpc_url, str(evm_chain_id)],
    )
