"""The shell script that describes the devnet in /opt/networks of the tools service."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "static_files/scripts/describe-networks.sh"
JQ = shutil.which("jq")
if os.environ.get("CI") and not JQ:
    raise RuntimeError("jq is required for the describe-networks tests in CI")

EMPTY = "11111111111111111111111111111111LpoYY"
RELAYER_KEY = "aa" * 32
RELAYER_ADDRESS = "0x176A0A29e5D61EB4dA42A3d5C71b7c17033fBF4D"

# A curl that answers like a devnet node with one L1. It logs each method.
CURL = '''
import json, os, sys
args = sys.argv[1:]
request = json.loads(args[args.index("--data") + 1])
with open(os.environ["TEST_CALLS"], "a") as log:
    log.write(request["method"] + " " + json.dumps(request["params"]) + "\\n")
results = {
    "info.getNetworkID": {"networkID": os.environ["TEST_NETWORK_ID"]},
    "platform.getBlockchains": {"blockchains": [
        {"id": "L1Chain", "name": "Avalanche Devnet", "subnetID": "L1Subnet", "vmID": "SubnetEVM"},
        {"id": "CChain", "name": "C-Chain", "subnetID": "%(empty)s", "vmID": "EVM"},
        {"id": "XChain", "name": "X-Chain", "subnetID": "%(empty)s", "vmID": "AVM"}]},
    "platform.getSubnet": {"isPermissioned": False, "managerChainID": "L1Chain"},
    "platform.getCurrentValidators": {"validators": [{"nodeID": "NodeID-" + request["params"].get("subnetID", "primary")}]},
}
print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": results[request["method"]]}))
''' % {"empty": EMPTY}

MANIFEST = {
    "primary_network": {
        "network_id": 88888, "rpc_url": "http://primary-0:9650",
        "p_chain_rpc_url": "http://primary-0:9650/ext/bc/P",
        "x_chain_rpc_url": "http://primary-0:9650/ext/bc/X",
        "c_chain_rpc_url": "http://primary-0:9650/ext/bc/C/rpc",
        "c_chain_ws_url": "ws://primary-0:9650/ext/bc/C/ws", "c_chain_id": 88888,
    },
    "l1s": [{
        "name": "l1-0", "subnet_id": "L1Subnet", "blockchain_id": "L1Chain", "evm_chain_id": 77777,
        "rpc_urls": ["http://l1-0-rpc-0:9650/ext/bc/L1Chain/rpc", "http://l1-0-rpc-1:9650/ext/bc/L1Chain/rpc"],
        "ws_urls": ["ws://l1-0-rpc-0:9650/ext/bc/L1Chain/ws", "ws://l1-0-rpc-1:9650/ext/bc/L1Chain/ws"],
        "validator_management": "native-pos",
        "validator_manager_address": "0x17aB05351fC94a1a67Bf3f56DdbB941aE6c63E25",
        "staking_manager_address": "0xStaking",
        "bridge": {"home": "0xHome"},
    }],
    "args": {},
}


@unittest.skipUnless(JQ, "jq is required for the describe-networks tests")
class DescribeNetworksTest(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work)
        state = self.work / "state"
        (state / "network").mkdir(parents=True)
        (state / "network/genesis.json").write_text('{"networkID": 88888}')
        relayer = state / "l1-0/bridge/relayer"
        relayer.mkdir(parents=True)
        (state / "l1-0/genesis.json").write_text('{"config": {"chainId": 77777}}')
        (relayer / "config.json").write_text(json.dumps({
            "source-blockchains": [{"message-contracts": {"0xMessenger": {"settings": {"reward-address": RELAYER_ADDRESS}}}}],
            "destination-blockchains": [{"account-private-key": RELAYER_KEY}],
        }))
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        curl = bin_dir / "curl"
        curl.write_text("#!" + sys.executable + "\n" + CURL)
        curl.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                        STATE_DIR=str(state), TEST_CALLS=str(self.work / "calls"),
                        TEST_NETWORK_ID="88888")
        self.out = self.work / "opt/networks"
        self.out.parent.mkdir()

    def run_script(self, *args, network_id="88888"):
        env = dict(self.env, TEST_NETWORK_ID=network_id)
        return subprocess.run(["bash", str(SCRIPT), str(self.out), *args],
                              env=env, capture_output=True, text=True)

    def read(self, path):
        return json.loads((self.out / path).read_text())

    def test_one_directory_per_network(self):
        result = self.run_script(json.dumps(MANIFEST))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Described 2 networks in {}\n".format(self.out))
        self.assertEqual(result.stderr, "")
        self.assertEqual(sorted(p.name for p in self.out.iterdir()),
                         ["deployment.json", "l1-0", "primary-network"])
        self.assertEqual(
            sorted(p.name for p in (self.out / "primary-network").iterdir()),
            ["accounts.json", "blockchains.json", "genesis.json", "network.json", "validators.json"])
        self.assertEqual(
            sorted(p.name for p in (self.out / "l1-0").iterdir()),
            ["accounts.json", "genesis.json", "network.json", "subnet.json", "validators.json"])
        # Only JSON files: no file for a reader that repeats them.
        self.assertEqual([p.name for p in self.out.rglob("*") if p.is_file() and p.suffix != ".json"], [])
        self.assertEqual(self.read("deployment.json"), MANIFEST)

        primary = self.read("primary-network/network.json")
        self.assertEqual([c["name"] for c in primary["chains"]], ["P-Chain", "X-Chain", "C-Chain"])
        self.assertEqual(primary["chains"][0]["blockchain_id"], EMPTY)
        self.assertEqual(primary["chains"][2]["blockchain_id"], "CChain")
        self.assertEqual(primary["chains"][2]["evm_chain_id"], 88888)
        self.assertEqual(primary["chains"][2]["rpc_url"], "http://primary-0:9650/ext/bc/C/rpc")
        # Host ports are random and known only outside the enclave
        # (helpers/endpoints.sh); the description holds no host address.
        self.assertNotIn("127.0.0.1", json.dumps(primary))
        self.assertEqual(len(self.read("primary-network/blockchains.json")["blockchains"]), 3)
        self.assertEqual(self.read("primary-network/validators.json")["validators"][0]["nodeID"], "NodeID-primary")
        self.assertEqual(self.read("primary-network/genesis.json"), {"networkID": 88888})

        l1 = self.read("l1-0/network.json")
        self.assertEqual(
            {k: l1[k] for k in ("blockchain_id", "subnet_id", "vm_id", "chain_name", "evm_chain_id", "rpc_url",
                                "staking_manager_address")},
            {"blockchain_id": "L1Chain", "subnet_id": "L1Subnet", "vm_id": "SubnetEVM",
             "chain_name": "Avalanche Devnet", "evm_chain_id": 77777,
             "rpc_url": "http://l1-0-rpc-0:9650/ext/bc/L1Chain/rpc",
             "staking_manager_address": "0xStaking"})
        self.assertEqual(len(l1["rpc_urls"]), 2)
        self.assertEqual(l1["bridge"], {"home": "0xHome"})
        self.assertEqual(self.read("l1-0/subnet.json")["managerChainID"], "L1Chain")
        self.assertEqual(self.read("l1-0/validators.json")["validators"][0]["nodeID"], "NodeID-L1Subnet")
        self.assertEqual(self.read("l1-0/genesis.json")["config"]["chainId"], 77777)

    def test_accounts_of_each_network(self):
        result = self.run_script(json.dumps(MANIFEST))
        self.assertEqual(result.returncode, 0, result.stderr)
        primary = self.read("primary-network/accounts.json")
        self.assertEqual([a["name"] for a in primary], ["ewoq", "messenger-deployer", "relayer-l1-0"])
        ewoq = primary[0]
        self.assertEqual(ewoq["evm_address"], "0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC")
        self.assertEqual(ewoq["p_chain_address"], "P-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p")
        self.assertTrue(ewoq["p_chain_private_key"].startswith("PrivateKey-ewoq"))
        self.assertEqual(primary[2]["private_key"], "0x" + RELAYER_KEY)
        self.assertEqual(primary[2]["evm_address"], RELAYER_ADDRESS)

        l1 = self.read("l1-0/accounts.json")
        self.assertEqual([a["name"] for a in l1],
                         ["ewoq", "bridge-recipient", "messenger-deployer", "token-remote-deployer", "relayer-l1-0"])
        self.assertIn("receives its rewards", l1[0]["role"])
        self.assertNotIn("Proof of Authority", l1[0]["role"])

    def test_poa_without_bridge(self):
        manifest = json.loads(json.dumps(MANIFEST))
        l1 = manifest["l1s"][0]
        for key in ("bridge", "staking_manager_address"):
            del l1[key]
        l1["validator_management"] = "poa"
        result = self.run_script(json.dumps(manifest))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([a["name"] for a in self.read("primary-network/accounts.json")], ["ewoq"])
        accounts = self.read("l1-0/accounts.json")
        self.assertEqual([a["name"] for a in accounts], ["ewoq"])
        self.assertIn("Proof of Authority", accounts[0]["role"])
        self.assertNotIn("staking_manager_address", self.read("l1-0/network.json"))

    def test_a_rerun_without_the_manifest_refreshes_the_files(self):
        self.assertEqual(self.run_script(json.dumps(MANIFEST)).returncode, 0)
        (self.out / "l1-0/stale.json").write_text("{}")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.out / "l1-0/stale.json").exists())
        self.assertEqual(self.read("deployment.json"), MANIFEST)
        # No temporary directory is left next to the output.
        self.assertEqual([p.name for p in self.out.parent.iterdir()], ["networks"])

    def test_refusals(self):
        # Another network: the manifest belongs to a different deployment.
        result = self.run_script(json.dumps(MANIFEST), network_id="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.out.exists())
        # An unknown L1 blockchain.
        manifest = json.loads(json.dumps(MANIFEST))
        manifest["l1s"][0]["blockchain_id"] = "Missing"
        result = self.run_script(json.dumps(manifest))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not list blockchain Missing", result.stderr)
        # A directory that the script did not write.
        self.out.mkdir()
        (self.out / "keep.txt").write_text("mine")
        result = self.run_script(json.dumps(MANIFEST))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.out / "keep.txt").exists())
        # No manifest at all.
        (self.out / "keep.txt").unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No deployment manifest", result.stderr)


if __name__ == "__main__":
    unittest.main()
