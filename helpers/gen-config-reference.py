#!/usr/bin/env python3
"""Generate the option references in docs/config/ from the pinned AvalancheGo.

    python3 helpers/gen-config-reference.py [--avalanchego ../avalanchego]

Run it after a change to the node images, to MANAGED_NODE_FLAGS, or to
DEFAULT_NODE_CONFIG. It writes:

    docs/config/node.yml      AvalancheGo flags, from `avalanchego --help` of the
                              pinned image. The binary is the complete source;
                              the upstream config.md misses flags.
    docs/config/l1-chain.yml  Subnet-EVM chain config
    docs/config/c-chain.yml   C-Chain chain config

The chain configs come from an AvalancheGo checkout, read at the commit of the
pinned image: the options and their types from the JSON tags of config.go, the
descriptions from config.md. The other files in docs/config/ are written by
hand.
"""

import argparse
import ast
import pathlib
import re
import subprocess
import textwrap

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/config"
WIDTH = 78


def starlark_constant(path, name):
    """Returns a module-level literal of a Starlark file."""
    for node in ast.parse((ROOT / path).read_text()).body:
        if isinstance(node, ast.Assign) and ast.unparse(node.targets[0]) == name:
            return ast.literal_eval(node.value)
    raise KeyError(name)


def comment(text, indent):
    """Wraps prose into comment lines."""
    prefix = " " * indent + "# "
    return textwrap.wrap(
        text, WIDTH, initial_indent=prefix, subsequent_indent=prefix, break_long_words=False
    )


def clean(text):
    """Turns a Markdown table cell into plain text."""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)  # [text](url) -> text
    text = re.sub(r"<br\s*/?>", " ", text)
    text = text.replace("**", "").replace("⚠️", "").replace("\\|", "|").replace("`", "")
    return re.sub(r"\s+", " ", text).strip()


def rule(title, indent):
    line = " " * indent + "# ── " + title + " "
    return line + "─" * max(3, WIDTH - len(line))


# ── AvalancheGo node flags ───────────────────────────────────────────────────

# Sections of node.yml: (title, introduction, flag prefixes or exact names).
# A flag goes into the first section that matches it.
NODE_SECTIONS = [
    (
        "Network, files, and directories",
        "Which network the node joins and where it keeps its files.",
        ["network-id", "genesis-", "upgrade-", "data-dir", "config-", "plugin-dir",
         "vm-aliases-", "chain-", "subnet-config-", "process-context-file", "version",
         "fd-limit"],
    ),
    (
        "APIs and HTTP server",
        "The HTTP server exposes the node APIs and the RPC API of every chain.",
        ["api-", "http-", "index-"],
    ),
    ("Logging", "", ["log-"]),
    (
        "Node identity",
        "A TLS key pair gives the node its node ID. A BLS key signs Warp messages.",
        ["staking-", "sybil-protection-"],
    ),
    (
        "Bootstrapping and sync",
        "How a new node finds the network and which chains it syncs.",
        ["bootstrap-", "state-sync-", "partial-sync-primary-network", "track-subnets"],
    ),
    ("Peer-to-peer network", "", ["network-", "public-ip"]),
    (
        "Message throttling",
        "Limits on the CPU, disk, and bandwidth that one peer can use.",
        ["throttler-"],
    ),
    (
        "Consensus",
        "Snowman consensus parameters. An L1 can override the snow-* values for "
        "its own chain in its subnet config (docs/config/l1-subnet.yml).",
        ["snow-", "consensus-", "simplex-", "proposervm-"],
    ),
    (
        "Primary Network staking",
        "Rules for validators and delegators of the Primary Network. They do not "
        "apply to L1 validators; the ValidatorManager contract of an L1 sets those.",
        ["min-", "max-", "stake-", "helicon-", "uptime-"],
    ),
    (
        "Transaction fees",
        "Fees of the P-Chain and X-Chain. The validator-fees-* flags set the "
        "continuous fee that every L1 validator pays to the P-Chain in AVAX.",
        ["tx-fee", "create-asset-tx-fee", "dynamic-fees-", "validator-fees-"],
    ),
    ("Health and benchlist", "", ["health-", "benchlist-", "router-"]),
    ("Database", "", ["db-"]),
    ("Resource tracking", "", ["system-tracker-", "meter-vms-enabled"]),
    ("Profiling and tracing", "", ["profile-", "tracing-"]),
    ("Avalanche Community Proposals", "", ["acp-"]),
    ("Other", "", [""]),
]

FLAG_LINE = re.compile(
    r"^\s+--(?P<name>[a-z0-9-]+)(?: (?P<type>[A-Za-z0-9]+))?\s{2,}(?P<usage>.*?)"
    r"(?: \(default (?P<default>.*)\))?$"
)

# Flags whose default in `avalanchego --help` needs an explanation.
_ALIASES = "The file is optional at the default path, but it must exist when the flag is set."
NODE_NOTES = {
    "chain-aliases-file": _ALIASES,
    "vm-aliases-file": _ALIASES,
    "network-allow-private-ips": "On this devnet the default is true. Do not set false: every node has a private IP address.",
    "snow-quorum-size": "Not set by default. When set, it replaces both snow-preference-quorum-size and snow-confidence-quorum-size.",
    "max-stake-duration": "Keep at least 87600h: the genesis validators of this devnet stake for ten years.",
    "stake-minting-period": "Must be at least max-stake-duration.",
    "throttler-inbound-cpu-validator-alloc": "The default is the number of CPUs of the machine. The line shows it for 8 CPUs.",
    "throttler-inbound-cpu-max-non-validator-usage": "The default is 0.8 times the number of CPUs. The line shows it for 8 CPUs.",
    "throttler-inbound-cpu-max-non-validator-node-usage": "The default is the number of CPUs divided by 8. The line shows it for 8 CPUs.",
}

# Flags whose default depends on the network ID or on the machine: the value
# that the reference shows. It must not change with the machine that runs
# this script.
NODE_FIXED_DEFAULTS = {
    "network-allow-private-ips": "true",
    "throttler-inbound-cpu-validator-alloc": "8",
    "throttler-inbound-cpu-max-non-validator-usage": "6.4",
    "throttler-inbound-cpu-max-non-validator-node-usage": "1",
}

# Deprecated flags. AvalancheGo still accepts them, but `--help` hides them.
NODE_HIDDEN_FLAGS = [
    "system-tracker-disk-required-available-space",
    "system-tracker-disk-warning-threshold-available-space",
]

# Spelling mistakes in the help text of the pinned release.
UPSTREAM_TYPOS = {"Oterhwise": "Otherwise"}

# pflag prints no default for a zero value.
ZERO_VALUES = {"bool": "false", "string": '""', "strings": "[]", "ints": "[]", "duration": '"0s"'}


def yaml_scalar(kind, default):
    """Returns a flag default as a YAML value."""
    if kind == "stringToString":
        return "{}"
    if default is None:
        return ZERO_VALUES.get(kind, "0")
    if kind in ("bool", "int", "uint", "float"):
        return default
    if kind in ("strings", "ints"):
        return default if default.startswith("[") else "[{}]".format(default)
    return '"{}"'.format(default.strip('"'))


def node_reference(image, version):
    usage = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "/avalanchego/build/avalanchego", image, "--help"],
        check=True, capture_output=True, text=True,
    )
    flags = []
    for line in (usage.stdout + usage.stderr).splitlines():
        match = FLAG_LINE.match(line)
        if match:
            flags.append(match.groupdict())
        elif line.lstrip().startswith("--"):
            raise SystemExit("cannot parse flag: " + line)
    managed = set(starlark_constant("src/config/sanity_check.star", "MANAGED_NODE_FLAGS"))
    package_defaults = starlark_constant("src/config/input_parser.star", "DEFAULT_NODE_CONFIG")
    unknown = (managed | set(package_defaults)) - {flag["name"] for flag in flags}
    if unknown:
        raise SystemExit("flags unknown to {}: {}".format(version, sorted(unknown)))

    lines = [
        "# AvalancheGo node flags ({}): all {} of them.".format(version, len(flags)),
        "#",
        "# This file is a reference, not an arguments file. To set a flag, copy its",
        "# line into your arguments file and remove the `#`. Set it under:",
        "#",
        "#   node_config                    for every node",
        "#   primary_network.node_config    for the Primary Network validators",
        "#   l1.node_config                 for the L1 validators and RPC nodes",
        "#",
        "# A later level takes precedence. The value on each line is the AvalancheGo",
        '# default. A flag that is "not set by default" needs a real value when you',
        '# turn it on. "Package default" marks a value that this package changes',
        "# (DEFAULT_NODE_CONFIG in src/config/input_parser.star). The package sets the",
        '# flags marked "managed" itself and rejects an override (MANAGED_NODE_FLAGS in',
        "# src/config/sanity_check.star).",
        "#",
        "# The list is the output of `avalanchego --help`. It leaves out two",
        "# deprecated flags that AvalancheGo still accepts:",
    ] + ["#   " + flag for flag in NODE_HIDDEN_FLAGS] + [
        "#",
        "# Generated by helpers/gen-config-reference.py. Do not edit.",
        "node_config:",
    ]
    remaining = list(flags)
    for title, introduction, prefixes in NODE_SECTIONS:
        section = [f for f in remaining if any(f["name"].startswith(p) for p in prefixes)]
        remaining = [f for f in remaining if f not in section]
        if not section:
            continue
        lines += ["", rule(title, 2)]
        if introduction:
            lines += comment(introduction, 2)
        for flag in section:
            kind = flag["type"] or "bool"
            value = NODE_FIXED_DEFAULTS.get(flag["name"], yaml_scalar(kind, flag["default"]))
            usage = flag["usage"]
            for typo, word in UPSTREAM_TYPOS.items():
                usage = usage.replace(typo, word)
            lines.append("")
            lines += comment(usage.rstrip(".") + ".", 2)
            if flag["name"] in managed:
                lines.append("  # Type: {}. Managed by the package.".format(kind))
                lines.append("  # {} (managed)".format(flag["name"]))
                continue
            note = "  # Type: {}.".format(kind)
            if flag["name"] in package_defaults:
                package_value = package_defaults[flag["name"]]
                if isinstance(package_value, bool):
                    package_value = str(package_value).lower()
                note += " Package default: {}.".format(package_value)
            if value in ('""', "[]", "{}"):
                note += " Not set by default."
            lines.append(note)
            if flag["name"] in NODE_NOTES:
                lines += comment(NODE_NOTES[flag["name"]], 2)
            lines.append("  #{}: {}".format(flag["name"], value))
    return "\n".join(lines) + "\n"


# ── EVM chain configs ────────────────────────────────────────────────────────

TABLE_ROW = re.compile(r"^\|\s*`(?P<name>[A-Za-z0-9-]+)`\s*\|(?P<cells>.*)\|\s*$")
STRUCT_FIELD = re.compile(r'^\s*(\w+)\s+(\S+)\s+`json:"([A-Za-z0-9-]+)')
DURATION_UNITS = {"Millisecond": 10**6, "Second": 10**9, "Minute": 60 * 10**9, "Hour": 3600 * 10**9}
# Go constants that default_config.go uses in arithmetic.
GO_CONSTANTS = {"utils.GWei": 10**9}
GO_CONSTANTS.update({"time." + unit: size for unit, size in DURATION_UNITS.items()})
GO_TYPE_NAMES = {
    "Duration": "duration",
    "set.Set[rpc.API]": "list of strings",
    "[]hexutil.Bytes": "list of hex strings",
    "gas.Price": "uint64",
    "PBool": "bool",
    "gas.Gas": "uint64",
    "[]string": "list of strings",
    "[]common.Hash": "list of hashes",
    "[]common.Address": "list of addresses",
    "set.Set[ids.NodeID]": "list of node IDs",
}


def go_defaults(source):
    """Returns {field: value} of the struct literal in default_config.go.

    A value is a bool, number, string, list of strings, or ("duration", ns).
    """
    constants = {name: int(value) for name, value in re.findall(r"const (\w+) = (\d+)", source)}
    body = source[source.index("return Config{") + len("return Config{") :]
    # Split the literal into its top-level `Field: expression,` entries.
    entries, depth, current = [], 0, ""
    for line in body.splitlines():
        line = line.split("//")[0] if "://" not in line else re.sub(r"\s//\s.*", "", line)
        current += line.strip()
        depth += line.count("{") + line.count("(") - line.count("}") - line.count(")")
        if depth < 0:
            break
        if depth == 0 and current:
            entries.append(current.rstrip(","))
            current = ""
    defaults = {}
    for entry in entries:
        field, _, expression = entry.partition(":")
        expression = expression.strip()
        if expression.startswith("[]"):
            defaults[field] = re.findall(r'"([^"]*)"', expression)
        elif expression.startswith('"'):
            defaults[field] = expression.strip('"')
        elif expression in ("true", "false"):
            defaults[field] = expression == "true"
        elif re.fullmatch(r"\w+\.Name", expression):  # for example pebbledb.Name
            defaults[field] = expression.split(".")[0]
        else:
            is_duration = expression.startswith("timeToDuration(")
            for name, value in {**constants, **GO_CONSTANTS}.items():
                expression = re.sub(r"\b{}\b".format(re.escape(name)), str(value), expression)
            expression = re.sub(r"\b(timeToDuration|uint64)\(", "(", expression).replace("_", "")
            if not re.fullmatch(r"[\d\s.+*/()-]+", expression):
                raise SystemExit("cannot evaluate default: " + entry)
            value = eval(expression)  # Arithmetic on digits only; checked above.
            defaults[field] = ("duration", int(value)) if is_duration else value
    return defaults


def go_duration(nanoseconds):
    for unit, size in (("h", 3600 * 10**9), ("m", 60 * 10**9), ("s", 10**9), ("ms", 10**6)):
        if nanoseconds and nanoseconds % size == 0:
            return "{}{}".format(nanoseconds // size, unit)
    return "0s"


def chain_default(go_type, value):
    """Returns (text for the comment, YAML value or None) of an option default."""
    if isinstance(value, tuple):
        text = go_duration(value[1])
        return text, '"{}"'.format(text)
    if isinstance(value, bool):
        return str(value).lower(), str(value).lower()
    if isinstance(value, list):
        text = "[{}]".format(", ".join('"{}"'.format(item) for item in value))
        return text, text
    if isinstance(value, str):
        return '"{}"'.format(value), '"{}"'.format(value)
    if isinstance(value, (int, float)):
        number = int(value) if float(value).is_integer() else value
        return "{:,}".format(number) if isinstance(number, int) else str(number), str(number)
    # No entry in default_config.go: the Go zero value.
    if go_type.startswith("*"):
        return "not set", None
    if go_type in ("bool", "PBool"):
        return "false", "false"
    if go_type == "string":
        return '""', '""'
    if go_type == "Duration":
        return "0s", '"0s"'
    if go_type.startswith("[]") or go_type.startswith("set."):
        return "[]", "[]"
    return "0", "0"


def markdown_default(go_type, cell, apis):
    """Returns (comment text, YAML value or None) for a default from config.md."""
    cell = cell.strip('"')
    if cell.startswith("every API"):
        return "every API that is on by default", "[{}]".format(
            ", ".join('"{}"'.format(api) for api in apis)
        )
    if cell in ("true", "false") or re.fullmatch(r"\d+", cell):
        if go_type == "duration":
            return "0s" if cell == "0" else cell, '"0s"' if cell == "0" else '"{}"'.format(cell)
        return cell, cell
    if cell == "empty array":
        return "[]", "[]"
    if go_type == "string":
        return '"{}"'.format(cell), '"{}"'.format(cell)
    return cell[0].lower() + cell[1:], None  # Prose, for example "parent block's target".


def chain_reference(
    checkout, commit, directory, header, args_path, package_values, defaults_in_go=True,
    effective_defaults={},
):
    def show(file):
        path = "{}/{}".format(directory, file)
        result = subprocess.run(
            ["git", "-C", str(checkout), "show", "{}:{}".format(commit, path)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise SystemExit(
                "{} lacks {} at {}; fetch the release tags".format(checkout, path, commit)
            )
        return result.stdout

    # config.go lists the options and their types. config.md describes them.
    fields = {}
    for line in show("config.go").splitlines():
        match = STRUCT_FIELD.match(line)
        if match:
            fields[match[3]] = (match[1], match[2])
    markdown = show("config.md")
    if defaults_in_go:
        # Subnet-EVM: default_config.go is exact; the defaults in config.md are not.
        defaults = go_defaults(show("default_config.go"))
        unused = set(defaults) - {field for field, _ in fields.values()}
        if unused:
            raise SystemExit("defaults without an option: {}".format(sorted(unused)))
    # C-Chain: the names of the JSON-RPC APIs that are on by default.
    apis = re.findall(r"^\| `(\w+)` \| enabled \|", markdown, re.M)

    lines = header + ["#", "# Generated by helpers/gen-config-reference.py. Do not edit."]
    indent = 2 * len(args_path)
    for depth, key in enumerate(args_path):
        lines.append("  " * depth + key + ":")
    documented = set()
    pending_heading = None
    for line in markdown.splitlines():
        if line.startswith("#"):
            pending_heading = line.lstrip("# ").strip()
            continue
        match = TABLE_ROW.match(line)
        if not match or match["name"] not in fields or match["name"] in documented:
            continue
        name = match["name"]
        documented.add(name)
        # An escaped pipe belongs to the cell text.
        cells = match["cells"].replace("\\|", "\0").split("|")
        description = clean(cells[1].replace("\0", "|"))
        field, go_type = fields[name]
        if defaults_in_go:
            text, value = chain_default(go_type, defaults.get(field))
        else:
            text, value = markdown_default(go_type, clean(cells[2].replace("\0", "|")), apis)
        if name in effective_defaults:
            text = value = effective_defaults[name]
        if pending_heading:
            lines += ["", rule(pending_heading, indent)]
            pending_heading = None
        lines.append("")
        lines += comment(description.replace(", see Available APIs", "").rstrip(".") + ".", indent)
        if name == "apis":
            disabled = re.findall(r"^\| `(\w+)` \| disabled \|", markdown, re.M)
            lines += comment(
                "On by default: {}. Off by default: {}.".format(", ".join(apis), ", ".join(disabled)),
                indent,
            )
        go_type = go_type.lstrip("*")
        note = "Type: {}. Default: {}.".format(GO_TYPE_NAMES.get(go_type, go_type), text)
        if name in package_values:
            value, package_note = package_values[name]
            note += " " + package_note
        lines += comment(note, indent)
        lines.append("{}#{}:{}".format(" " * indent, name, " " + value if value else ""))
    missing = sorted(set(fields) - documented)
    if missing and defaults_in_go:
        raise SystemExit("{}/config.md does not describe {}".format(directory, missing))
    if missing:
        # The C-Chain config has options for tests that upstream does not document.
        print("{}: left out, no description upstream: {}".format(directory, ", ".join(missing)))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--avalanchego",
        type=pathlib.Path,
        default=ROOT.parent / "avalanchego",
        help="AvalancheGo checkout that contains the commit of the pinned image",
    )
    checkout = parser.parse_args().avalanchego
    image = starlark_constant("src/config/constants.star", "IMAGES")["avalanchego"]
    banner = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "/avalanchego/build/avalanchego", image, "--version"],
        check=True, capture_output=True, text=True,
    ).stdout
    found = re.search(r"avalanchego/([\d.]+) .*commit=([0-9a-f]+)", banner)
    if not found:
        raise SystemExit("unexpected version output: " + banner)
    version, commit = "v" + found[1], found[2]
    # The L1 nodes run the subnet_evm image. The references describe it only if
    # it is built from the same commit.
    l1_image = starlark_constant("src/config/constants.star", "IMAGES")["subnet_evm"]
    l1_banner = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "/avalanchego/build/avalanchego", l1_image, "--version"],
        check=True, capture_output=True, text=True,
    ).stdout
    if "commit=" + commit not in l1_banner:
        raise SystemExit("the subnet_evm image is not built from {}: {}".format(commit, l1_banner))
    warp = ("true", "Package default: true.")

    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "node.yml").write_text(node_reference(image, version))
    (OUTPUT / "l1-chain.yml").write_text(
        chain_reference(
            checkout, commit, "graft/subnet-evm/plugin/evm/config",
            [
                "# Subnet-EVM chain config ({}): how each node runs the L1 chain.".format(version),
                "#",
                "# This file is a reference, not an arguments file. To set an option, copy",
                "# its line into your arguments file under `l1.chain_config` and remove the",
                "# `#`. The value on each line is the Subnet-EVM default; a line without a",
                "# value is not set by default. The config applies to every node of the L1.",
                "# It tunes a node (APIs, caches, pruning, gossip), not the chain rules;",
                "# those are in the genesis (docs/config/l1-genesis.yml).",
            ],
            ["l1", "chain_config"], {"warp-api-enabled": warp},
            # default_config.go leaves the scheme empty, and empty selects hash.
            effective_defaults={"state-scheme": '"hash"'},
        )
    )
    (OUTPUT / "c-chain.yml").write_text(
        chain_reference(
            checkout, commit, "vms/saevm/cchain",
            [
                "# C-Chain chain config ({}).".format(version),
                "#",
                "# This file is a reference, not an arguments file. To set an option, copy",
                "# its line into your arguments file under `primary_network.c_chain_config`",
                "# and remove the `#`. The value on each line is the default; a line without",
                "# a value is not set by default.",
                "#",
                "# AvalancheGo {} holds two C-Chain VMs: Coreth for the blocks before the".format(version),
                "# Helicon upgrade, and the SAE VM for the blocks after it. Helicon is active",
                "# from the first block of this devnet, so the SAE VM runs the chain. It",
                "# knows only the options below. It ignores an option of the earlier Coreth",
                "# config and names it in a log warning. The one exception is `eth-apis`:",
                "# it is deprecated, and the SAE VM maps it to `apis`.",
                "#",
                "# On the first start, Coreth also reads this file once, before the SAE VM",
                "# takes over. Coreth ignores the options that it does not know.",
            ],
            ["primary_network", "c_chain_config"], {}, defaults_in_go=False,
        )
    )
    print("Wrote node.yml, l1-chain.yml, and c-chain.yml for AvalancheGo {} ({})".format(version, commit[:10]))


if __name__ == "__main__":
    main()
