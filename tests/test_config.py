"""Arguments: defaults, validation, and the shipped arguments files."""

import hashlib
import json
import unittest

import starlark

ROOT = starlark.ROOT
constants = starlark.load("src/config/constants.star")
input_parser = starlark.load("src/config/input_parser.star")
sanity_check = starlark.load("src/config/sanity_check.star")
parse = input_parser.parse

yaml = starlark.import_yaml()


class DefaultsTest(unittest.TestCase):
    def test_empty_arguments_resolve_to_the_documented_defaults(self):
        args = parse({})
        self.assertEqual(set(args), set(input_parser.DEFAULT_ARGS))
        self.assertEqual(args["primary_network"]["validator_count"], 3)
        self.assertEqual(args["l1"]["validator_management"], "native-pos")
        self.assertEqual(args["l1"]["validator_count"], 5)
        self.assertEqual(args["images"], constants.IMAGES)
        self.assertTrue(args["bridge"] and args["metrics"])

    def test_a_key_without_a_value_keeps_its_default(self):
        # YAML parses a key that holds only comments as None.
        args = parse({"l1": None, "primary_network": {"node_config": None}, "bridge": None})
        self.assertEqual(args["l1"]["validator_count"], 5)
        self.assertEqual(
            args["primary_network"]["node_config"], input_parser.DEFAULT_NODE_CONFIG
        )
        self.assertTrue(args["bridge"])

    def test_parsing_does_not_change_the_defaults(self):
        before = json.dumps(input_parser.DEFAULT_ARGS, sort_keys=True)
        parse({"node_config": {"log-level": "debug"}, "l1": {"chain_config": {"a": 1}}})
        self.assertEqual(json.dumps(input_parser.DEFAULT_ARGS, sort_keys=True), before)
        self.assertEqual(parse({})["l1"]["chain_config"], {"warp-api-enabled": True})


class ValidationTest(unittest.TestCase):
    def assert_rejected(self, args):
        # Only the package's own `fail()` counts, not an error of the test loader.
        with self.subTest(args=args), self.assertRaises(starlark.Fail):
            parse(args)

    def test_unknown_arguments(self):
        for args in (
            {"network": "mainnet"},
            {"staking": "poa"},  # Renamed to l1.validator_management.
            {"primary_network": {"count": 3}},
            {"l1": {"validators": 5}},
            {"images": {"avalanche": "image"}},
            {"l1": []},
            ["l1"],
        ):
            self.assert_rejected(args)

    def test_counts_and_chain_ids(self):
        for args in (
            {"primary_network": {"validator_count": 1}},
            {"primary_network": {"validator_count": 101}},
            {"l1": {"count": 0}},
            {"l1": {"validator_count": 0}},
            {"l1": {"validator_count": True}},
            {"l1": {"validator_count": "5"}},
            {"l1": {"rpc_count": 0}},
            {"l1": {"count": 101}},
            {"l1": {"validator_count": 101}},
            {"l1": {"rpc_count": 101}},
            {"l1": {"chain_id": 0}},
            {"l1": {"chain_id": 2147483548}},
            {"l1": {"chain_id": constants.C_CHAIN_ID}},
            {"l1": {"chain_id": constants.C_CHAIN_ID - 1, "count": 2}},
            # Chain IDs of public networks: a devnet transaction must not be valid there.
            {"l1": {"chain_id": 1}},
            {"l1": {"chain_id": 43113}},
            {"l1": {"chain_id": 43114}},
            {"l1": {"chain_id": 43112, "count": 2}},
        ):
            self.assert_rejected(args)
        parse({"l1": {"chain_id": 43115}})
        parse({"l1": {"count": 100, "validator_count": 100, "rpc_count": 100, "chain_id": 2147483447}})
        parse({"l1": {"chain_id": constants.C_CHAIN_ID - 2, "count": 2}})
        parse({"l1": {"chain_id": constants.C_CHAIN_ID + 1}})

    def test_modes_flags_and_images(self):
        for args in (
            {"l1": {"validator_management": "pos"}},
            {"bridge": "yes"},
            {"metrics": 1},
            {"images": {"avalanchego": ""}},
            {"images": {"subnet_evm": []}},
            {"images": {"tools": 1}},
        ):
            self.assert_rejected(args)
        for mode in ("poa", "native-pos", "erc20-pos"):
            self.assertEqual(
                parse({"l1": {"validator_management": mode}})["l1"]["validator_management"],
                mode,
            )
        # An empty tools image selects the local build.
        self.assertEqual(parse({"images": {"tools": ""}})["images"]["tools"], "")

    def test_config_mappings(self):
        for args in (
            {"node_config": []},
            {"primary_network": {"c_chain_config": []}},
            {"l1": {"chain_config": "pruning-enabled"}},
            {"l1": {"subnet_config": "validatorOnly"}},
            {"primary_network": {"p_chain_config": []}},
            {"primary_network": {"x_chain_config": "checksums-enabled"}},
            {"node_config": {1: True}},
            # A private L1 would lock out the RPC nodes and the aggregator.
            {"l1": {"subnet_config": {"validatorOnly": True}}},
        ):
            self.assert_rejected(args)
        parse({"l1": {"subnet_config": {"validatorOnly": False}}})

    def test_managed_node_flags_cannot_be_overridden(self):
        for flag in sanity_check.MANAGED_NODE_FLAGS:
            for args in (
                {"node_config": {flag: True}},
                {"primary_network": {"node_config": {flag: True}}},
                {"l1": {"node_config": {flag: True}}},
            ):
                self.assert_rejected(args)

    def test_managed_genesis_fields_cannot_be_overridden(self):
        self.assertEqual(sanity_check.MANAGED_GENESIS_KEYS, ["gasLimit"])
        for key in sanity_check.MANAGED_GENESIS_KEYS:
            self.assert_rejected({"l1": {"genesis": {key: "0x1"}}})
        for key in sanity_check.MANAGED_GENESIS_CONFIG_KEYS:
            self.assert_rejected({"l1": {"genesis": {"config": {key: {}}}}})
        for genesis in (
            [],
            {"config": []},
            {"alloc": []},
            {"alloc": {"ab": None}},
            {"alloc": {1: {}}},
            # An unquoted balance is a YAML number, which can lose digits.
            {"alloc": {"ab": {"balance": 1000000000000000000}}},
            # Subnet-EVM rejects an account without a balance.
            {"alloc": {"ab": {"code": "0x00"}}},
        ):
            self.assert_rejected({"l1": {"genesis": genesis}})
        parse({"l1": {"genesis": {"alloc": {"ab": {"balance": "0x1"}, "cd": {"balance": "0", "code": "0x00"}}}}})
        # A key without a value is accepted; it keeps the base genesis value.
        parse({"l1": {"genesis": {"config": {"feeConfig": None}, "alloc": None}}})
        parse({"l1": {"genesis": {"config": None}}})
        genesis = {"config": {"feeConfig": {"minBaseFee": 1000}}}
        self.assertEqual(parse({"l1": {"genesis": genesis}})["l1"]["genesis"], genesis)

    def test_reserved_deployers_cannot_shift_contract_addresses(self):
        ewoq = "0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC"
        bridge_deployers = (
            "0xF7Edc8FA1eCc32967F827C9043FcAe6ba73afA5c",
            "4CCeBa2d7D2B4fdcE4304d3e09a1fea9fbEb1528",
        )
        funded = lambda **account: dict(account, balance="0x1")
        for address in (ewoq,) + bridge_deployers:
            parse({"l1": {"genesis": {"alloc": {address: funded()}}}})
            for account in (funded(nonce="0x1"), funded(nonce=1), funded(nonce="abc"), funded(code="0x00")):
                self.assert_rejected({"l1": {"genesis": {"alloc": {address: account}}}})
        for nonce in (0, "0x0", "0"):
            parse({"l1": {"genesis": {"alloc": {ewoq: funded(nonce=nonce, code="0x")}}}})
        # Without the bridge, only the ValidatorManager deployer is reserved.
        genesis = {"alloc": {bridge_deployers[0]: funded(nonce="0x1")}}
        parse({"bridge": False, "l1": {"genesis": genesis}})
        self.assert_rejected({"bridge": False, "l1": {"genesis": {"alloc": {ewoq: funded(nonce=1)}}}})


class NodeConfigTest(unittest.TestCase):
    def test_later_layers_take_precedence(self):
        args = parse(
            {
                "node_config": {"log-level": "debug", "snow-sample-size": 5},
                "primary_network": {"node_config": {"log-level": "warn"}},
                "l1": {"node_config": {"index-enabled": False}},
            }
        )
        primary, l1 = args["primary_network"]["node_config"], args["l1"]["node_config"]
        self.assertEqual(primary["log-level"], "warn")
        self.assertEqual(l1["log-level"], "debug")
        self.assertEqual(primary["snow-sample-size"], 5)
        self.assertTrue(primary["index-enabled"])
        self.assertFalse(l1["index-enabled"])
        # Untouched package defaults remain.
        self.assertEqual(l1["snow-preference-quorum-size"], 2)

    def test_package_defaults_do_not_include_managed_flags(self):
        self.assertFalse(
            set(input_parser.DEFAULT_NODE_CONFIG) & set(sanity_check.MANAGED_NODE_FLAGS)
        )

    def test_chain_configs_stay_separate(self):
        args = parse(
            {
                "primary_network": {"c_chain_config": {"apis": ["chain"]}},
                "l1": {"chain_config": {"log-level": "debug"}},
            }
        )
        self.assertEqual(args["primary_network"]["c_chain_config"], {"apis": ["chain"]})
        self.assertEqual(
            args["l1"]["chain_config"], {"warp-api-enabled": True, "log-level": "debug"}
        )
        # A package default of the chain config can be overridden.
        args = parse({"l1": {"chain_config": {"warp-api-enabled": False}}})
        self.assertEqual(args["l1"]["chain_config"], {"warp-api-enabled": False})


def merge(base, override):
    """Mirrors mergeJSON in tools/lifecycle.go."""
    for key, value in override.items():
        if value is None:
            continue
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base


@unittest.skipUnless(yaml, "PyYAML is not installed")
class ArgumentsFilesTest(unittest.TestCase):
    def files(self):
        files = sorted(ROOT.glob("examples/*.yml")) + sorted(ROOT.glob(".github/configs/*.yml"))
        self.assertEqual(
            [file.name for file in sorted(ROOT.glob("examples/*.yml"))], ["poa.yml", "pos.yml"]
        )
        return files

    def test_every_arguments_file_is_valid(self):
        for file in self.files():
            with self.subTest(file=file.name):
                parse(yaml.safe_load(file.read_text()))

    def test_pos_example_documents_the_defaults(self):
        written = yaml.safe_load((ROOT / "examples/pos.yml").read_text())
        # The example names every argument. The `images` defaults are long
        # digests; the example shows that argument as a comment.
        self.assertEqual(set(written), set(input_parser.DEFAULT_ARGS) - {"images"})
        for section in ("primary_network", "l1"):
            self.assertEqual(set(written[section]), set(input_parser.DEFAULT_ARGS[section]))
        example = parse(written)
        defaults = parse({})
        # The example spells out the genesis defaults; the rest must be equal.
        genesis = example["l1"].pop("genesis")
        defaults["l1"].pop("genesis")
        self.assertEqual(example, defaults)
        base = json.loads((ROOT / "static_files/l1-genesis.json").read_text())
        normalize = lambda alloc: {
            address.lower().removeprefix("0x"): account for address, account in alloc.items()
        }
        base["alloc"] = normalize(base["alloc"])
        genesis["alloc"] = normalize(genesis["alloc"])
        self.assertEqual(merge(json.loads(json.dumps(base)), genesis), base)

    def test_poa_example_spells_out_the_default_fees(self):
        example = yaml.safe_load((ROOT / "examples/poa.yml").read_text())
        base = json.loads((ROOT / "static_files/l1-genesis.json").read_text())
        self.assertEqual(
            example["l1"]["genesis"]["config"]["feeConfig"], base["config"]["feeConfig"]
        )
        self.assertEqual(example["l1"]["validator_management"], "poa")


class ContractArtifactTest(unittest.TestCase):
    def test_required_contract_hashes(self):
        directory = ROOT / "static_files/contracts"
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


if __name__ == "__main__":
    unittest.main()
