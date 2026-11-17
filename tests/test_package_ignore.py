"""Keep the local-package upload boundary explicit, without emulating Kurtosis."""

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackageIgnoreTest(unittest.TestCase):
    def test_root_upload_policy_excludes_only_metadata_and_generated_outputs(self):
        ignore_file = ROOT / ".kurtosisignore"
        self.assertTrue(
            ignore_file.is_file(),
            "kurtosis run . needs a root .kurtosisignore; .gitignore is not used",
        )
        rules = {
            line.strip()
            for line in ignore_file.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        }
        # Deliberate allowlist: adding broad patterns could silently remove
        # main.star, kurtosis.yml, src/, static_files/, or the tools/ build
        # context (including tools/.dockerignore). Review policy changes here.
        # Kurtosis 1.18.2 accepts these literal directory rules and *.pyc;
        # directory traversal prunes their contents, including private evidence.
        self.assertEqual(rules, {
            ".git/",
            ".build/",
            "artifacts/",
            "contracts/out/",
            "contracts/cache/",
            "__pycache__/",
            "*.pyc",
        })


if __name__ == "__main__":
    unittest.main()
