"""A fresh Docker cache must not pollute the RPC values checked by the script."""

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
    raise RuntimeError("jq is required for devnet checker tests in CI")

# Test only the Primary Network and its EVM endpoint. No real container or RPC
# is used; Docker reproduces the stderr emitted when its image cache is empty.
STUB = '''
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
name = Path(sys.argv[0]).name
state = Path(os.environ['TEST_STATE'])
with (state / 'calls').open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\\n')
image = state / 'image'
if name == 'kurtosis':
    if args[:2] == ['files', 'download']:
        target = Path(args[-1])
        target.mkdir(parents=True)
        if args[3] == 'network-description':
            (target / 'primary-network').mkdir()
            (target / 'primary-network' / 'network.json').write_text(json.dumps({'chains': [
                {'blockchain_id': '11111111111111111111111111111111LpoYY'}, {'blockchain_id': 'C'}, {'blockchain_id': 'X'}]}))
        else:
            (target / 'deployment.json').write_text((state / 'manifest.json').read_text())
    elif args[:2] == ['port', 'print']:
        print('http://127.0.0.1:9650')
    else:
        raise RuntimeError(args)
elif name == 'curl':
    method = json.loads(args[args.index('--data') + 1])['method']
    result = {
        'info.getNetworkID': {'networkID': 88888},
        'info.isBootstrapped': {'isBootstrapped': True},
        'platform.getCurrentValidators': {'validators': [{}, {}]},
        'platform.getHeight': {'height': 1},
        'avm.getBalance': {'balance': 1},
        'platform.getBlockchains': {'blockchains': [{'id': 'X'}, {'id': 'C'}]},
        'eth_chainId': hex(88888),
    }[method]
    print(json.dumps({'result': result}))
elif name == 'docker':
    if args[:2] == ['image', 'inspect']:
        sys.exit(0 if image.exists() else 1)
    elif args[0] == 'pull':
        print('Pulling Foundry image', file=sys.stderr)
        if os.environ['FAIL_PULL'] == 'yes':
            sys.exit(8)
        image.touch()
    elif args[0] == 'run':
        if not image.exists():
            print('Unable to find image locally; pulling Foundry', file=sys.stderr)
            image.touch()
        cast = args[args.index('cast') + 2:]
        method = cast[0]
        if method == 'chain-id':
            print(88888)
        elif method == 'block-number':
            block = state / 'block'
            print(2 if block.exists() else 1)
            block.touch()
        elif method == 'balance':
            print(1)
        elif method == 'send':
            print(json.dumps({'status': '0x1', 'contractAddress': '0x1234'}))
        elif method == 'call':
            print('"CASH"' if 'symbol()(string)' in cast else '5')
        else:
            raise RuntimeError(cast)
    else:
        raise RuntimeError(args)
'''


@unittest.skipUnless(JQ, "jq is required for devnet checker tests")
class DevnetCheckTest(unittest.TestCase):
    def run_check(self, cached=False, fail_pull=False):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for folder in ("scripts", "contracts", "static_files/contracts", "bin"):
                (work / folder).mkdir(parents=True)
            for name in ("scripts/check-devnet.sh", "scripts/endpoints.sh", "contracts/Dockerfile"):
                shutil.copyfile(ROOT / name, work / name)
            (work / "static_files/contracts/CashToken.json").write_text(json.dumps({"bytecode": {"object": "0x00"}}))
            manifest = {
                "primary_network": {"network_id": 88888, "c_chain_id": 88888,
                                    "rpc_url": "http://primary-0:9650",
                                    "c_chain_rpc_url": "http://primary-0:9650/ext/bc/C/rpc"},
                "args": {"primary_network": {"validator_count": 2}, "l1": {"validator_count": 1, "rpc_count": 1}},
                "l1s": [],
            }
            (work / "manifest.json").write_text(json.dumps(manifest))
            if cached:
                (work / "image").touch()
            for name in ("docker", "curl", "kurtosis"):
                binary = work / "bin" / name
                binary.write_text("#!" + sys.executable + "\n" + STUB)
                binary.chmod(0o755)
            result = subprocess.run(
                ["bash", "scripts/check-devnet.sh", "test"], cwd=work,
                env=dict(os.environ, PATH=str(work / "bin") + os.pathsep + os.environ["PATH"],
                         TEST_STATE=str(work), FAIL_PULL="yes" if fail_pull else "no"),
                capture_output=True, text=True,
            )
            return result, (work / "calls").read_text()

    def test_cold_cache_pull_does_not_change_the_captured_chain_id(self):
        result, calls = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ok    chain ID: 88888", result.stdout)
        # The host address comes from the published port, not the manifest.
        self.assertIn("ok    EVM chain ID at http://127.0.0.1:9650/ext/bc/C/rpc: 88888", result.stdout)
        self.assertIn("ok    blockchains in /opt/networks/*/network.json", result.stdout)
        self.assertIn("Pulling Foundry image", result.stderr)
        self.assertLess(calls.index("docker pull "), calls.index("docker run "))

    def test_cached_image_does_not_require_a_registry_pull(self):
        result, calls = self.run_check(cached=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("docker pull ", calls)

    def test_pull_failure_stops_before_any_transaction(self):
        result, calls = self.run_check(fail_pull=True)
        self.assertEqual(result.returncode, 8, result.stdout + result.stderr)
        self.assertNotIn("docker run ", calls)


if __name__ == "__main__":
    unittest.main()
