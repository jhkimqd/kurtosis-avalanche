import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackageCheckTest(unittest.TestCase):
    def run_check(self, fail_plan):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            (work / "scripts").mkdir()
            (work / "examples").mkdir()
            (work / ".github/configs").mkdir(parents=True)
            shutil.copyfile(ROOT / "scripts/check-package.sh", work / "scripts/check-package.sh")
            (work / "examples/profile.yml").write_text("staking: poa\n")
            (work / ".github/configs/two-l1s.yml").write_text("l1:\n  count: 2\n")
            binary = work / "bin/kurtosis"
            binary.parent.mkdir()
            binary.write_text(
                '#!/usr/bin/env bash\n'
                'printf "%s\\n" "$*" >> "$CALLS"\n'
                'if [[ "$1" == run ]] && { [[ "$FAIL_PLAN" == yes ]] || [[ "$FAIL_PLAN" == nightly && "$*" == *"--main-file nightly.star"* ]]; }; then\n'
                '    echo "There was an error interpreting Starlark code"\n'
                '    echo "Error encountered running Starlark code in dry-run mode."\n'
                'fi\n'
                'exit 0\n'
            )
            binary.chmod(0o755)
            calls = work / "calls.log"
            result = subprocess.run(
                ["bash", "scripts/check-package.sh"], cwd=work,
                env=dict(os.environ, PATH=str(binary.parent) + os.pathsep + os.environ["PATH"],
                         CALLS=str(calls), FAIL_PLAN=fail_plan),
                capture_output=True, text=True,
            )
            self.assertIn("enclave rm -f avax-check-", calls.read_text())
            return result

    def test_reported_plan_error_fails_even_when_cli_exits_zero(self):
        result = self.run_check(fail_plan="yes")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_successful_plan_check_returns_zero(self):
        result = self.run_check(fail_plan="no")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_nightly_plan_errors_also_fail_the_check(self):
        result = self.run_check(fail_plan="nightly")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nightly.star", result.stdout)


if __name__ == "__main__":
    unittest.main()
