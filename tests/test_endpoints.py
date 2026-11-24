"""scripts/endpoints.sh joins the manifest with the ports that Kurtosis publishes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
JQ = shutil.which("jq")
if os.environ.get("CI") and not JQ:
    raise RuntimeError("jq is required for the endpoints tests in CI")

# A fake Kurtosis CLI: `files download` writes the manifest, and `port print`
# answers from a table of published ports.
STUB = '''
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
state = Path(os.environ["TEST_STATE"])
if args[:2] == ["files", "download"]:
    target = Path(args[-1])
    target.mkdir(parents=True)
    (target / "deployment.json").write_text((state / "manifest.json").read_text())
elif args[:2] == ["port", "print"]:
    ports = json.loads((state / "ports.json").read_text())
    key = args[3] + "/" + args[4]
    if key not in ports:
        print("no such port", file=sys.stderr)
        sys.exit(1)
    print(ports[key])
else:
    raise RuntimeError(args)
'''

MANIFEST = {
    "primary_network": {"rpc_url": "http://primary-0:9650", "c_chain_id": 88888},
    "l1s": [
        {"name": "l1-0", "blockchain_id": "ChainA", "evm_chain_id": 77777,
         "rpc_urls": ["http://l1-0-rpc-0:9650/ext/bc/ChainA/rpc"]},
        {"name": "l1-1", "blockchain_id": "ChainB", "evm_chain_id": 77778,
         "rpc_urls": ["http://l1-1-rpc-0:9650/ext/bc/ChainB/rpc", "http://l1-1-rpc-1:9650/ext/bc/ChainB/rpc"]},
    ],
    "explorers": [
        {"chain": "c-chain", "evm_chain_id": 88888, "service": "c-chain-explorer", "port_id": "http"},
        {"chain": "l1-0", "evm_chain_id": 77777, "service": "l1-0-explorer", "port_id": "http"},
    ],
    "observability": {"grafana_url": "http://grafana:3000"},
}

PORTS = {
    "primary-0/rpc": "http://127.0.0.1:40001",
    "l1-0-rpc-0/rpc": "http://127.0.0.1:40002",
    "l1-1-rpc-0/rpc": "http://127.0.0.1:40003",
    "c-chain-explorer/http": "http://127.0.0.1:40004",
    "l1-0-explorer/http": "http://127.0.0.1:40005",
    "grafana/http": "http://127.0.0.1:40006",
}


@unittest.skipUnless(JQ, "jq is required for the endpoints tests")
class EndpointsTest(unittest.TestCase):
    def run_script(self, manifest=MANIFEST, ports=PORTS, *options):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "bin").mkdir()
            (work / "manifest.json").write_text(json.dumps(manifest))
            (work / "ports.json").write_text(json.dumps(ports))
            binary = work / "bin" / "kurtosis"
            binary.write_text("#!" + sys.executable + "\n" + STUB)
            binary.chmod(0o755)
            return subprocess.run(
                ["bash", str(ROOT / "scripts/endpoints.sh"), "test", *options],
                env=dict(os.environ, PATH=str(work / "bin") + os.pathsep + os.environ["PATH"], TEST_STATE=str(work)),
                capture_output=True, text=True,
            )

    def test_json_names_every_chain_explorer_and_grafana(self):
        result = self.run_script(MANIFEST, PORTS, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        endpoints = json.loads(result.stdout)
        self.assertEqual(endpoints["primary_network"], {
            "rpc_url": "http://127.0.0.1:40001",
            "p_chain_rpc_url": "http://127.0.0.1:40001/ext/bc/P",
            "x_chain_rpc_url": "http://127.0.0.1:40001/ext/bc/X",
            "c_chain_rpc_url": "http://127.0.0.1:40001/ext/bc/C/rpc",
            "c_chain_ws_url": "ws://127.0.0.1:40001/ext/bc/C/ws",
            "c_chain_id": 88888,
        })
        # Each L1 is reached through its first RPC node.
        self.assertEqual(endpoints["l1s"], [
            {"name": "l1-0", "blockchain_id": "ChainA", "evm_chain_id": 77777,
             "rpc_url": "http://127.0.0.1:40002/ext/bc/ChainA/rpc", "ws_url": "ws://127.0.0.1:40002/ext/bc/ChainA/ws"},
            {"name": "l1-1", "blockchain_id": "ChainB", "evm_chain_id": 77778,
             "rpc_url": "http://127.0.0.1:40003/ext/bc/ChainB/rpc", "ws_url": "ws://127.0.0.1:40003/ext/bc/ChainB/ws"},
        ])
        self.assertEqual(endpoints["explorers"], [
            {"chain": "c-chain", "evm_chain_id": 88888, "url": "http://127.0.0.1:40004",
             "api_url": "http://127.0.0.1:40004/api/v2"},
            {"chain": "l1-0", "evm_chain_id": 77777, "url": "http://127.0.0.1:40005",
             "api_url": "http://127.0.0.1:40005/api/v2"},
        ])
        self.assertEqual(endpoints["grafana_url"], "http://127.0.0.1:40006")

    def test_table(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertIn("C-Chain (chain ID 88888)    http://127.0.0.1:40001/ext/bc/C/rpc", lines)
        self.assertIn("l1-1 (chain ID 77778)       http://127.0.0.1:40003/ext/bc/ChainB/rpc", lines)
        self.assertIn("Explorer of l1-0            http://127.0.0.1:40005", lines)
        self.assertIn("Grafana                     http://127.0.0.1:40006", lines)

    def test_a_devnet_without_explorers_or_grafana(self):
        manifest = dict(MANIFEST, observability={})
        del manifest["explorers"]
        result = self.run_script(manifest, PORTS, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        endpoints = json.loads(result.stdout)
        self.assertEqual(endpoints["explorers"], [])
        self.assertNotIn("grafana_url", endpoints)

    def test_a_missing_port_fails(self):
        ports = dict(PORTS)
        del ports["l1-1-rpc-0/rpc"]
        result = self.run_script(MANIFEST, ports, "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no port rpc of service l1-1-rpc-0", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_an_unknown_option_fails_before_any_call(self):
        result = self.run_script(MANIFEST, PORTS, "--yaml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage", result.stderr)


if __name__ == "__main__":
    unittest.main()
