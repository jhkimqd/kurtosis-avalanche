inputs = import_module("./src/config/input.star")

def execute(plan, command, extract = {}):
    return plan.exec(service_name = "lab", recipe = ExecRecipe(command = command, extract = extract))

def node(plan, cfg, fixture, index, name, bootstrap, subnet = "", chain = "C"):
    flags = json.decode(read_file("./fixtures/node-{}.json".format(index)))
    flags.update({
        "genesis-file": "/fixtures/genesis.json",
        "bootstrap-ids": bootstrap[0],
        "bootstrap-ips": bootstrap[1],
        "track-subnets": subnet,
        "max-stake-duration": "87600h",
        "stake-minting-period": "87600h",
        "snow-sample-size": "3",
        "snow-preference-quorum-size": "2",
        "snow-confidence-quorum-size": "2",
    })
    config = plan.render_templates(name = name + "-config", config = {
        "node.json": struct(template = "{{.content}}", data = {"content": json.encode(flags)}),
        "chains/{}/config.json".format(chain): struct(template = '{"warp-api-enabled":true}', data = {}),
    })
    return plan.add_service(name = name, config = ServiceConfig(
        image = cfg["image"],
        entrypoint = ["avalanchego"],
        cmd = ["--config-file=/config/node.json", "--public-ip=KURTOSIS_IP_ADDR_PLACEHOLDER"],
        ports = {"rpc": PortSpec(number = 9650, application_protocol = "http", wait = "2m"), "staking": PortSpec(number = 9651, wait = "2m")},
        files = {"/config": config, "/fixtures": fixture, "/data": Directory(persistent_key = name + "-data")},
        max_cpu = cfg["node_cpu_millicores"], max_memory = cfg["node_memory_mb"],
    ))

def run(plan, args = {}):
    cfg = inputs.parse(args)
    fixture = plan.upload_files(src = "./fixtures", name = "public-local-fixtures")
    network = json.decode(read_file("./fixtures/network.json"))
    targets = []
    primary = []
    bootstrap = ("", "")
    for i in range(3):
        service = node(plan, cfg, fixture, i, "primary-{}".format(i), bootstrap)
        primary.append(service)
        targets.append({"targets": ["{}:9650".format(service.ip_address)], "labels": {"role": "primary", "node": "primary-{}".format(i)}})
        if i == 0:
            bootstrap = (network["nodes"][0]["node_id"], "{}:9651".format(service.ip_address))
    for i in range(3):
        plan.wait(service_name = "primary-{}".format(i), recipe = PostHttpRequestRecipe(content_type = "application/json",
            port_id = "rpc", endpoint = "/ext/health", body = '{"jsonrpc":"2.0","id":1,"method":"health.health","params":{}}', extract = {"healthy": ".result.healthy"}),
            field = "extract.healthy", assertion = "==", target_value = True, timeout = "5m")
    uri = "http://{}:9650".format(primary[0].ip_address)
    plan.add_service(name = "lab", config = ServiceConfig(image = cfg["image"], entrypoint = ["sleep"], cmd = ["infinity"], env_vars = {"LAB_INSTANCE": cfg["instance_id"]}, files = {"/fixtures": fixture, "/state": Directory(persistent_key = "lab-state")}))
    chains = []
    for chain_index in range(cfg["l1_count"]):
        name = "l1-{}".format(chain_index)
        state = "/state/" + name
        execute(plan, ["lab", "create", uri, state, "/fixtures/l1-genesis.json"])
        values = execute(plan, ["cat", state + "/chain.json"], {"subnet": "fromjson | .subnet_id", "chain": "fromjson | .blockchain_id"})
        subnet, chain = values["extract.subnet"], values["extract.chain"]
        validators = []
        for i in range(cfg["validator_count"]):
            validators.append(node(plan, cfg, fixture, i + 3 + chain_index * 5, "{}-validator-{}".format(name, i), bootstrap, subnet, chain))
        for i, validator in enumerate(validators):
            targets.append({"targets": ["{}:9650".format(validator.ip_address)], "labels": {"role": "validator", "node": "{}-validator-{}".format(name, i)}})
        rpc_node = node(plan, cfg, fixture, 7 + chain_index * 5, name + "-rpc", bootstrap, subnet, chain)
        execute(plan, ["lab", "convert", uri, state, "self", "0x17aB05351fC94a1a67Bf3f56DdbB941aE6c63E25", "/fixtures"] + [str(i + 3 + chain_index * 5) for i in range(cfg["validator_count"])])
        targets.append({"targets": ["{}:9650".format(rpc_node.ip_address)], "labels": {"role": "rpc", "node": name + "-rpc"}})
        rpc = "http://{}:9650/ext/bc/{}/rpc".format(rpc_node.ip_address, chain)
        execute(plan, ["lab", "wait", rpc])
        aggregator_config = plan.render_templates(name = name + "-aggregator-config", config = {"config.json": struct(template = "{{.content}}", data = {"content": json.encode({"p-chain-api": {"base-url": uri}, "info-api": {"base-url": uri}, "tracked-subnet-ids": [subnet], "api-port": 8080, "metrics-port": 8081, "allow-private-ips": True})})})
        aggregator = plan.add_service(name = name + "-aggregator", config = ServiceConfig(image = cfg["image"], entrypoint = ["signature-aggregator"], cmd = ["--config-file=/config/config.json"], files = {"/config": aggregator_config}, ports = {"api": PortSpec(number = 8080, application_protocol = "http", wait = "2m")}))
        execute(plan, ["lab", "manager", uri, rpc, state, "http://{}:8080".format(aggregator.ip_address)])
        if cfg["staking"] != "poa":
            execute(plan, ["lab", "migrate", uri, rpc, state, "http://{}:8080".format(aggregator.ip_address), str(7 + chain_index * 5), cfg["staking"]])
        execute(plan, ["lab", "run", rpc, str(cfg["smoke_transactions"])])
        chains.append({"name": name, "subnet_id": subnet, "blockchain_id": chain, "rpc": rpc, "validator_management": cfg["staking"], "fully_pos": False, "rpc_node_promoted": cfg["staking"] != "poa"})
    if cfg["metrics"]:
        prometheus_config = plan.render_templates(name = "prometheus-config", config = {"prometheus.yml": struct(template = "{{.content}}", data = {"content": json.encode({"global": {"scrape_interval": "5s"}, "scrape_configs": [{"job_name": "avalanche", "metrics_path": "/ext/metrics", "static_configs": targets}]})})})
        plan.add_service(name = "prometheus", config = ServiceConfig(image = "prom/prometheus@sha256:6927e0919a144aa7616fd0137d4816816d42f6b816de3af269ab065250859a62", cmd = ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=30m"], files = {"/etc/prometheus": prometheus_config}, ports = {"http": PortSpec(number = 9090, application_protocol = "http")}, max_memory = 512))
    manifest = {"schema_version": 1, "network_id": 88888, "configuration": cfg, "chains": chains, "primary_rpc": uri, "versions": json.decode(read_file("./versions.json")), "support_level": "experimental-poa"}
    artifact = plan.render_templates(name = "deployment-manifest", config = {"deployment.json": struct(template = "{{.content}}", data = {"content": json.encode(manifest)})})
    evidence = plan.store_service_files(name = "experiment-state", service_name = "lab", src = "/state")
    return {"evidence": evidence, "manifest": artifact, "chains": chains, "helper": "lab"}
