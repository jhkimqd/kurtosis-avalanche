"""AvalancheGo services and generated configuration."""


def launch(
    plan, cfg, fixture, index, name, bootstrap, subnet="", chain="C", role="primary"
):
    flags = {"partial-sync-primary-network": role != "primary"}
    flags.update(
        {
            "max-stake-duration": "87600h",
            "stake-minting-period": "87600h",
            "snow-sample-size": str(min(3, cfg["primary_count"])),
            "snow-preference-quorum-size": str(min(2, cfg["primary_count"])),
            "snow-confidence-quorum-size": str(min(2, cfg["primary_count"])),
        }
    )
    flags.update(cfg["node_config"])
    flags.update(cfg["role_config"].get(role, {}))
    flags.update(cfg["node_overrides"].get(name, {}))
    flags.update(
        {
            "genesis-file": "/fixtures/genesis.json",
            "bootstrap-ids": bootstrap[0],
            "bootstrap-ips": bootstrap[1],
            "track-subnets": subnet,
            "chain-config-dir": "/chains",
        }
    )
    if role == "primary":
        flags["plugin-dir"] = "/plugins"
    else:
        flags["plugin-dir"] = "/avalanchego/build/plugins"
    c_config = dict(cfg["c_chain_config"])
    c_config["warp-api-enabled"] = True
    templates = {
        "C/config.json": struct(
            template="{{.content}}", data={"content": json.encode(c_config)}
        ),
    }
    if chain != "C":
        chain_config = dict(cfg["l1_chain_config"])
        chain_config["warp-api-enabled"] = True
        templates["{}/config.json".format(chain)] = struct(
            template="{{.content}}", data={"content": json.encode(chain_config)}
        )
    config = plan.render_templates(name=name + "-config", config=templates)
    plan.exec(
        service_name="tools",
        recipe=ExecRecipe(
            command=[
                "lab",
                "configure",
                "/state/network/node-{}.json".format(index),
                json.encode(flags),
                "/state/config/{}/node.json".format(name),
            ]
        ),
    )
    node_config = plan.store_service_files(
        name=name + "-node-config",
        service_name="tools",
        src="/state/config/{}".format(name),
    )
    files = {
        "/config": node_config,
        "/chains": config,
        "/fixtures": fixture,
        "/data": Directory(persistent_key=name + "-data"),
    }
    if role == "primary":
        files["/plugins"] = Directory(persistent_key=name + "-plugins")
    return plan.add_service(
        name=name,
        config=ServiceConfig(
            image=cfg["primary_image"] if role == "primary" else cfg["node_image"],
            entrypoint=["/avalanchego/build/avalanchego"],
            cmd=[
                "--config-file=/config/node.json",
                "--public-ip=KURTOSIS_IP_ADDR_PLACEHOLDER",
            ],
            ports={
                "rpc": PortSpec(number=9650, application_protocol="http", wait="2m"),
                "staking": PortSpec(number=9651, wait="2m"),
            },
            files=files,
            max_cpu=(
                cfg["bootstrap_cpu_millicores"]
                if "-bootstrap-" in name
                else cfg["node_cpu_millicores"]
            ),
            max_memory=(
                cfg["bootstrap_memory_mb"]
                if "-bootstrap-" in name
                else cfg["node_memory_mb"]
            ),
        ),
    )
