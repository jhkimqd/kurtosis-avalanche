"""helpers/check-observability.sh: what it asks, and when it fails."""

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
    raise RuntimeError("jq is required for the observability checker tests in CI")

# Stands in for `kurtosis` and `curl`. No service runs: every store answers
# each query with one series, except where TEST_FAULT asks for a fault.
STUB = r'''
import json
import os
from pathlib import Path
import sys

name, args = sys.argv[1], sys.argv[2:]
state = Path(os.environ['TEST_STATE'])
faults = os.environ.get('TEST_FAULT', '').split(',')
with (state / 'calls').open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\n')
NODES = ['primary-0', 'primary-1', 'l1-0-validator-0', 'l1-0-rpc-0']
if name == 'kurtosis':
    if args[:2] == ['files', 'download']:
        target = Path(args[-1])
        target.mkdir(parents=True)
        (target / 'deployment.json').write_text((state / 'manifest.json').read_text())
    elif args[:2] == ['port', 'print']:
        print('http://' + args[3])
    else:
        raise RuntimeError(args)
elif name == 'curl':
    url = next(arg for arg in args if arg.startswith('http://'))
    service, path = url.removeprefix('http://').split('/', 1)
    query = next((arg.removeprefix('query=') for arg in args if arg.startswith('query=')), '')
    if path == '-/ready':
        print('Alloy is ready.')
    elif service == 'prometheus':
        if query.startswith('count(up{job="avalanche"}'):
            value = '3' if 'node-down' in faults else str(len(NODES))
        elif query == 'up == 0':
            print(json.dumps({'status': 'success', 'data': {'result': [{'metric': {'node': 'l1-0-rpc-0'}}] if 'node-down' in faults else []}}))
            sys.exit(0)
        elif 'empty-panel' in faults and 'avalanche_snowman_blks_processing' in query:
            print(json.dumps({'status': 'success', 'data': {'result': []}}))
            sys.exit(0)
        elif 'no-answer' in faults and 'avalanche_network_peers' in query:
            # The store is down or too slow: curl prints nothing.
            sys.exit(0)
        elif 'query-error' in faults and 'avalanche_network_peers' in query:
            print(json.dumps({'status': 'error', 'error': 'query timed out'}))
            sys.exit(0)
        else:
            value = '1'
        print(json.dumps({'status': 'success', 'data': {'result': [{'metric': {}, 'value': [0, value]}]}}))
    elif service == 'loki':
        if path.endswith('query_range'):
            stated = '[11-19|10:00:00.123]' if 'read-time' not in faults else '[11-19|09:00:00.000]'
            # 2026-11-19T10:00:00.123Z in nanoseconds.
            print(json.dumps({'status': 'success', 'data': {'result': [{'stream': {}, 'values': [['1795082400123000000', stated + ' INFO node/node.go:160 initializing node']]}]}}))
        else:
            nodes = NODES[:-1] if 'no-logs' in faults else NODES
            print(json.dumps({'status': 'success', 'data': {'result': [{'metric': {'node': node}, 'value': [0, '5']} for node in nodes]}}))
    elif service == 'grafana':
        if path == 'api/health':
            print(json.dumps({'database': 'ok'}))
        elif path.startswith('api/datasources/uid/'):
            print(json.dumps({'status': 'OK'}))
        elif path.startswith('api/search'):
            uids = ['avalanche-overview', 'avalanche-l1', 'avalanche-primary-network', 'avalanche-icm', 'avalanche-logs']
            print(json.dumps([{'uid': uid} for uid in uids if not ('no-dashboard' in faults and uid == 'avalanche-l1')]))
        else:
            raise RuntimeError(url)
    else:
        raise RuntimeError(url)
'''

STACK = {name + "_url": "http://" + name for name in ("prometheus", "loki", "alloy", "grafana")}


@unittest.skipUnless(JQ, "jq is not installed")
class ObservabilityCheckTest(unittest.TestCase):
    def run_check(self, fault="", observability=STACK, bridge=False):
        manifest = {
            "args": {
                "primary_network": {"validator_count": 2},
                "l1": {"count": 1, "validator_count": 1, "rpc_count": 1},
                "bridge": bridge,
            },
            "observability": observability,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "bin"
            binaries.mkdir()
            stub = root / "stub.py"
            stub.write_text(STUB)
            for name in ("kurtosis", "curl"):
                (binaries / name).write_text('#!/bin/sh\nexec "{}" "{}" {} "$@"\n'.format(sys.executable, stub, name))
                (binaries / name).chmod(0o755)
            (root / "manifest.json").write_text(json.dumps(manifest))
            environment = dict(os.environ, PATH="{}:{}".format(binaries, os.environ["PATH"]),
                               TEST_STATE=str(root), TEST_FAULT=fault, CHECK_TIMEOUT="0")
            result = subprocess.run(
                ["bash", str(ROOT / "helpers/check-observability.sh"), "test-enclave"],
                capture_output=True, text=True, env=environment, timeout=120,
            )
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
        return result, calls

    # Each run asks every dashboard query once, so the cases share runs.

    def test_a_healthy_stack_passes_every_check(self):
        result, calls = self.run_check(bridge=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All checks passed", result.stdout)
        self.assertNotIn("FAIL", result.stdout)
        for line in ("every node is scraped: 4", "every ICM relayer is scraped: 1",
                     "every node has lines of its main logger: 4 nodes",
                     "a line keeps the time that it states: 11-19|10:00:00.123",
                     "Grafana has every dashboard: 5 dashboards"):
            self.assertIn(line, result.stdout)
        self.assertIn("app_successful_relay_message_count", calls)

    def test_each_fault_fails_its_check(self):
        result, _ = self.run_check("node-down,empty-panel,no-logs,read-time,no-dashboard")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for message in (
            "every node is scraped: 3 of 4 are up",
            "no target is down: l1-0-rpc-0",
            "has no data: ",
            "no lines of l1-0-rpc-0",
            "the line states '11-19|09:00:00.000', Loki holds it at '11-19|10:00:00.123'",
            "Grafana has every dashboard: missing avalanche-l1",
        ):
            with self.subTest(message=message):
                self.assertIn(message, result.stdout)
        self.assertIn("7 check(s) failed", result.stdout)

    def test_a_store_that_does_not_answer_is_not_data(self):
        # Metrics only, to keep the run short.
        stack = {key: STACK[key] for key in ("prometheus_url", "alloy_url")}
        for fault in ("no-answer", "query-error"):
            with self.subTest(fault=fault):
                result, _ = self.run_check(fault, observability=stack)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("has no data: ", result.stdout)
                self.assertIn("avalanche_network_peers", result.stdout)

    def test_only_the_running_parts_are_checked(self):
        result, calls = self.run_check(observability={})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no observability stack", result.stdout)
        self.assertNotIn("curl", calls)
        # Metrics only, and no bridge: no Loki, no Grafana, no relayer.
        stack = {key: STACK[key] for key in ("prometheus_url", "alloy_url")}
        result, calls = self.run_check(observability=stack)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Metrics in Prometheus", result.stdout)
        for absent in ("Logs in Loki", "Grafana", "ICM relayer"):
            self.assertNotIn(absent, result.stdout)
        for absent in ("http://loki", "http://grafana", "icm-relayer", "app_successful_relay_message_count"):
            self.assertNotIn(absent, calls)

    def test_an_enclave_without_a_manifest_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            binaries = Path(directory)
            (binaries / "kurtosis").write_text("#!/bin/sh\nexit 1\n")
            (binaries / "kurtosis").chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "helpers/check-observability.sh"), "missing"],
                capture_output=True, text=True,
                env=dict(os.environ, PATH="{}:{}".format(binaries, os.environ["PATH"])),
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Cannot read the deployment manifest", result.stderr)


if __name__ == "__main__":
    unittest.main()
