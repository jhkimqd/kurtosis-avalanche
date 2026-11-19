#!/usr/bin/env python3
"""Report newer stable upstream releases without changing the package pins."""

import argparse
from functools import cache
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
VERSION = r"v?(\d+)\.(\d+)\.(\d+)"


def version(tag):
    """Return a numeric stable version, rejecting prereleases and other tags."""
    match = re.fullmatch(VERSION, tag)
    if not match:
        raise ValueError("not a stable version: " + tag)
    return tuple(map(int, match.groups()))


def pins(root):
    """Read versions from the same files CI and the launchers use."""
    constants = (root / "src/config/constants.star").read_text()
    components = [
        ("AvalancheGo", "ava-labs/avalanchego", "", r"# AvalancheGo (v[\d.]+)\. Runs"),
        ("Subnet-EVM image", "ava-labs/avalanchego", "", r"# AvalancheGo (v[\d.]+) with"),
        ("Signature aggregator", "ava-labs/icm-services", "signature-aggregator-", r"# Signature aggregator (v[\d.]+)\."),
        ("ICM relayer", "ava-labs/icm-services", "icm-relayer-", r"# ICM relayer (v[\d.]+)\."),
        ("Alloy", "grafana/alloy", "", r"# Alloy (v[\d.]+)\."),
        ("Loki", "grafana/loki", "", r"# Loki (v[\d.]+)\."),
        ("Prometheus", "prometheus/prometheus", "", r"# Prometheus (v[\d.]+)\."),
    ]
    result = []
    for name, repo, prefix, pattern in components:
        match = re.search(pattern, constants)
        if not match:
            raise ValueError("cannot find the pinned version of " + name)
        result.append((name, repo, prefix, match[1]))
    setup = (root / ".github/actions/setup-kurtosis/action.yml").read_text()
    foundry = (root / "contracts/Dockerfile").read_text()
    for name, repo, text, pattern in [
        ("Kurtosis CLI", "kurtosis-tech/kurtosis", setup, r"(?m)^[ \t]*KURTOSIS_VERSION:[ \t]+(\S+)[ \t]*$"),
        ("Foundry", "foundry-rs/foundry", foundry, r"FROM ghcr.io/foundry-rs/foundry:(v[\d.]+)@"),
    ]:
        match = re.search(pattern, text)
        if not match:
            raise ValueError("cannot find the pinned version of " + name)
        result.append((name, repo, "", match[1]))
    for _, _, _, current in result:
        version(current)
    return result


def github_client(token):
    """Return a cached, timeout-bounded reader of the public GitHub API."""
    @cache
    def fetch(path):
        headers = {"Accept": "application/vnd.github+json", "User-Agent": "kurtosis-avalanche-version-watch"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = Request("https://api.github.com" + path, headers=headers)
        with urlopen(request, timeout=20) as response:
            return json.load(response)
    return fetch


def latest_release(repo, prefix, fetch):
    """Find a stable release, including component-prefixed ICM release tags."""
    base = "/repos/" + repo + "/releases"
    if not prefix:
        release = fetch(base + "/latest")
        tag = release["tag_name"]
        if release["draft"] or release["prerelease"]:
            raise ValueError("latest release is a draft or prerelease")
        version(tag)
        return tag

    candidates = []
    page = 1
    while True:
        releases = fetch(base + "?per_page=100&page=" + str(page))
        for release in releases:
            tag = release["tag_name"]
            if release["draft"] or release["prerelease"] or not tag.startswith(prefix):
                continue
            try:
                number = version(tag.removeprefix(prefix))
            except ValueError:
                continue
            candidates.append((number, tag))
        if len(releases) < 100:
            break
        page += 1
    if not candidates:
        raise ValueError("no stable release with prefix " + prefix)
    return max(candidates)[1]


def report(current_pins, fetch):
    """Return a Markdown report and errors; updates produce workflow warnings."""
    lines = ["# Upstream version watch", "", "Pins remain unchanged. Review compatibility before upgrading.", "",
             "| Component | Pinned | Latest stable | Status |", "| --- | --- | --- | --- |"]
    errors = []
    for name, repo, prefix, current in current_pins:
        try:
            tag = latest_release(repo, prefix, fetch)
            latest = tag.removeprefix(prefix) if prefix else tag
            comparison = (version(latest) > version(current)) - (version(latest) < version(current))
            status = {1: "Update available", 0: "Current", -1: "Pinned newer than latest release"}[comparison]
            link = "https://github.com/" + repo + "/releases/tag/" + quote(tag, safe="")
            lines.append(f"| {name} | {current} | [{latest}]({link}) | {status} |")
            if comparison > 0:
                print(f"::warning title=Version watch::{name}: {current} -> {latest}")
        except (HTTPError, URLError, TimeoutError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            errors.append(f"{name}: {error}")
            lines.append(f"| {name} | {current} | Unavailable | Check failed |")
    if errors:
        lines.extend(["", "Upstream checks failed:", ""] + ["- " + error for error in errors])
    return "\n".join(lines) + "\n", errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="also write the Markdown report to this file")
    args = parser.parse_args()
    try:
        current_pins = pins(ROOT)
    except (OSError, ValueError) as error:
        errors = [str(error)]
        text = "# Upstream version watch\n\nCould not read pinned versions: " + str(error) + "\n"
    else:
        text, errors = report(current_pins, github_client(os.environ.get("GITHUB_TOKEN")))
    print(text)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            output.write(text)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
