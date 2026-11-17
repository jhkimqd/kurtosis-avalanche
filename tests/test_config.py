import pathlib, unittest, builtins, json, hashlib


def fail(message):
    raise ValueError(message)


def kind(value):
    return {int: "int", bool: "bool", str: "string", dict: "dict", list: "list"}.get(
        builtins.type(value), "unknown"
    )


ns = {"fail": fail, "type": kind}
exec(pathlib.Path("src/config/input.star").read_text(), ns)


class ConfigTest(unittest.TestCase):
    def test_rejects_unsupported_features_and_bad_bounds(self):
        for args in (
            {"network": "mainnet"},
            {"staking": "pos"},
            {"validator_count": 0},
            {"validator_count": True},
            {"l1_count": 0},
            {"metrics": "true"},
            {"instance_id": ""},
            {"chain_id_start": 88888},
            {"chain_id_start": 88887, "l1_count": 2},
        ):
            with self.subTest(args=args), self.assertRaises(ValueError):
                ns["parse"](args)

    def test_reserved_deployers_cannot_shift_contract_addresses(self):
        deployers = (
            "8db97c7cece249c2b98bdc0226cc4c2a57bf52fc",
            "0xF7Edc8FA1eCc32967F827C9043FcAe6ba73afA5c",
            "4CCeBa2d7D2B4fdcE4304d3e09a1fea9fbEb1528",
        )
        for address in deployers:
            for account in ({"nonce": "0x1"}, {"nonce": 1}, {"code": "0x00"}):
                with self.subTest(address=address, account=account), self.assertRaises(
                    ValueError
                ):
                    ns["parse"]({"l1_genesis": {"alloc": {address: account}}})
        for args in ({"alloc": []}, {"alloc": {deployers[0]: None}}):
            with self.subTest(genesis=args), self.assertRaises(ValueError):
                ns["parse"]({"l1_genesis": args})
        for nonce in (0, "0x0", "0x00", "0"):
            args = {
                "l1_genesis": {"alloc": {deployers[0]: {"nonce": nonce, "code": "0x"}}}
            }
            self.assertEqual(ns["parse"](args)["l1_genesis"], args["l1_genesis"])
        # Bridge-disabled networks do not reserve the bridge deployers.
        ns["parse"](
            {"bridge": False, "l1_genesis": {"alloc": {deployers[1]: {"nonce": "0x1"}}}}
        )

    def test_supported_profiles(self):
        for mode in ("poa", "native-pos", "erc20-pos"):
            self.assertEqual(
                ns["parse"]({"staking": mode, "instance_id": "test-instance"})[
                    "staking"
                ],
                mode,
            )


class OverrideTest(unittest.TestCase):
    def test_identity_and_wiring_cannot_be_overridden(self):
        for key in ns["MANAGED_NODE_KEYS"]:
            for scope in ("node_config", "role_config", "node_overrides"):
                value = {key: True}
                if scope == "role_config":
                    value = {"rpc": value}
                if scope == "node_overrides":
                    value = {"primary-0": value}
                with self.subTest(key=key, scope=scope), self.assertRaises(ValueError):
                    ns["parse"]({scope: value})

    def test_invalid_override_shapes_and_targets(self):
        for args in (
            {"primary_image": ""},
            {"primary_image": []},
            {"role_config": {"archive": {}}},
            {"role_config": []},
            {"node_overrides": {"primary-O": {}}},
            {"node_overrides": {"l1-0-rpc-1": {}}},
            {"l1_chain_config": {"warp-api-enabled": False}},
            {"c_chain_config": []},
        ):
            with self.subTest(args=args), self.assertRaises(ValueError):
                ns["parse"](args)

    def test_runtime_fleet_size(self):
        self.assertEqual(
            ns["parse"]({"staking": "poa", "validator_count": 15, "rpc_count": 3})[
                "fleet_size"
            ],
            18,
        )
        self.assertEqual(
            ns["parse"]({"staking": "native-pos", "validator_count": 1})["fleet_size"],
            22,
        )
        for args in ({"primary_count": 1}, {"validator_count": 101}, {"bridge": "yes"}):
            with self.subTest(args=args), self.assertRaises(ValueError):
                ns["parse"](args)

    def test_native_options_are_preserved(self):
        args = {
            "node_config": {"log-level": "debug"},
            "role_config": {"rpc": {"api-admin-enabled": False}},
            "node_overrides": {"l1-0-rpc-0": {"log-level": "warn"}},
            "c_chain_config": {"eth-apis": ["eth", "net"]},
        }
        actual = ns["parse"](args)
        for key, value in args.items():
            self.assertEqual(actual[key], value)


class ArtifactTest(unittest.TestCase):
    def test_required_contract_hashes(self):
        directory = pathlib.Path("static_files/contracts")
        expected = json.loads((directory / "hashes.json").read_text())
        self.assertEqual(
            set(expected),
            {p.stem for p in directory.glob("*.json") if p.name != "hashes.json"},
        )
        for name, digest in expected.items():
            with self.subTest(contract=name):
                data = (directory / (name + ".json")).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
                artifact = json.loads(data)
                self.assertTrue(artifact["abi"])
                self.assertTrue(artifact["bytecode"]["object"])

    def test_genesis_overrides_preserve_generated_requirements(self):
        args = {
            "l1_genesis": {"config": {"feeConfig": {"minBaseFee": 1000}}},
            "chain_id_start": 90000,
        }
        self.assertEqual(ns["parse"](args)["l1_genesis"], args["l1_genesis"])
        for key in ("chainId", "warpConfig", "contractNativeMinterConfig"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                ns["parse"]({"l1_genesis": {"config": {key: {}}}})


class RenderingTest(unittest.TestCase):
    def test_override_precedence_and_vm_config_separation(self):
        from types import SimpleNamespace

        class Plan:
            def render_templates(self, **kwargs):
                self.templates = kwargs["config"]
                return "rendered"

            def exec(self, **kwargs):
                self.flags = json.loads(kwargs["recipe"]["command"][3])

            def store_service_files(self, **kwargs):
                return "node-config"

            def add_service(self, **kwargs):
                return kwargs

        namespace = {
            "json": SimpleNamespace(encode=json.dumps, decode=json.loads),
            "read_file": lambda path: pathlib.Path("src/node", path).read_text(),
        }
        for symbol in (
            "struct",
            "ServiceConfig",
            "PortSpec",
            "Directory",
            "ExecRecipe",
        ):
            namespace[symbol] = lambda **kwargs: kwargs
        exec(pathlib.Path("src/node/launcher.star").read_text(), namespace)
        cfg = ns["parse"](
            {
                "node_config": {"log-level": "debug", "snow-sample-size": "1"},
                "role_config": {"rpc": {"log-level": "warn"}},
                "node_overrides": {"l1-0-rpc-0": {"log-level": "error"}},
                "c_chain_config": {"eth-apis": ["eth"]},
                "l1_chain_config": {"log-level": "info"},
            }
        )
        plan = Plan()
        service = namespace["launch"](
            plan,
            cfg,
            "fixtures",
            4,
            "l1-0-rpc-0",
            ("peer", "peer:9651"),
            "subnet",
            "chain",
            "rpc",
        )
        rendered = {
            key: json.loads(value["data"]["content"])
            for key, value in plan.templates.items()
        }
        self.assertEqual(plan.flags["log-level"], "error")
        self.assertEqual(plan.flags["snow-sample-size"], "1")
        self.assertEqual(plan.flags["bootstrap-ids"], "peer")
        self.assertEqual(rendered["C/config.json"]["eth-apis"], ["eth"])
        self.assertNotIn("eth-apis", rendered["chain/config.json"])
        self.assertTrue(rendered["chain/config.json"]["warp-api-enabled"])
        self.assertNotIn("/plugins", service["config"]["files"])


if __name__ == "__main__":
    unittest.main()
