import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class ExportContractsTest(unittest.TestCase):
    def test_manifest_is_published_only_after_all_contracts_export(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            artifacts = ROOT / "static_files/contracts"
            expected = json.loads((artifacts / "hashes.json").read_text())
            for name in expected:
                build = (
                    "contracts/out"
                    if name in ("StakingToken", "CashToken", "MessageReceiver")
                    else ".build/icm/out"
                )
                target = work / build / (name + ".sol") / (name + ".json")
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(artifacts / (name + ".json"), target)
            output = work / "static_files/contracts"
            output.mkdir(parents=True)
            manifest = output / "hashes.json"
            manifest.write_text('{"previous": "manifest"}\n')
            cash = work / "contracts/out/CashToken.sol/CashToken.json"
            data = cash.read_bytes()
            cash.unlink()
            command = [sys.executable, str(ROOT / "helpers/export-contracts.py")]
            failed = subprocess.run(command, cwd=work, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("CashToken.json", failed.stderr)
            self.assertEqual(json.loads(manifest.read_text()), {"previous": "manifest"})
            cash.write_bytes(data)
            subprocess.run(
                command, cwd=work, capture_output=True, text=True, check=True
            )
            self.assertEqual(json.loads(manifest.read_text()), expected)
            for name, digest in expected.items():
                self.assertEqual(
                    hashlib.sha256(
                        (output / (name + ".json")).read_bytes()
                    ).hexdigest(),
                    digest,
                )


if __name__ == "__main__":
    unittest.main()
