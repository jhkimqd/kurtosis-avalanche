commands = import_module("./src/tools.star")
inputs = import_module("./src/config/input.star")
nodes = import_module("./src/node/launcher.star")
l1 = import_module("./src/l1/launcher.star")
metrics = import_module("./src/services/metrics.star")


def run(plan, args={}):
    cfg = inputs.parse(args)
    fixture = plan.upload_files(src="./static_files", name="public-local-fixtures")
    plan.add_service(
        name="tools",
        config=ServiceConfig(
            image=(
                cfg["tools_image"]
                if cfg["tools_image"]
                else ImageBuildSpec(
                    image_name="avalanche-tools:local", build_context_dir="./tools"
                )
            ),
            entrypoint=["sleep"],
            cmd=["infinity"],
            env_vars={"LAB_INSTANCE": cfg["instance_id"]},
            files={
                "/fixtures": fixture,
                "/state": Directory(persistent_key="lab-state"),
            },
        ),
    )
    total = cfg["primary_count"] + cfg["l1_count"] * cfg["fleet_size"]
    commands.execute(
        plan,
        ["lab", "prepare", "/state/network", str(total), str(cfg["primary_count"])],
    )
    generated = plan.store_service_files(
        name="generated-network", service_name="tools", src="/state/network"
    )
    identity = commands.execute(
        plan, ["cat", "/state/network/bootstrap.json"], {"id": "fromjson | .id"}
    )
    targets = []
    primary = []
    bootstrap = ("", "")
    for i in range(cfg["primary_count"]):
        name = "primary-{}".format(i)
        service = nodes.launch(plan, cfg, generated, i, name, bootstrap)
        primary.append(service)
        targets.append(
            {
                "targets": ["{}:9650".format(service.ip_address)],
                "labels": {"role": "primary", "node": name},
            }
        )
        if i == 0:
            bootstrap = (identity["extract.id"], "{}:9651".format(service.ip_address))
    for i in range(cfg["primary_count"]):
        plan.wait(
            service_name="primary-{}".format(i),
            recipe=PostHttpRequestRecipe(
                content_type="application/json",
                port_id="rpc",
                endpoint="/ext/health",
                body='{"jsonrpc":"2.0","id":1,"method":"health.health","params":{}}',
                extract={"healthy": ".result.healthy"},
            ),
            field="extract.healthy",
            assertion="==",
            target_value=True,
            timeout="5m",
        )
    uri = "http://{}:9650".format(primary[0].ip_address)
    chains = l1.launch(plan, cfg, generated, bootstrap, uri, targets)
    if cfg["metrics"]:
        metrics.launch(plan, targets)
    manifest = {
        "schema_version": 1,
        "network_id": 88888,
        "configuration": cfg,
        "chains": chains,
        "primary_rpc": uri,
        "images": {
            "avalanchego": cfg["primary_image"],
            "subnet_evm": cfg["node_image"],
            "aggregator": cfg["aggregator_image"],
            "relayer": cfg["relayer_image"],
            "tools": cfg["tools_image"] if cfg["tools_image"] else "built from ./tools",
        },
        "support_level": "local-devnet",
    }
    artifact = plan.render_templates(
        name="deployment-manifest",
        config={
            "deployment.json": struct(
                template="{{.content}}", data={"content": json.encode(manifest)}
            )
        },
    )
    evidence = plan.store_service_files(
        name="deployment-state", service_name="tools", src="/state"
    )
    return {
        "primary_rpc": uri,
        "c_chain_rpc": uri + "/ext/bc/C/rpc",
        "evidence": evidence,
        "manifest": artifact,
        "chains": chains,
        "tools": "tools",
    }
