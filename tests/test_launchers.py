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
        plan, node, service, files = self.launch(
            {}, name="l1-0-bootstrap-0", role="bootstrap", index=3, bootstrap_peer=BOOTSTRAP, l1=L1
        )
        package_flags = set(files["node.json"]) - set(input_parser.DEFAULT_NODE_CONFIG)
        self.assertLessEqual(package_flags, set(sanity_check.MANAGED_NODE_FLAGS))
        self.assertEqual(service.max_memory, constants.BOOTSTRAP_NODE_MAX_MEMORY)
        # A temporary node leaves no volume behind.
        self.assertNotIn("/data", service.files)


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
            ["tools", "prometheus", "alloy", "primary-0", "primary-1", "primary-2"] + bootstrap
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
            {"prometheus_url": "http://prometheus:9090", "alloy_url": "http://alloy:12345"},
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
                self.assertEqual(sorted(planned), sorted(set(services) - {"tools", "prometheus", "alloy"}))
                # Each support service declares the port that Alloy scrapes.
                for address in addresses:
                    name, port = address.split(":")
                    self.assertEqual(services[name].ports["metrics"].number, int(port))

    def test_prometheus_stores_and_alloy_scrapes(self):
        plan, services = self.run_package({})
        self.assertEqual(list(services)[:3], ["tools", "prometheus", "alloy"])
        prometheus = services["prometheus"]
        self.assertIn("--web.enable-remote-write-receiver", prometheus.cmd)
        self.assertNotIn("scrape_configs", plan.rendered("prometheus-config")["prometheus.yml"])
        alloy = services["alloy"]
        self.assertEqual(alloy.image, constants.IMAGES["alloy"])
        self.assertEqual(alloy.env_vars["PROMETHEUS_REMOTE_WRITE_URL"], "http://prometheus:9090/api/v1/write")
        self.assertIn("--disable-reporting", alloy.cmd)
        self.assertEqual(alloy.files["/etc/alloy"].artifact_names, ["alloy-metrics-pipeline"])
        # Nine nodes: the limits grow with the network.
        self.assertEqual(alloy.max_memory, constants.ALLOY_BASE_MEMORY + 9 * constants.ALLOY_NODE_MEMORY)
        self.assertEqual(prometheus.max_memory, constants.PROMETHEUS_BASE_MEMORY + 9 * constants.PROMETHEUS_NODE_MEMORY)

    def test_targets_and_labels(self):
        plan, _ = self.run_package({"l1": {"count": 2}})
        targets = plan.rendered("alloy-targets")
        # The pipeline reads one file per job; its `job_name` is the constant.
        pipeline = (starlark.ROOT / "static_files/observability/alloy/metrics.alloy").read_text()
        self.assertEqual(
            set(targets), {job + ".json" for job in vars(constants.METRICS_JOB).values()}
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

    def test_the_scrape_timeout_is_below_the_interval(self):
        # Alloy does not start otherwise, and `alloy validate` does not see it.
        pipeline = (starlark.ROOT / "static_files/observability/alloy/metrics.alloy").read_text()
        scrapes = pipeline.count("prometheus.scrape ")
        self.assertEqual(scrapes, 3)
        self.assertEqual(re.findall(r'scrape_interval += "(.+)"', pipeline), ["5s"] * scrapes)
        self.assertEqual(re.findall(r'scrape_timeout += "(.+)"', pipeline), ["4s"] * scrapes)


if __name__ == "__main__":
    unittest.main()
