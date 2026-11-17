"""Exercise the developer script without requiring Docker in unit tests.

The fake Docker command supplies real committed artifacts at the container boundary;
run scripts/check-contracts.sh itself to verify the pinned compiler build.
"""
import hashlib
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ContractBuildTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = pathlib.Path(self.temporary.name)
        self.root = self.work / "checkout"
        for relative in (
            "scripts/check-contracts.sh", "scripts/export-contracts.py",
            "contracts/Dockerfile", "contracts/foundry.toml",
        ):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if (ROOT / relative).exists():
                shutil.copyfile(ROOT / relative, target)
        shutil.copytree(ROOT / "contracts/src", self.root / "contracts/src")
        shutil.copytree(ROOT / "static_files/contracts", self.root / "static_files/contracts")
        self.rebuilt = self.work / "rebuilt"
        shutil.copytree(ROOT / "static_files/contracts", self.rebuilt)
        # Existing compiler outputs are deliberately not part of the build context.
        stale = self.root / ".build/icm/out/stale"
        stale.parent.mkdir(parents=True)
        stale.write_text("do not touch")
        bin_directory = self.work / "bin"
        bin_directory.mkdir()
        docker = bin_directory / "docker"
        docker.write_text('''#!/usr/bin/env python3
import os, pathlib, sys, tarfile
args = sys.argv[1:]
if args[0] == "build":
    context = pathlib.Path(args[-1])
    assert not (context / ".build").exists()
    assert not (context / "contracts/out").exists()
    assert (context / "contracts/src/CashToken.sol").is_file()
    assert (context / "scripts/export-contracts.py").is_file()
    pathlib.Path(args[args.index("--iidfile") + 1]).write_text("sha256:test-image")
elif args[0] == "run":
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as archive:
        archive.add(os.environ["REBUILT"], arcname=".")
else:
    raise SystemExit("unexpected Docker command: " + repr(args))
''')
        docker.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(bin_directory) + os.pathsep + os.environ["PATH"],
                                REBUILT=str(self.rebuilt), TMPDIR=str(self.work))

    def snapshot(self):
        return {str(path.relative_to(self.root)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in self.root.rglob("*") if path.is_file()}

    def run_script(self, *arguments):
        return subprocess.run(["bash", str(self.root / "scripts/check-contracts.sh"), *arguments],
                              env=self.environment, cwd=self.work, capture_output=True, text=True)

    def test_default_check_builds_in_isolation_without_writing_checkout(self):
        before = self.snapshot()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertIn("11", result.stdout)

    def test_mismatch_fails_without_rewriting_artifact_or_manifest(self):
        artifact = self.root / "static_files/contracts/CashToken.json"
        artifact.write_text(artifact.read_text() + " ")
        before = self.snapshot()
        result = self.run_script("check")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CashToken.json", result.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_refresh_is_explicit_and_updates_both_artifacts_and_hashes(self):
        directory = self.root / "static_files/contracts"
        (directory / "CashToken.json").write_text("outdated artifact\n")
        (directory / "hashes.json").write_text("outdated manifest\n")
        result = self.run_script("refresh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in directory.iterdir()},
                         {p.name: p.read_bytes() for p in self.rebuilt.iterdir()})
        self.assertEqual((self.root / ".build/icm/out/stale").read_text(), "do not touch")

    def test_unknown_mode_and_extra_arguments_are_rejected(self):
        for arguments in (("--refresh",), ("typo",), ("check", "refresh")):
            with self.subTest(arguments=arguments):
                before = self.snapshot()
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("Usage:", result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_failed_build_does_not_refresh_any_artifact(self):
        docker = self.work / "bin/docker"
        docker.write_text("#!/bin/sh\nexit 42\n")
        before = self.snapshot()
        result = self.run_script("refresh")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
