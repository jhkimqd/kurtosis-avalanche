"""The option references in docs/config/ stay usable and in step with the package."""

import re
import unittest

import starlark

ROOT = starlark.ROOT
CONFIG = ROOT / "docs/config"
input_parser = starlark.load("src/config/input_parser.star")
sanity_check = starlark.load("src/config/sanity_check.star")

yaml = starlark.import_yaml()

# An option line is a comment whose `#` is followed by the key, after an even
# number of spaces for a nested key: `#key: value`, `#  nested: value`. Prose
# has one space: `# text`.
OPTION = re.compile(r"^(\s*)#(?=(?:  )*[A-Za-z\"])")


def uncommented(file):
    """Returns the file with every option line turned on."""
    return "\n".join(OPTION.sub(r"\1", line) for line in file.read_text().splitlines())


class NodeReferenceTest(unittest.TestCase):
    text = (CONFIG / "node.yml").read_text()

    def test_marks_exactly_the_managed_flags(self):
        marked = set(re.findall(r"^  # ([a-z0-9-]+) \(managed\)$", self.text, re.M))
        self.assertEqual(marked, set(sanity_check.MANAGED_NODE_FLAGS))

    def test_shows_every_package_default(self):
        for flag, value in input_parser.DEFAULT_NODE_CONFIG.items():
            value = str(value).lower() if isinstance(value, bool) else value
            # Note lines can follow the type line.
            pattern = r"Package default: {}\.\n(?:  # .*\n)*  #{}: ".format(
                re.escape(str(value)), flag
            )
            with self.subTest(flag=flag):
                self.assertRegex(self.text, pattern)

    def test_lists_each_flag_once(self):
        flags = re.findall(r"^  #([a-z0-9-]+): ", self.text, re.M)
        flags += re.findall(r"^  # ([a-z0-9-]+) \(managed\)$", self.text, re.M)
        self.assertEqual(len(flags), len(set(flags)))
        self.assertIn("all {} of them".format(len(flags)), self.text)


@unittest.skipUnless(yaml, "PyYAML is not installed")
class ReferenceFilesTest(unittest.TestCase):
    files = sorted(CONFIG.glob("*.yml"))

    def test_expected_files(self):
        self.assertEqual(
            [file.name for file in self.files],
            ["c-chain.yml", "l1-chain.yml", "l1-genesis.yml", "l1-subnet.yml", "node.yml", "p-x-chain.yml"],
        )

    def test_a_reference_sets_nothing_as_written(self):
        for file in self.files:
            with self.subTest(file=file.name):
                args = input_parser.parse(yaml.safe_load(file.read_text()))
                # A genesis key without a value keeps the base value.
                config = args["l1"]["genesis"].pop("config", None)
                self.assertIn(config, (None, {"feeConfig": None}))
                self.assertEqual(args, input_parser.parse({}))

    def test_every_option_line_is_valid_once_uncommented(self):
        for file in self.files:
            with self.subTest(file=file.name):
                args = yaml.safe_load(uncommented(file))
                parsed = input_parser.parse(args)
                # Each file documents one part of the arguments, and fills it.
                changed = [
                    (section, key)
                    for section in ("primary_network", "l1")
                    for key in parsed[section]
                    if parsed[section][key] != input_parser.parse({})[section][key]
                ]
                self.assertTrue(changed or "node_config" in args)

    def test_genesis_reference_shows_the_base_genesis(self):
        import json

        reference = yaml.safe_load(uncommented(CONFIG / "l1-genesis.yml"))["l1"]["genesis"]
        base = json.loads((ROOT / "static_files/l1-genesis.json").read_text())
        self.assertEqual(reference["config"]["feeConfig"], base["config"]["feeConfig"])
        self.assertNotIn("gasLimit", reference)  # Managed: follows the fee config.
        self.assertEqual(int(base["gasLimit"], 16), base["config"]["feeConfig"]["gasLimit"])
        self.assertEqual(reference["timestamp"].lower(), base["timestamp"].lower())
        (balance,) = [account["balance"] for account in reference["alloc"].values()]
        self.assertEqual([balance], [a["balance"] for a in base["alloc"].values()])


class RepositoryDocsTest(unittest.TestCase):
    """The prose documents name files and versions that exist."""

    documents = [ROOT / "README.md", ROOT / "AGENTS.md"] + sorted(ROOT.glob("docs/**/*.md"))

    def test_relative_links_resolve(self):
        for document in self.documents:
            for target in re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", document.read_text()):
                if "://" in target:
                    continue
                with self.subTest(document=document.name, link=target):
                    self.assertTrue((document.parent / target).exists())

    def test_named_repository_paths_exist(self):
        # A path in backticks that starts with a top-level directory of the repository.
        pattern = r"`((?:src|tools|tests|scripts|examples|docs|static_files|contracts|\.github)/[^`*<> ]+)`"
        for document in self.documents + sorted(ROOT.glob("examples/*.yml")):
            for path in re.findall(pattern, document.read_text()):
                with self.subTest(document=document.name, path=path):
                    self.assertTrue((ROOT / path.rstrip("/.,")).exists())

    def test_pinned_version_is_the_same_everywhere(self):
        constants_text = (ROOT / "src/config/constants.star").read_text()
        version = re.search(r"# AvalancheGo (v[\d.]+)\. Runs the Primary Network", constants_text)[1]
        commit = re.search(r"fetch --depth 1 origin ([0-9a-f]{40})", (ROOT / "tools/Dockerfile").read_text())[1]
        files = [ROOT / "README.md", ROOT / "AGENTS.md", ROOT / "examples/pos.yml"]
        files += sorted(CONFIG.glob("*.yml"))
        for file in files:
            text = file.read_text()
            with self.subTest(file=file.name):
                self.assertIn(version, text)
                # No other AvalancheGo release is named, and no other commit.
                self.assertEqual(set(re.findall(r"(?:AvalancheGo|avalanchego:|subnet-evm:)\s?(v\d+\.\d+\.\d+)", text)) - {version}, set())
                self.assertEqual(set(re.findall(r"\b[0-9a-f]{40}\b", text)) - {commit}, set())

    def test_readme_names_the_pinned_versions(self):
        constants_text = (ROOT / "src/config/constants.star").read_text()
        readme = (ROOT / "README.md").read_text()
        for component in ("Signature aggregator", "ICM relayer", "Alloy", "Grafana", "Loki", "Prometheus"):
            version = re.search(r"# {} (v[\d.]+)\.".format(component), constants_text)[1]
            with self.subTest(component=component):
                self.assertIn("| {} | {} |".format(component, version), readme)

    def test_pos_example_names_the_pinned_image_versions(self):
        # The `images` comment of the example shows each image with its tag.
        constants_text = (ROOT / "src/config/constants.star").read_text()
        example = (ROOT / "examples/pos.yml").read_text()
        for component, image in (
            ("Signature aggregator", "avaplatform/signature-aggregator:{}"),
            ("ICM relayer", "avaplatform/icm-relayer:{}"),
            ("Alloy", "grafana/alloy:{}"),
            ("Prometheus", "prom/prometheus:{}"),
            # These two images have tags without the `v`.
            ("Grafana", "grafana/grafana:{}"),
            ("Loki", "grafana/loki:{}"),
        ):
            version = re.search(r"# {} (v[\d.]+)\.".format(component), constants_text)[1]
            if component in ("Grafana", "Loki"):
                version = version.removeprefix("v")
            with self.subTest(component=component):
                self.assertIn("#   {}: {}".format(component.lower().replace(" ", "_"), image.format(version)), example)


if __name__ == "__main__":
    unittest.main()
