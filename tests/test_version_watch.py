"""Release discovery must distinguish stable updates from unavailable checks."""

import contextlib
import importlib.util
import io
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("watch_versions", ROOT / "scripts/watch-versions.py")
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


def release(tag):
    return dict(tag_name=tag, draft=False, prerelease=False)


class ReleaseTest(unittest.TestCase):
    def test_numeric_comparison_handles_double_digit_versions(self):
        self.assertGreater(watch.version("v1.10.0"), watch.version("v1.9.9"))
        self.assertEqual(watch.version("1.2.3"), watch.version("v1.2.3"))
        for tag in ("v1.2.3-rc.1", "v1.2.3-fuji", "nightly", "v1.2"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                watch.version(tag)

    def test_component_releases_are_filtered_and_sorted_numerically(self):
        tags = [release("icm-relayer-v1.9.0"), release("icm-relayer-v1.10.0"),
                release("icm-relayer-v2.0.0-rc.0"), release("icm-relayer-v3.0.0-fuji"),
                release("signature-aggregator-v9.0.0"),
                dict(tag_name="icm-relayer-v4.0.0", draft=True, prerelease=False),
                dict(tag_name="icm-relayer-v5.0.0", draft=False, prerelease=True)]
        self.assertEqual(watch.latest_release("ava-labs/icm-services", "icm-relayer-", lambda _: tags),
                         "icm-relayer-v1.10.0")

    def test_component_discovery_follows_pagination(self):
        calls = []

        def fetch(path):
            calls.append(path)
            if path.endswith("page=1"):
                return [release("icm-relayer-v1.0.0")] * 100
            return [release("signature-aggregator-v0.7.0")]

        self.assertEqual(watch.latest_release("ava-labs/icm-services", "signature-aggregator-", fetch),
                         "signature-aggregator-v0.7.0")
        self.assertEqual(len(calls), 2)

    def test_no_matching_component_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "no stable release"):
            watch.latest_release("ava-labs/icm-services", "icm-relayer-", lambda _: [release("other-v1.0.0")])

    def test_latest_endpoint_does_not_accept_a_prerelease(self):
        for data in [dict(tag_name="v2.0.0", draft=False, prerelease=True), release("v2.0.0-rc.1")]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                watch.latest_release("example/tool", "", lambda _: data)

    def test_current_versions_come_from_repository_files(self):
        pins = watch.pins(ROOT)
        self.assertEqual(len(pins), 9)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("src/config/constants.star", ".github/actions/setup-kurtosis/action.yml", "contracts/Dockerfile"):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text((ROOT / name).read_text())
            setup = root / ".github/actions/setup-kurtosis/action.yml"
            setup.write_text(re.sub(r"KURTOSIS_VERSION: [\d.]+", "KURTOSIS_VERSION: 1.99.0", setup.read_text()))
            self.assertIn(("Kurtosis CLI", "kurtosis-tech/kurtosis", "", "1.99.0"), watch.pins(root))

    def test_suffixed_cli_pin_is_not_silently_treated_as_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("src/config/constants.star", ".github/actions/setup-kurtosis/action.yml", "contracts/Dockerfile"):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text((ROOT / name).read_text())
            setup = root / ".github/actions/setup-kurtosis/action.yml"
            template = setup.read_text()
            for value in ("1.18.2-bad", "1.18.2-rc.1", "1.18.2#bad"):
                setup.write_text(re.sub(r"KURTOSIS_VERSION: [\d.]+", "KURTOSIS_VERSION: " + value, template))
                with self.subTest(value=value), self.assertRaisesRegex(ValueError, "not a stable version"):
                    watch.pins(root)


class ReportTest(unittest.TestCase):
    pins = [("Example", "example/tool", "", "v1.9.0")]

    def test_updates_warn_without_failing_or_changing_pins(self):
        with contextlib.redirect_stdout(io.StringIO()) as warnings:
            report, errors = watch.report(self.pins, lambda _: release("v1.10.0"))
        self.assertFalse(errors)
        self.assertIn("Update available", report)
        self.assertIn("::warning", warnings.getvalue())
        self.assertEqual(self.pins[0][-1], "v1.9.0")

    def test_pinned_version_ahead_of_latest_is_not_an_update(self):
        with contextlib.redirect_stdout(io.StringIO()) as warnings:
            report, errors = watch.report(self.pins, lambda _: release("v1.8.0"))
        self.assertFalse(errors)
        self.assertIn("Pinned newer than latest release", report)
        self.assertFalse(warnings.getvalue())

    def test_one_api_failure_keeps_other_results_and_is_not_current(self):
        pins = self.pins + [("Other", "example/other", "", "v1.0.0")]

        def fetch(path):
            if "other" in path:
                raise HTTPError("https://api.github.com" + path, 403, "rate limited", {}, None)
            return release("v1.9.0")

        report, errors = watch.report(pins, fetch)
        self.assertEqual(len(errors), 1)
        self.assertIn("| Example | v1.9.0 |", report)
        self.assertIn("| Other | v1.0.0 | Unavailable | Check failed |", report)

    def test_failed_check_writes_summary_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            output = Path(directory) / "report.md"
            with patch.object(watch, "pins", return_value=self.pins), \
                 patch.object(watch, "github_client", return_value=lambda _: {}), \
                 patch("sys.argv", ["watch-versions.py", "--output", str(output)]), \
                 patch.dict("os.environ", GITHUB_STEP_SUMMARY=str(summary)), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(watch.main(), 1)
            self.assertIn("Check failed", summary.read_text())
            self.assertEqual(summary.read_text(), output.read_text())

    def test_missing_pin_is_reported_and_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            with patch.object(watch, "pins", side_effect=ValueError("missing CLI version")), \
                 patch("sys.argv", ["watch-versions.py"]), \
                 patch.dict("os.environ", GITHUB_STEP_SUMMARY=str(summary)), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(watch.main(), 1)
            self.assertIn("Could not read pinned versions: missing CLI version", summary.read_text())


if __name__ == "__main__":
    unittest.main()
