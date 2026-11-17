commands = import_module("../tools.star")
bridge = import_module("./bridge.star")
icm = import_module("../services/icm.star")
nodes = import_module("../node/launcher.star")


def launch(plan, cfg, fixture, bootstrap, uri, targets):
    chains = []
    fleet_size = cfg["fleet_size"]
    for chain_index in range(cfg["l1_count"]):
        name = "l1-{}".format(chain_index)
        first_index = cfg["primary_count"] + chain_index * fleet_size
        state = "/state/" + name
        commands.execute(
            plan,
            [
                "lab",
                "create",
                uri,
                state,
                "/fixtures/l1-genesis.json",
                str(cfg["chain_id_start"] + chain_index),
                json.encode(cfg["l1_genesis"]),
                json.encode(cfg["bridge"]),
            ],
        )
        values = commands.execute(
            plan,
            ["cat", state + "/chain.json"],
            {"subnet": "fromjson | .subnet_id", "chain": "fromjson | .blockchain_id"},
        )
        subnet, chain = values["extract.subnet"], values["extract.chain"]
        initial_count = cfg["validator_count"] if cfg["staking"] == "poa" else 20
        initial_role = "validator" if cfg["staking"] == "poa" else "bootstrap"
        validators = []
        for i in range(initial_count):
            validators.append(
                nodes.launch(
                    plan,
                    cfg,
                    fixture,
                    first_index + i,
                    "{}-{}-{}".format(name, initial_role, i),
                    bootstrap,
                    subnet,
                    chain,
                    role="validator",
                )
            )
        if cfg["staking"] == "poa":
            for i, validator in enumerate(validators):
                targets.append(
                    {
                        "targets": ["{}:9650".format(validator.ip_address)],
                        "labels": {
                            "role": "validator",
                            "node": "{}-validator-{}".format(name, i),
                        },
                    }
                )
        rpc_urls = []
        for i in range(cfg["rpc_count"]):
            rpc_name = "{}-rpc-{}".format(name, i)
            rpc_node = nodes.launch(
                plan,
                cfg,
                fixture,
                first_index + initial_count + i,
                rpc_name,
                bootstrap,
                subnet,
                chain,
                role="rpc",
            )
            targets.append(
                {
                    "targets": ["{}:9650".format(rpc_node.ip_address)],
                    "labels": {"role": "rpc", "node": rpc_name},
                }
            )
            rpc_urls.append(
                "http://{}:9650/ext/bc/{}/rpc".format(rpc_node.ip_address, chain)
            )
        commands.execute(
            plan,
            [
                "lab",
                "convert",
                uri,
                state,
                "self",
                "0x17aB05351fC94a1a67Bf3f56DdbB941aE6c63E25",
                "/state/network",
                "1000000" if cfg["staking"] == "poa" else "50000",
            ]
            + [str(first_index + i) for i in range(initial_count)],
        )
        rpc = rpc_urls[0]
        commands.execute(
            plan, ["lab", "wait", rpc, str(cfg["chain_id_start"] + chain_index)]
        )
        aggregator = icm.launch_aggregator(plan, cfg, name, uri, subnet)
        commands.execute(
            plan,
            [
                "lab",
                "manager",
                uri,
                rpc,
                state,
                "http://{}:8080".format(aggregator.ip_address),
            ],
        )
        manager_info = commands.execute(
            plan, ["cat", state + "/manager.json"], {"address": "fromjson | .address"}
        )
        staking_address = ""
        bridge_addresses = {}
        if cfg["bridge"]:
            bridge_addresses = bridge.launch(plan, cfg, name, uri, rpc, state)
        if cfg["staking"] != "poa":
            final_indexes = []
            for i in range(cfg["validator_count"]):
                index = first_index + initial_count + cfg["rpc_count"] + i
                final_indexes.append(str(index))
                final_name = "{}-validator-{}".format(name, i)
                validator = nodes.launch(
                    plan,
                    cfg,
                    fixture,
                    index,
                    final_name,
                    bootstrap,
                    subnet,
                    chain,
                    role="validator",
                )
                targets.append(
                    {
                        "targets": ["{}:9650".format(validator.ip_address)],
                        "labels": {"role": "validator", "node": final_name},
                    }
                )
                commands.execute(
                    plan,
                    [
                        "lab",
                        "migrate",
                        uri,
                        rpc,
                        state,
                        "http://{}:8080".format(aggregator.ip_address),
                        str(index),
                        cfg["staking"],
                    ],
                )
            commands.execute(
                plan,
                [
                    "lab",
                    "finalize-pos",
                    uri,
                    rpc,
                    state,
                    "http://{}:8080".format(aggregator.ip_address),
                    cfg["staking"],
                ]
                + final_indexes,
            )
            staking_info = commands.execute(
                plan,
                ["cat", state + "/staking.json"],
                {"address": "fromjson | .staking"},
            )
            staking_address = staking_info["extract.address"]
            for i in range(initial_count):
                plan.remove_service(name="{}-bootstrap-{}".format(name, i))
        if cfg["bridge"]:
            commands.execute(plan, ["lab", "bridge-smoke", uri, rpc, state])
        commands.execute(plan, ["lab", "run", rpc, str(cfg["smoke_transactions"])])
        for endpoint in rpc_urls:
            commands.execute(
                plan,
                ["lab", "wait", endpoint, str(cfg["chain_id_start"] + chain_index)],
            )
        commands.execute(plan, ["lab", "verify-rpcs"] + rpc_urls)
        chains.append(
            {
                "bridge": bridge_addresses,
                "evm_chain_id": cfg["chain_id_start"] + chain_index,
                "validator_manager": manager_info["extract.address"],
                "staking_manager": staking_address,
                "name": name,
                "subnet_id": subnet,
                "blockchain_id": chain,
                "rpc": rpc,
                "rpcs": rpc_urls,
                "validator_management": cfg["staking"],
                "fully_pos": cfg["staking"] != "poa",
                "rpc_node_promoted": False,
            }
        )
    return chains
