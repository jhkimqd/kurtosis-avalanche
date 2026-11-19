"""Plan construction: which services and commands each launcher produces."""

import json
import re
import unittest

import starlark

constants = starlark.load("src/config/constants.star")
input_parser = starlark.load("src/config/input_parser.star")
l1_launcher = starlark.load("src/l1/launcher.star")
node_launcher = starlark.load("src/node/launcher.star")
primary_network_launcher = starlark.load("src/primary_network/launcher.star")
main = starlark.load("main.star")

NETWORK = starlark.SimpleNamespace(artifact="network", bootstrap_node_id="NodeID-0")
BOOTSTRAP = starlark.SimpleNamespace(node_id="NodeID-0", ip_address="10.0.0.1")
L1 = starlark.SimpleNamespace(
    subnet_id="subnet", blockchain_id="chain", config_artifact="l1-0-config"
)
# The services of the observability stack, in the order in which they start.
STACK = ["prometheus", "loki", "alloy", "grafana"]


class NodeTest(unittest.TestCase):
    def launch(self, args, **kwargs):
        plan = starlark.FakePlan()
        node = node_launcher.launch(plan, input_parser.parse(args), NETWORK, **kwargs)
        return plan, node, plan.services()[node.name], plan.rendered(node.name + "-config")

    def test_first_primary_validator(self):
        args = {
            "node_config": {"log-level": "debug"},
            "primary_network": {
                "p_chain_config": {"checksums-enabled": True},
                "c_chain_config": {"apis": ["chain"]},
            },
        }
        plan, node, service, files = self.launch(args, name="primary-0", role="primary", index=0)
        flags = files["node.json"]
        self.assertEqual(
            set(files),
            {"node.json", "chains/P/config.json", "chains/X/config.json", "chains/C/config.json"},
        )
        self.assertEqual(files["chains/P/config.json"], {"checksums-enabled": True})
        self.assertEqual(files["chains/X/config.json"], {})
        self.assertEqual(files["chains/C/config.json"], {"apis": ["chain"]})
        self.assertEqual(flags["log-level"], "debug")
        self.assertEqual(flags["network-id"], str(constants.NETWORK_ID))
        self.assertEqual(flags["staking-tls-key-file"], "/network/nodes/0/staker.key")
        self.assertEqual((flags["bootstrap-ids"], flags["bootstrap-ips"]), ("", ""))
        for flag in ("track-subnets", "partial-sync-primary-network", "plugin-dir", "subnet-config-dir"):
            self.assertNotIn(flag, flags)
        self.assertEqual(service.image, constants.IMAGES["avalanchego"])
        self.assertEqual(service.files["/network"], "network")
        self.assertEqual(service.max_memory, constants.NODE_MAX_MEMORY)
        self.assertEqual(node.rpc_url, "http://primary-0:9650")
        # The node writes its log files to the volume that Alloy reads.
        self.assertEqual(flags["log-dir"], "/logs/primary-0")
        self.assertEqual(flags["log-dir"], node_launcher.log_dir("primary-0"))
        self.assertEqual(service.files["/logs"].persistent_key, constants.NODE_LOGS_VOLUME_KEY)

    def test_without_log_collection_the_logs_stay_with_the_node(self):
        plan, node, service, files = self.launch({"logs": False}, name="primary-0", role="primary", index=0)
        # The default of AvalancheGo: <data-dir>/logs.
        self.assertEqual(files["node.json"]["log-dir"], "/data/logs")
        self.assertNotIn("/logs", service.files)

    def test_l1_node(self):
        args = {
            "primary_network": {"node_config": {"log-level": "warn"}},
            "l1": {
                "node_config": {"log-level": "error"},
            },
        }
        plan, node, service, files = self.launch(
            args, name="l1-0-rpc-0", role="rpc", index=7, bootstrap_peer=BOOTSTRAP, l1=L1
        )
        flags = files["node.json"]
        # The chain and subnet config come from the L1's artifact (see the
        # deployment test): a rendered file name cannot hold a runtime ID.
        self.assertEqual(set(files), {"node.json"})
        self.assertEqual(service.files["/l1"], "l1-0-config")
        self.assertEqual(flags["chain-config-dir"], "/l1/chains")
        self.assertEqual(flags["subnet-config-dir"], "/l1/subnets")
        self.assertEqual(flags["log-level"], "error")
        self.assertEqual(flags["staking-signer-key-file"], "/network/nodes/7/signer.key")
        self.assertEqual(flags["bootstrap-ids"], "NodeID-0")
        self.assertEqual(flags["bootstrap-ips"], "10.0.0.1:9651")
        self.assertEqual(flags["track-subnets"], "subnet")
        self.assertTrue(flags["partial-sync-primary-network"])
        self.assertEqual(service.image, constants.IMAGES["subnet_evm"])
        self.assertEqual(service.files["/data"].persistent_key, "l1-0-rpc-0-data")

    def test_managed_flags_win_and_are_all_rejected_as_overrides(self):
        sanity_check = starlark.load("src/config/sanity_check.star")
        for role, name in (("bootstrap", "l1-0-bootstrap-0"), ("validator", "l1-0-validator-0"), ("primary", "primary-1")):
            with self.subTest(role=role):
                plan, node, service, files = self.launch(
                    {}, name=name, role=role, index=3, bootstrap_peer=BOOTSTRAP, l1=None if role == "primary" else L1
                )
                package_flags = set(files["node.json"]) - set(input_parser.DEFAULT_NODE_CONFIG)
                self.assertLessEqual(package_flags, set(sanity_check.MANAGED_NODE_FLAGS))
        plan, node, service, files = self.launch(
            {}, name="l1-0-bootstrap-0", role="bootstrap", index=3, bootstrap_peer=BOOTSTRAP, l1=L1
        )
        self.assertEqual(service.max_memory, constants.BOOTSTRAP_NODE_MAX_MEMORY)
        # A temporary node leaves no data volume behind. Its log files stay in
        # the shared volume, so that its part of the setup can be read later.
        self.assertNotIn("/data", service.files)
        self.assertEqual(service.files["/logs"].persistent_key, constants.NODE_LOGS_VOLUME_KEY)


class BootstrapSizingTest(unittest.TestCase):
    def test_every_validator_set_change_stays_within_the_churn_limit(self):
        stake_weight = constants.POS_VALIDATOR_WEIGHT
        for validators in range(1, 101):
            count = l1_launcher.bootstrap_validator_count(validators)
            weight = l1_launcher.bootstrap_validator_weight(validators)
            total = count * weight
            with self.subTest(validators=validators, bootstrap=count, weight=weight):
                self.assertGreaterEqual(count, 1)
                self.assertEqual(weight * 4, validators * stake_weight)
                for _ in range(validators):  # Each permanent validator joins.
                    self.assertLessEqual(stake_weight * 100, total * 20)
                    total += stake_weight
                for _ in range(count):  # Each bootstrap validator leaves.
                    self.assertLessEqual(weight * 100, total * 20)
                    total -= weight
                self.assertEqual(total, validators * stake_weight)
                if count > 1:  # One bootstrap validator fewer would not do.
                    self.assertGreater(stake_weight * 100, (count - 1) * weight * 20)
        self.assertEqual(
            [l1_launcher.bootstrap_validator_count(n) for n in (1, 2, 4, 5, 19, 20, 100)],
            [20, 10, 5, 4, 2, 1, 1],
        )

    def test_node_count(self):
        node_count = lambda **l1: l1_launcher.node_count(input_parser.parse({"l1": l1})["l1"])
        self.assertEqual(node_count(validator_management="poa", validator_count=15, rpc_count=3), 18)
        self.assertEqual(node_count(validator_management="native-pos", validator_count=1), 22)
        self.assertEqual(node_count(validator_management="erc20-pos", validator_count=5), 10)


class DeploymentTest(unittest.TestCase):
    def run_package(self, args):
        plan = starlark.FakePlan()
        manifest = main.run(plan, args)
        commands = [command for command in plan.commands() if command[0] == "lab"]
        return plan, manifest, commands

    def by_name(self, commands, name):
        return [command for command in commands if command[1] == name]

    def test_poa(self):
        args = {
            "primary_network": {"validator_count": 2},
            "l1": {
                "validator_management": "poa",
                "validator_count": 2,
                "rpc_count": 2,
                "chain_config": {"pruning-enabled": False},
                "subnet_config": {"proposerNumHistoricalBlocks": 100},
            },
            "bridge": False,
            "metrics": False,
            "logs": False,
            "dashboards": False,
        }
        plan, manifest, commands = self.run_package(args)
        self.assertEqual(
            list(plan.services()),
            ["tools", "primary-0", "primary-1", "l1-0-validator-0", "l1-0-validator-1",
             "l1-0-rpc-0", "l1-0-rpc-1", "l1-0-aggregator"],
        )
        self.assertEqual(self.by_name(commands, "prepare")[0][3:], ["6", "2"])
        # `lab create` receives the chain config and the subnet config as JSON.
        self.assertEqual(
            [json.loads(argument) if argument[0] == "{" else argument for argument in self.by_name(commands, "create")[0][6:]],
            [{}, "false", {"warp-api-enabled": True, "pruning-enabled": False}, {"proposerNumHistoricalBlocks": 100}],
        )
        self.assertEqual(plan.services()["l1-0-rpc-1"].files["/l1"], "l1-0-config")
        for name, kwargs in plan.calls:
            if name == "render_templates":
                for path in kwargs["config"]:
                    self.assertNotIn("<", path, "runtime value in a rendered file name")
        convert = self.by_name(commands, "convert")[0]
        self.assertEqual(convert[4:], ["self", constants.VALIDATOR_MANAGER_ADDRESS, "/state/network", "1000000", "2", "3"])
        self.assertEqual(
            [command[1] for command in commands],
            ["prepare", "create", "convert", "wait", "manager", "run", "wait", "wait", "verify-rpcs"],
        )
        l1 = manifest["l1s"][0]
        self.assertEqual(l1["rpc_urls"][1], "http://l1-0-rpc-1:9650/ext/bc/<blockchain_id>/rpc")
        self.assertNotIn("bridge", l1)
        self.assertNotIn("staking_manager_address", l1)
        self.assertEqual(manifest["primary_network"]["c_chain_rpc_url"], "http://primary-0:9650/ext/bc/C/rpc")
        self.assertEqual(manifest["observability"], {})
        self.assertFalse([name for name, _ in plan.calls if name == "remove_service"])

    def test_pos_defaults(self):
        plan, manifest, commands = self.run_package({})
        services = list(plan.services())
        bootstrap = ["l1-0-bootstrap-{}".format(i) for i in range(4)]
        validators = ["l1-0-validator-{}".format(i) for i in range(5)]
        self.assertEqual(
            services,
            ["tools"] + STACK + ["primary-0", "primary-1", "primary-2"] + bootstrap
            + ["l1-0-rpc-0", "l1-0-aggregator", "l1-0-relayer"] + validators,
        )
        # Identities: 3 primary, then validators 3..7, RPC 8, bootstrap 9..12.
        self.assertEqual(self.by_name(commands, "prepare")[0][3:], ["13", "3"])
        self.assertEqual(self.by_name(commands, "convert")[0][7:], ["250000", "9", "10", "11", "12"])
        self.assertEqual([command[6] for command in self.by_name(commands, "migrate")], ["3", "4", "5", "6", "7"])
        self.assertEqual(self.by_name(commands, "finalize-pos")[0][6:], ["native-pos", "3", "4", "5", "6", "7"])
        self.assertEqual(
            [kwargs["name"] for name, kwargs in plan.calls if name == "remove_service"], bootstrap
        )
        # Alloy scrapes the permanent nodes only.
        targets = plan.rendered("alloy-targets")["avalanche.json"]
        self.assertEqual(
            [target["labels"]["node"] for target in targets],
            ["primary-0", "primary-1", "primary-2"] + validators + ["l1-0-rpc-0"],
        )
        self.assertEqual(
            manifest["observability"],
            {"prometheus_url": "http://prometheus:9090", "loki_url": "http://loki:3100",
             "alloy_url": "http://alloy:12345", "grafana_url": "http://grafana:3000"},
        )
        self.assertEqual(manifest["l1s"][0]["staking_manager_address"], "<address>")
        self.assertEqual(manifest["l1s"][0]["bridge"]["home"], "<home>")
        # The commands of the L1 run in the order of its lifecycle.
        self.assertEqual(
            [command[1] for command in commands],
            ["prepare", "create", "convert", "wait", "manager", "bridge-deploy", "bridge-activate"]
            + ["migrate"] * 5
            + ["finalize-pos", "bridge-smoke", "run", "wait", "verify-rpcs"],
        )
        # Each validator stakes only after its own node has started.
        order = [
            kwargs["name"] if name == "add_service" else "stake-" + kwargs["recipe"].command[6]
            for name, kwargs in plan.calls
            if name == "add_service" or (name == "exec" and kwargs["recipe"].command[1] == "migrate")
        ]
        for number, index in enumerate(range(3, 8)):
            self.assertEqual(
                order.index("l1-0-validator-{}".format(number)) + 1, order.index("stake-{}".format(index))
            )
        # The bootstrap nodes keep running for one more uptime tracker period
        # after their removal (see _wait_for_uptime_trackers).
        steps = [
            name if name == "remove_service" else " ".join(kwargs["recipe"].command[:2])
            for name, kwargs in plan.calls
            if name == "remove_service"
            or (name == "exec" and kwargs["recipe"].command[0] == "sleep")
            or (name == "exec" and kwargs["recipe"].command[1] == "finalize-pos")
        ]
        self.assertEqual(steps, ["lab finalize-pos", "sleep 65"] + ["remove_service"] * 4)
        self.assertGreater(constants.UPTIME_TRACKER_SYNC_SECONDS, 60)
        # The permanent nodes get the full resource limits, the temporary ones less.
        services = plan.services()
        self.assertEqual(services["l1-0-validator-0"].max_memory, constants.NODE_MAX_MEMORY)
        self.assertEqual(services["l1-0-validator-0"].max_cpu, constants.NODE_MAX_CPU)
        self.assertEqual(services["l1-0-bootstrap-0"].max_memory, constants.BOOTSTRAP_NODE_MAX_MEMORY)
        self.assertEqual(services["l1-0-bootstrap-0"].max_cpu, constants.BOOTSTRAP_NODE_MAX_CPU)
        # The first validator starts alone; every other node syncs from it.
        peers = {
            name: plan.rendered(name + "-config")["node.json"]
            for name in ("primary-0", "primary-1", "primary-2", "l1-0-validator-0", "l1-0-rpc-0")
        }
        self.assertEqual(peers["primary-0"]["bootstrap-ids"], "")
        self.assertEqual(peers["primary-0"]["bootstrap-ips"], "")
        for name in ("primary-1", "primary-2", "l1-0-validator-0", "l1-0-rpc-0"):
            self.assertEqual(peers[name]["bootstrap-ids"], "<id>")
            self.assertEqual(peers[name]["bootstrap-ips"], "ip-of-primary-0:9651")
        # The final test sends real transfers.
        self.assertEqual(self.by_name(commands, "run")[0][3], str(constants.SMOKE_TRANSACTION_COUNT))
        self.assertGreater(constants.SMOKE_TRANSACTION_COUNT, 0)

    def test_erc20_pos_passes_the_mode_to_the_staking_commands(self):
        args = {"l1": {"validator_management": "erc20-pos", "validator_count": 20}, "bridge": False}
        plan, manifest, commands = self.run_package(args)
        self.assertEqual({command[7] for command in self.by_name(commands, "migrate")}, {"erc20-pos"})
        self.assertEqual(self.by_name(commands, "finalize-pos")[0][6], "erc20-pos")
        self.assertEqual(manifest["l1s"][0]["validator_management"], "erc20-pos")
        self.assertNotIn("bridge-smoke", [command[1] for command in commands])

    def test_each_l1_gets_its_own_identities_and_chain_id(self):
        args = {"l1": {"count": 2, "validator_management": "poa", "validator_count": 1}, "bridge": False}
        plan, manifest, commands = self.run_package(args)
        self.assertEqual(self.by_name(commands, "prepare")[0][3:], ["7", "3"])
        self.assertEqual([command[-1] for command in self.by_name(commands, "convert")], ["3", "5"])
        self.assertEqual([command[5] for command in self.by_name(commands, "create")], ["77777", "77778"])
        self.assertEqual([l1["name"] for l1 in manifest["l1s"]], ["l1-0", "l1-1"])
        self.assertIn("l1-1-rpc-0", plan.services())


class ObservabilityTest(unittest.TestCase):
    def run_package(self, args):
        plan = starlark.FakePlan()
        main.run(plan, args)
        return plan, plan.services()

    def test_the_planned_services_are_the_started_services(self):
        # The stack starts first and names its targets before they exist.
        for args in (
            {},
            {"l1": {"validator_management": "poa"}, "bridge": False},
            {"l1": {"count": 2, "validator_management": "erc20-pos", "validator_count": 20, "rpc_count": 2}},
        ):
            with self.subTest(args=args):
                plan, services = self.run_package(args)
                parsed = input_parser.parse(args)
                planned = [node.name for node in primary_network_launcher.planned_nodes(parsed)]
                addresses = []
                for l1_index in range(parsed["l1"]["count"]):
                    l1 = l1_launcher.planned(parsed, l1_index)
                    planned += [node.name for node in l1.nodes + l1.bootstrap_nodes]
                    addresses += [target.address for target in l1.metrics_targets]
                planned += [address.split(":")[0] for address in addresses]
                self.assertEqual(sorted(planned), sorted(set(services) - {"tools"} - set(STACK)))
                # Each support service declares the port that Alloy scrapes.
                for address in addresses:
                    name, port = address.split(":")
                    self.assertEqual(services[name].ports["metrics"].number, int(port))

    def test_prometheus_stores_and_alloy_scrapes(self):
        plan, services = self.run_package({})
        # The stack starts before the network, the stores before the collector.
        self.assertEqual(list(services)[:6], ["tools"] + STACK + ["primary-0"])
        prometheus = services["prometheus"]
        self.assertIn("--web.enable-remote-write-receiver", prometheus.cmd)
        self.assertNotIn("scrape_configs", plan.rendered("prometheus-config")["prometheus.yml"])
        alloy = services["alloy"]
        self.assertEqual(alloy.image, constants.IMAGES["alloy"])
        self.assertEqual(alloy.env_vars["PROMETHEUS_REMOTE_WRITE_URL"], "http://prometheus:9090/api/v1/write")
        self.assertIn("--disable-reporting", alloy.cmd)
        self.assertEqual(alloy.env_vars["LOKI_PUSH_URL"], "http://loki:3100/loki/api/v1/push")
        self.assertEqual(alloy.files["/etc/alloy"].artifact_names, ["alloy-metrics-pipeline", "alloy-logs-pipeline"])
        self.assertEqual(alloy.files["/logs"].persistent_key, constants.NODE_LOGS_VOLUME_KEY)
        self.assertEqual((alloy.user.uid, alloy.user.gid), (0, 0))
        self.assertEqual(services["loki"].image, constants.IMAGES["loki"])
        self.assertFalse(plan.rendered("loki-config")["config.yaml"]["analytics"]["reporting_enabled"])
        # Nine nodes: the limits grow with the network.
        self.assertEqual(alloy.max_memory, constants.ALLOY_BASE_MEMORY + 9 * constants.ALLOY_NODE_MEMORY)
        self.assertEqual(prometheus.max_memory, constants.PROMETHEUS_BASE_MEMORY + 9 * constants.PROMETHEUS_NODE_MEMORY)

    def test_targets_and_labels(self):
        plan, _ = self.run_package({"l1": {"count": 2}})
        targets = plan.rendered("alloy-targets")
        # The pipeline reads one file per job; its `job_name` is the constant.
        pipeline = (starlark.ROOT / "static_files/observability/alloy/metrics.alloy").read_text()
        self.assertEqual(
            set(targets), {job + ".json" for job in vars(constants.METRICS_JOB).values()} | {"logs.json"}
        )
        self.assertEqual(
            sorted(re.findall(r'"/etc/alloy-targets/(.+)\.json"', pipeline)),
            sorted(re.findall(r'job_name += "(.+)"', pipeline)),
        )
        self.assertEqual(
            set(re.findall(r'job_name += "(.+)"', pipeline)), set(vars(constants.METRICS_JOB).values())
        )
        nodes = {target["labels"]["node"]: target for target in targets["avalanche.json"]}
        self.assertEqual(nodes["primary-0"], {"targets": ["primary-0:9650"], "labels": {"node": "primary-0", "role": "primary"}})
        self.assertEqual(nodes["l1-1-rpc-0"]["labels"], {"node": "l1-1-rpc-0", "role": "rpc", "l1": "l1-1"})
        self.assertFalse([name for name in nodes if "bootstrap" in name])
        self.assertEqual(
            targets["icm-relayer.json"],
            [{"targets": ["l1-{}-relayer:9092".format(i)], "labels": {"l1": "l1-{}".format(i)}} for i in range(2)],
        )
        self.assertEqual(
            [target["targets"] for target in targets["signature-aggregator.json"]],
            [["l1-0-aggregator:8081"], ["l1-1-aggregator:8081"]],
        )
        # Without a bridge no relayer runs; its target file is an empty list.
        plan, _ = self.run_package({"bridge": False})
        self.assertEqual(plan.rendered("alloy-targets")["icm-relayer.json"], [])

    def test_each_switch_starts_only_its_services(self):
        for args, expected in (
            ({}, STACK),
            ({"dashboards": False}, ["prometheus", "loki", "alloy"]),
            ({"logs": False}, ["prometheus", "alloy", "grafana"]),
            ({"metrics": False}, ["loki", "alloy", "grafana"]),
            ({"metrics": False, "logs": False, "dashboards": False}, []),
        ):
            with self.subTest(args=args):
                plan, services = self.run_package(args)
                stack = [name for name in services if name in STACK]
                self.assertEqual(stack, expected)
                manifest = main.run(starlark.FakePlan(), args)
                self.assertEqual(sorted(manifest["observability"]), sorted(name + "_url" for name in expected))
                if not expected:
                    continue
                # Alloy gets a pipeline, a target file, and an address only
                # for a store that runs.
                alloy = services["alloy"]
                self.assertEqual(
                    alloy.files["/etc/alloy"].artifact_names,
                    ["alloy-{}-pipeline".format(kind) for kind, store in (("metrics", "prometheus"), ("logs", "loki")) if store in expected],
                )
                self.assertEqual("PROMETHEUS_REMOTE_WRITE_URL" in alloy.env_vars, "prometheus" in expected)
                self.assertEqual("LOKI_PUSH_URL" in alloy.env_vars, "loki" in expected)
                self.assertEqual("/logs" in alloy.files, "loki" in expected)
                self.assertEqual("logs.json" in plan.rendered("alloy-targets"), "loki" in expected)
                self.assertEqual("avalanche.json" in plan.rendered("alloy-targets"), "prometheus" in expected)
                self.assertEqual("/logs" in services["primary-0"].files, "loki" in expected)
                if "grafana" not in expected:
                    continue
                # Grafana gets a datasource and a dashboard group only for a
                # store that runs, and opens on a dashboard that exists.
                grafana = services["grafana"]
                provisioning = plan.rendered("grafana-provisioning")
                datasources = provisioning["datasources/datasources.yml"]["datasources"]
                self.assertEqual(
                    [(source["uid"], source["url"]) for source in datasources],
                    [(store, manifest["observability"][store + "_url"]) for store in ("prometheus", "loki") if store in expected],
                )
                self.assertEqual([source["isDefault"] for source in datasources].count(True), 1)
                groups = [group for group, store in (("metrics", "prometheus"), ("logs", "loki")) if store in expected]
                self.assertEqual(
                    {path: artifact for path, artifact in grafana.files.items() if path != "/config"},
                    {"/dashboards/" + group: "grafana-{}-dashboards".format(group) for group in groups},
                )
                home = grafana.env_vars["GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH"]
                self.assertTrue(home.startswith("/dashboards/{}/".format(groups[0])))
                source = starlark.ROOT / "static_files/observability/grafana/dashboards"
                self.assertTrue((source / home.removeprefix("/dashboards/")).is_file())

    def test_grafana_is_open_to_look_at_and_stays_offline(self):
        plan, services = self.run_package({})
        grafana = services["grafana"]
        self.assertEqual(grafana.image, constants.IMAGES["grafana"])
        self.assertEqual(grafana.env_vars["GF_AUTH_ANONYMOUS_ENABLED"], "true")
        # Grafana 13 supports no other role for a visitor without a login.
        self.assertEqual(grafana.env_vars["GF_AUTH_ANONYMOUS_ORG_ROLE"], "Viewer")
        for setting in ("GF_ANALYTICS_REPORTING_ENABLED", "GF_ANALYTICS_CHECK_FOR_UPDATES",
                        "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES", "GF_NEWS_NEWS_FEED_ENABLED"):
            self.assertEqual(grafana.env_vars[setting], "false")
        provider = plan.rendered("grafana-provisioning")["dashboards/dashboards.yml"]["providers"][0]
        self.assertEqual(provider["options"]["path"], "/dashboards")
        self.assertFalse(provider["allowUiUpdates"])
        # Every uploaded directory exists and holds dashboards.
        uploads = [kwargs for name, kwargs in plan.calls if name == "upload_files" and kwargs["name"].startswith("grafana-")]
        self.assertEqual(len(uploads), 2)
        for upload in uploads:
            directory = (starlark.ROOT / "src/observability" / upload["src"]).resolve()
            self.assertTrue(list(directory.glob("*.json")), upload["src"])

    def test_log_targets_name_the_log_files_of_every_node(self):
        plan, services = self.run_package({})
        targets = plan.rendered("alloy-targets")["logs.json"]
        bootstrap = ["l1-0-bootstrap-{}".format(i) for i in range(4)]
        # Every node that ever runs, the temporary ones included.
        self.assertEqual(
            sorted(target["labels"]["node"] for target in targets),
            sorted(set(services) - {"tools", "l1-0-aggregator", "l1-0-relayer"} - set(STACK)),
        )
        metrics = {target["labels"]["node"]: target["labels"] for target in plan.rendered("alloy-targets")["avalanche.json"]}
        for target in targets:
            labels = dict(target["labels"])
            node = labels["node"]
            with self.subTest(node=node):
                # Without an address a file_sd entry yields no target at all.
                self.assertEqual(target["targets"], ["localhost"])
                log_dir = plan.rendered(node + "-config")["node.json"]["log-dir"]
                self.assertEqual(labels.pop("__path__"), log_dir + "/*.log")
                self.assertTrue(labels.pop("__path_exclude__").startswith(log_dir + "/*-"))
                self.assertEqual(labels.pop("job"), constants.METRICS_JOB.node)
                # Logs and metrics of a node carry the same labels.
                if node in bootstrap:
                    self.assertEqual(labels, {"node": node, "role": "bootstrap", "l1": "l1-0"})
                else:
                    self.assertEqual(labels, metrics[node])

    def test_the_log_pipeline_skips_rotated_files_only(self):
        import fnmatch
        plan, _ = self.run_package({})
        labels = plan.rendered("alloy-targets")["logs.json"][0]["labels"]
        directory = "/logs/primary-0/"
        blockchain_id = "2LFmzhHDKxkreihEtPanVmofuFn63bsh8twnRXEbDhBtCJxURB"
        for name, read in (
            ("main.log", True), ("P.log", True), ("vm-factory.log", True), (blockchain_id + ".log", True),
            ("main-2026-11-19T10-00-00.000.log", False), (blockchain_id + "-2026-11-19T10-00-00.000.log", False),
        ):
            with self.subTest(file=name):
                self.assertTrue(fnmatch.fnmatchcase(directory + name, labels["__path__"]))
                self.assertEqual(not fnmatch.fnmatchcase(directory + name, labels["__path_exclude__"]), read)

    def test_the_scrape_timeout_is_below_the_interval(self):
        # Alloy does not start otherwise, and `alloy validate` does not see it.
        pipeline = (starlark.ROOT / "static_files/observability/alloy/metrics.alloy").read_text()
        scrapes = pipeline.count("prometheus.scrape ")
        self.assertEqual(scrapes, 3)
        self.assertEqual(re.findall(r'scrape_interval += "(.+)"', pipeline), ["5s"] * scrapes)
        self.assertEqual(re.findall(r'scrape_timeout += "(.+)"', pipeline), ["4s"] * scrapes)


if __name__ == "__main__":
    unittest.main()
