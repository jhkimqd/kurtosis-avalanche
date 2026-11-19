#!/usr/bin/env python3
"""Generate the Grafana dashboards in static_files/observability/grafana/.

    python3 scripts/gen-dashboards.py            write the dashboard files
    python3 scripts/gen-dashboards.py --queries  print every query as JSON

The dashboards follow the Avalanche production dashboards: the L1 dashboard
(rows Consensus, System Usage, Chain Networking, EVM Block Processing, EVM Tx
Pool), the on-call triage dashboard (a grid of status numbers, then detail),
and the main node dashboard. Three things differ on a devnet:

- Labels. A node has `node`, `role`, and `l1` where production has `pod`,
  `component`, and a subnet name (see src/observability/alloy.star).
- Windows. Rates use `$__rate_interval`, which follows the 5 second scrape
  interval. Production uses 5 minutes, longer than many devnets live.
- Machine metrics. A devnet has no Kubernetes; CPU, memory, and disk come
  from the metrics of AvalancheGo itself.

Each panel is one call below: its title, a description for the (i) of the
panel, and its queries. Change a panel here, run this script, and commit the
JSON files; a test compares them. `--queries` feeds
scripts/check-observability.sh, which runs each query on a live devnet.
"""

import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "static_files/observability/grafana/dashboards"

# Every dashboard carries this tag; the link bar of each lists the others.
TAG = "kurtosis-avalanche"

PROMETHEUS = {"type": "prometheus", "uid": "${datasource}"}
LOKI = {"type": "loki", "uid": "${loki}"}

# Window of a rate in a graph, and in a status number (an instant query).
RATE = "$__rate_interval"
NOW = "1m"

# ── Selectors ────────────────────────────────────────────────────────────────

# Every node, for the overview.
NODE = 'job="avalanche", node=~"$node"'
# The nodes of the selected L1, and their metrics of the L1's own chain. An L1
# node also follows the P-Chain, and the node database reports chain "all".
L1_NODE = 'job="avalanche", l1=~"$l1", node=~"$node"'
L1_CHAIN = L1_NODE + ', chain!~"P|X|C|all"'
# The Primary Network validators and the selected chains of P, X, and C.
PRIMARY_NODE = 'job="avalanche", role="primary", node=~"$node"'
PRIMARY_CHAIN = PRIMARY_NODE + ', chain=~"$chain"'
# The EVM of an L1 (Subnet-EVM) and of the C-Chain.
L1_EVM = "avalanche_subnetevm_vm_eth_"
C_EVM = "avalanche_evm_eth_"
SAE = "avalanche_evm_transition_sae_"

# Consensus messages that a node handles, as in the production dashboard.
CONSENSUS_OPS = (
    "put|get_accepted_frontier|accepted_frontier|get_accepted|accepted|get_ancestors"
    "|ancestors|get|push_query|pull_query|chits|app_gossip|app_request|app_response"
)

# Values that stand in for the dashboard variables in `--queries`. The two
# long windows cover an idle devnet, which may log nothing for minutes.
RESOLVED = {
    "$__rate_interval": "1m",
    "$__interval": "24h",
    "$__range": "24h",
    "$node": ".*",
    "$l1": ".+",
    "$chain": "P|X|C",
    "$logger": ".*",
    "$level": ".*",
    "$search": "",
}


# ── Panels ───────────────────────────────────────────────────────────────────


class Dashboard:
    """Collects panels, lays them out on the 24 column grid, and numbers them."""

    def __init__(self, uid, title, description, variables, time_from="now-30m"):
        self.uid = uid
        self.title = title
        self.description = description
        self.variables = variables
        self.time_from = time_from
        self.panels = []
        self.queries = []
        self._next_id = 1
        self._row = None  # the collapsed row that takes the next panels
        self._x = self._y = self._height = 0

    def _place(self, panel, width, height):
        if self._x + width > 24:
            self._x = 0
            self._y += self._height
            self._height = 0
        panel["gridPos"] = {"h": height, "w": width, "x": self._x, "y": self._y}
        panel["id"] = self._next_id
        self._next_id += 1
        self._x += width
        self._height = max(self._height, height)
        (self._row["panels"] if self._row else self.panels).append(panel)

    def row(self, title, collapsed=False):
        """Starts a section. A collapsed section loads its panels when opened."""
        self._x, self._y, self._height = 0, self._y + self._height, 0
        row = {"type": "row", "title": title, "collapsed": collapsed, "panels": []}
        self._row = None
        self._place(row, 24, 1)
        self._row = row if collapsed else None
        self._x, self._y, self._height = 0, self._y + 1, 0

    def _panel(self, kind, title, description, targets, width, height, datasource, optional, requires):
        if not description:
            raise ValueError("panel '{}' needs a description".format(title))
        panel = {
            "type": kind,
            "title": title,
            "description": description,
            "datasource": datasource,
            "targets": [],
        }
        for index, target in enumerate(targets):
            expr, legend = target if isinstance(target, tuple) else (target, "")
            ref = chr(ord("A") + index)
            query = {"datasource": datasource, "expr": expr, "refId": ref}
            if datasource == PROMETHEUS:
                query.update({"editorMode": "code", "range": kind != "stat", "instant": kind == "stat"})
            if legend:
                query["legendFormat"] = legend
            panel["targets"].append(query)
            self.queries.append(
                {
                    "dashboard": self.uid,
                    "panel": title,
                    "datasource": datasource["type"],
                    # Loki answers a query for log lines only over a time range.
                    "range": kind == "logs",
                    "expr": resolve(expr),
                    "optional": optional,
                    "requires": requires,
                }
            )
        self._place(panel, width, height)
        return panel

    def graph(self, title, description, *targets, unit="short", bars=False, stack=False,
              minimum=None, maximum=None, width=8, optional=False, requires=None):
        """A time series with the style of the production dashboards.

        Args:
            targets: each a query, or a (query, legend) pair.
            optional: the query can be empty on a healthy devnet, for example
                a counter of failures that never happened.
            requires: the package argument that the panel needs, if any.
        """
        panel = self._panel("timeseries", title, description, targets, width, 7, PROMETHEUS, optional, requires)
        defaults = {
            "color": {"mode": "palette-classic"},
            "custom": {
                "drawStyle": "bars" if bars else "line",
                "lineInterpolation": "linear" if bars else "smooth",
                "lineWidth": 1,
                "fillOpacity": 60 if bars else (20 if stack else 0),
                "showPoints": "never",
                "spanNulls": True,
                "stacking": {"group": "A", "mode": "normal" if stack else "none"},
            },
            "unit": unit,
        }
        if minimum is not None:
            defaults["min"] = minimum
        if maximum is not None:
            defaults["max"] = maximum
        panel["fieldConfig"] = {"defaults": defaults, "overrides": []}
        panel["options"] = {
            "legend": {
                "calcs": ["min", "max", "mean", "lastNotNull"],
                "displayMode": "table",
                "placement": "bottom",
                "showLegend": True,
            },
            "tooltip": {"mode": "multi", "sort": "desc"},
        }
        return panel

    def number(self, title, description, expr, unit="short", steps=None, width=4,
               datasource=PROMETHEUS, optional=False, requires=None):
        """One status number, coloured by `steps` as [(colour, from value)]."""
        panel = self._panel("stat", title, description, [expr], width, 4, datasource, optional, requires)
        steps = steps or [("text", None)]
        panel["fieldConfig"] = {
            "defaults": {
                "color": {"mode": "thresholds"},
                "thresholds": {
                    "mode": "absolute",
                    "steps": [{"color": color, "value": value} for color, value in steps],
                },
                "unit": unit,
                "noValue": "no data",
            },
            "overrides": [],
        }
        panel["options"] = {
            "colorMode": "background" if len(steps) > 1 else "value",
            "graphMode": "none",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "textMode": "value",
        }
        return panel

    def timeline(self, title, description, expr, legend, width=24, requires=None):
        """One coloured bar per series: green while 1, red while 0."""
        panel = self._panel("state-timeline", title, description, [(expr, legend)], width, 8, PROMETHEUS, False, requires)
        panel["fieldConfig"] = {
            "defaults": {
                "color": {"mode": "thresholds"},
                "custom": {"fillOpacity": 80, "lineWidth": 0},
                "mappings": [
                    {
                        "type": "value",
                        "options": {
                            "0": {"text": "down", "color": "red", "index": 0},
                            "1": {"text": "up", "color": "green", "index": 1},
                        },
                    }
                ],
                "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]},
            },
            "overrides": [],
        }
        panel["options"] = {
            "legend": {"showLegend": False},
            "mergeValues": True,
            "rowHeight": 0.8,
            "showValue": "never",
            "tooltip": {"mode": "single"},
        }
        return panel

    def log_graph(self, title, description, *targets, width=12, stack=True):
        """A count of log lines over time, from Loki."""
        panel = self._panel("timeseries", title, description, targets, width, 7, LOKI, False, "logs")
        panel["fieldConfig"] = {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "custom": {
                    "drawStyle": "bars",
                    "fillOpacity": 60,
                    "lineWidth": 1,
                    "showPoints": "never",
                    "stacking": {"group": "A", "mode": "normal" if stack else "none"},
                },
                "unit": "short",
            },
            "overrides": [
                {
                    "matcher": {"id": "byName", "options": name},
                    "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}}],
                }
                for name, color in (("error", "red"), ("fatal", "dark-red"), ("warn", "orange"), ("info", "green"), ("debug", "blue"))
            ],
        }
        panel["options"] = {
            "legend": {"calcs": ["sum"], "displayMode": "table", "placement": "right", "showLegend": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
        }
        return panel

    def logs(self, title, description, expr, height=14):
        """Log lines, newest first."""
        panel = self._panel("logs", title, description, [expr], 24, height, LOKI, False, "logs")
        panel["options"] = {
            "dedupStrategy": "none",
            "enableLogDetails": True,
            "prettifyLogMessage": False,
            "showCommonLabels": False,
            "showLabels": False,
            "showTime": True,
            "sortOrder": "Descending",
            "wrapLogMessage": True,
        }
        return panel

    def json(self):
        return {
            "uid": self.uid,
            "title": self.title,
            "description": self.description,
            "tags": [TAG],
            "editable": True,
            "graphTooltip": 1,  # one crosshair across all panels
            "links": [
                {
                    "type": "dashboards",
                    "title": "Dashboards",
                    "tags": [TAG],
                    "asDropdown": False,
                    "includeVars": False,
                    "keepTime": True,
                    "targetBlank": False,
                }
            ],
            "panels": self.panels,
            "refresh": "10s",
            "schemaVersion": 39,
            "templating": {"list": self.variables},
            "time": {"from": self.time_from, "to": "now"},
            "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m", "5m"]},
            "timezone": "browser",
            "version": 1,
        }


def resolve(expr):
    """Returns the query with a value in place of each dashboard variable."""
    for variable, value in RESOLVED.items():
        expr = expr.replace(variable, value)
    return expr


# ── Variables ────────────────────────────────────────────────────────────────


def datasource_variable(name, kind, label):
    return {"name": name, "label": label, "type": "datasource", "query": kind, "current": {}, "hide": 0, "refresh": 1}


def query_variable(name, label, query, datasource=PROMETHEUS, multi=True):
    variable = {
        "name": name,
        "label": label,
        "type": "query",
        "datasource": datasource,
        "definition": query,
        "query": {"query": query, "refId": name} if datasource == PROMETHEUS else {"label": name, "stream": query, "type": 1},
        "refresh": 2,  # when the time range changes: nodes appear during setup
        "sort": 1,
        "multi": multi,
        "includeAll": multi,
    }
    if multi:
        variable.update({"allValue": ".*", "current": {"selected": True, "text": "All", "value": "$__all"}})
    return variable


def custom_variable(name, label, values):
    return {
        "name": name,
        "label": label,
        "type": "custom",
        "query": ",".join(values),
        "options": [{"text": value, "value": value, "selected": False} for value in values],
        "multi": True,
        "includeAll": True,
        "allValue": "|".join(values),
        "current": {"selected": True, "text": "All", "value": "$__all"},
    }


def text_variable(name, label):
    return {"name": name, "label": label, "type": "textbox", "query": "", "current": {"text": "", "value": ""}}


PROMETHEUS_VARIABLE = datasource_variable("datasource", "prometheus", "Datasource")


# ── Shared queries ───────────────────────────────────────────────────────────


def ratio(numerator, denominator, by, selector, window=RATE, scale=""):
    """Returns increase(numerator) / increase(denominator), summed by `by`."""
    return "sum by ({by}) (increase({n}{{{s}}}[{w}])) / sum by ({by}) (increase({d}{{{s}}}[{w}])){scale}".format(
        by=by, n=numerator, d=denominator, s=selector, w=window, scale=scale
    )


def zero_when_none(condition, population):
    """Counts the series that meet `condition`; 0 instead of nothing when none do.

    Nothing at all then means that the metric is missing, not that all is well.
    """
    return "count({}) or (count({}) * 0)".format(condition, population)


def consensus(board, selector, by, legend):
    """Adds the consensus panels of the production L1 dashboard."""
    s = selector

    def per(metric, function="increase", window=RATE):
        return "max by ({}) ({}({}{{{}}}[{}]))".format(by, function, metric, s, window)

    def gauge(metric):
        return "max by ({}) ({}{{{}}})".format(by, metric, s)

    chits = 'avalanche_handler_messages{{{}, op="chits"}}'.format(s)
    failed = 'avalanche_handler_messages{{{}, op="query_failed"}}'.format(s)
    board.graph(
        "Last Accepted Height",
        "The current block height: how many blocks have been finalized. A flat line means that the chain has no transactions, or that it stopped.",
        (gauge("avalanche_snowman_last_accepted_height"), legend),
    )
    board.graph(
        "Accepted Blocks",
        "Number of new blocks accepted (finalized) in each interval.",
        (per("avalanche_snowman_blks_accepted_count"), legend),
        bars=True,
    )
    board.graph(
        "Rejected Blocks",
        "Number of blocks that were proposed but ultimately rejected by consensus.",
        (per("avalanche_snowman_blks_rejected_count"), legend),
        bars=True,
    )
    board.graph(
        "Processing Blocks",
        "Number of blocks currently in flight: received and being evaluated, but not yet accepted or rejected. A growing number means the node is not finalizing blocks.",
        (gauge("avalanche_snowman_blks_processing"), legend),
    )
    board.graph(
        "Average Block Accept Latency",
        "The average time from when a block is first seen to when it is finalized.",
        (ratio("avalanche_snowman_blks_accepted_sum", "avalanche_snowman_blks_accepted_count", by, s, scale=" / 1e9"), legend),
        unit="s",
    )
    board.graph(
        "Reject Rate",
        "The ratio of rejected blocks to all decided blocks (accepted plus rejected).",
        (
            "sum by ({by}) (increase(avalanche_snowman_blks_rejected_count{{{s}}}[{w}])) / (sum by ({by}) (increase(avalanche_snowman_blks_rejected_count{{{s}}}[{w}])) + sum by ({by}) (increase(avalanche_snowman_blks_accepted_count{{{s}}}[{w}])))".format(by=by, s=s, w=RATE),
            legend,
        ),
        unit="percentunit",
        minimum=0,
        maximum=1,
    )
    board.graph(
        "Successful Polls",
        "The share of Snowman consensus polls that reached a successful outcome. It reads 100% while the chain is idle.",
        (
            "(sum by ({by}) (increase(avalanche_snowman_polls_successful{{{s}}}[{w}])) + 1) / (sum by ({by}) (increase(avalanche_snowman_polls_successful{{{s}}}[{w}])) + sum by ({by}) (increase(avalanche_snowman_polls_failed{{{s}}}[{w}])) + 1)".format(by=by, s=s, w=RATE),
            legend,
        ),
        unit="percentunit",
        minimum=0,
        maximum=1,
    )
    board.graph(
        "Successful Queries",
        "The share of consensus queries that received a valid response (chits) instead of a failure. A drop means that peers do not answer this node. It reads 100% while the chain is idle.",
        (
            "(sum by ({by}) (increase({c}[{w}])) + 1) / (sum by ({by}) (increase({c}[{w}])) + (sum by ({by}) (increase({f}[{w}])) or sum by ({by}) (increase({c}[{w}])) * 0) + 1)".format(by=by, c=chits, f=failed, w=RATE),
            legend,
        ),
        unit="percentunit",
        minimum=0,
        maximum=1,
    )
    board.graph(
        "Stake Benched",
        "The total weight of validators on the bench list: validators that this node excludes from consensus queries for a while, because they did not respond.",
        (gauge("avalanche_benchlist_benched_weight"), legend),
    )
    board.graph(
        "Validators Benched",
        "The number of validators currently benched.",
        (gauge("avalanche_benchlist_benched_num"), legend),
    )
    board.graph(
        "Polls per Accepted Block",
        "The average number of consensus rounds (polls) that finalize one block.",
        (
            "(sum by ({by}) (increase(avalanche_snowman_polls_successful{{{s}}}[{w}])) + sum by ({by}) (increase(avalanche_snowman_polls_failed{{{s}}}[{w}]))) / sum by ({by}) (increase(avalanche_snowman_blks_accepted_count{{{s}}}[{w}]))".format(by=by, s=s, w=RATE),
            legend,
        ),
    )
    board.graph(
        "Outstanding Polls",
        "The number of consensus polls in flight: started but not yet resolved.",
        (gauge("avalanche_snowman_polls"), legend),
    )
    board.graph(
        "Outstanding Block Requests",
        "The number of block fetch requests that were sent but not yet answered.",
        (gauge("avalanche_snowman_requests"), legend),
    )
    board.graph(
        "Pending Jobs",
        "Consensus jobs that wait to run: blocks that wait for an ancestor before they can be issued.",
        (gauge("avalanche_snowman_blocked"), legend),
    )
    board.graph(
        "Requests Failed",
        "Failed requests to peers, by kind. `query_failed` is a consensus query without an answer; the others fetch blocks or the frontier of the chain.",
        (
            'sum by (op) (increase(avalanche_handler_messages{{{}, op=~".+_failed"}}[{}]))'.format(s, RATE),
            "{{op}}",
        ),
        bars=True,
        optional=True,
    )
    board.graph(
        "Average Verification Time",
        "The average time to verify a block, successful and failed verifications together.",
        (ratio("avalanche_meterchainvm_verify_sum", "avalanche_meterchainvm_verify_count", by, s, scale=" / 1e9"), legend),
        unit="s",
    )
    board.graph(
        "Block Verifications Failed",
        "The number of blocks that failed verification.",
        (per("avalanche_meterchainvm_verify_err_count"), legend),
        bars=True,
    )
    board.graph(
        "Non-Verified Blocks Pinned In Memory",
        "The number of blocks that were received but not yet verified, held in memory.",
        (gauge("avalanche_snowman_non_verified_blks"), legend),
    )
    board.graph(
        "Blocks Built",
        "The number of blocks that this node proposed.",
        (per("avalanche_snowman_blks_built"), legend),
        bars=True,
    )
    board.graph(
        "Build Block Failures",
        "The number of times a node tried to build a block and failed.",
        (per("avalanche_snowman_blk_builds_failed"), legend),
        bars=True,
    )


# ── Dashboards ───────────────────────────────────────────────────────────────


def overview():
    board = Dashboard(
        "avalanche-overview",
        "Avalanche devnet: overview",
        "Is the devnet healthy? The top row counts what is wrong: 0 on green is good, a red number names how many nodes have the problem, and 'no data' means that the metric is not collected. The rows below show which node and since when. While the network deploys, a node that has not started yet counts as down.",
        [PROMETHEUS_VARIABLE, query_variable("node", "Node", 'label_values(up{job="avalanche"}, node)')],
    )
    bad = [("green", None), ("red", 1)]
    board.row("Status")
    board.number(
        "Nodes up",
        "Number of AvalancheGo nodes that answer the metrics scrape.",
        'count(up{job="avalanche"} == 1) or vector(0)',
        steps=[("red", None), ("green", 1)],
    )
    board.number(
        "Nodes down",
        "Number of nodes that do not answer the metrics scrape. During the deployment this counts the nodes that have not started yet.",
        zero_when_none('up{job="avalanche"} == 0', 'up{job="avalanche"}'),
        steps=bad,
    )
    board.number(
        "Support services down",
        "Number of ICM relayers and signature aggregators that do not answer the metrics scrape. They start late in the deployment.",
        zero_when_none('up{job!="avalanche"} == 0', 'up{job!="avalanche"}'),
        steps=bad,
    )
    board.number(
        "Unhealthy nodes",
        "Number of nodes with a failing health check. A node is unhealthy while it bootstraps, and when it loses its peers or falls behind.",
        zero_when_none(
            'max by (node) (avalanche_health_checks_failing{job="avalanche", check="health"}) >= 1',
            'avalanche_health_checks_failing{job="avalanche", check="health"}',
        ),
        steps=bad,
    )
    board.number(
        "Low stake connected",
        "Number of node and chain pairs that are connected to less than 85% of the stake of the chain. Such a node is cut off from the validators.",
        zero_when_none(
            'min by (node, chain) (avalanche_stake_percent_connected{job="avalanche"}) < 0.85',
            'avalanche_stake_percent_connected{job="avalanche"}',
        ),
        steps=bad,
    )
    board.number(
        "Stuck blocks",
        "Number of nodes with more than 50 blocks in processing. Such a node is not finalizing blocks.",
        zero_when_none(
            'max by (node) (avalanche_snowman_blks_processing{job="avalanche"}) > 50',
            'avalanche_snowman_blks_processing{job="avalanche"}',
        ),
        steps=bad,
    )
    board.number(
        "Failing queries",
        "Number of node and chain pairs whose consensus queries succeed less than 85% of the time. The peers of such a node do not answer it. An idle chain sends no queries and does not count.",
        zero_when_none(
            '(sum by (node, chain) (rate(avalanche_handler_messages{{job="avalanche", op="chits"}}[{w}])) / sum by (node, chain) (rate(avalanche_handler_messages{{job="avalanche", op=~"chits|query_failed"}}[{w}]))) < 0.85'.format(w=NOW),
            'avalanche_handler_messages{job="avalanche", op="chits"}',
        ),
        steps=bad,
    )
    board.number(
        "Stake benched",
        "Number of node and chain pairs that bench more than 8% of the stake. A node that benches many peers is often overloaded itself.",
        zero_when_none(
            '(max by (node, chain) (avalanche_benchlist_benched_weight{job="avalanche"}) / max by (node, chain) (avalanche_stake_total_weight{job="avalanche"})) > 0.08',
            'avalanche_benchlist_benched_weight{job="avalanche"}',
        ),
        steps=bad,
    )
    board.number(
        "L1 validators",
        "Number of active L1 validators that the P-Chain records, over all L1s.",
        'max(avalanche_platformvm_active_l1_validators{job="avalanche"})',
    )
    board.number(
        "Relayed messages",
        "Number of ICM messages that the relayers delivered since they started. Without `bridge` no relayer runs.",
        "sum(app_successful_relay_message_count) or vector(0)",
        requires="bridge",
    )
    board.number(
        "Bad blocks",
        "Number of blocks, over all EVM chains and nodes, that a node could not execute. Any bad block is serious: the node disagrees with the network.",
        'sum({__name__=~"avalanche_(evm|subnetevm_vm)_eth_chain_block_bad_count", job="avalanche"})',
        steps=bad,
    )
    board.number(
        "Metric series",
        "Number of metric series in Prometheus now. It grows with the number of nodes; the memory limits of Alloy and Prometheus follow the node count.",
        'count({job=~".+"})',
    )

    board.row("Chains")
    board.graph(
        "Last accepted height by chain",
        "Block height of each chain, the highest over all nodes. P, X, and C are the chains of the Primary Network; a long ID is the chain of an L1. An EVM chain builds a block only when it has transactions, so a flat line can be an idle chain.",
        ("max by (chain) (avalanche_snowman_last_accepted_height{{{}}})".format(NODE), "{{chain}}"),
    )
    board.graph(
        "Accepted blocks per second by chain",
        "Rate of finalized blocks of each chain.",
        ("max by (chain) (rate(avalanche_snowman_blks_accepted_count{{{}}}[{}]))".format(NODE, RATE), "{{chain}}"),
        unit="ops",
    )
    board.graph(
        "Time since the last accepted block",
        "Seconds since each chain finalized its last block. It grows while a chain is idle; that is normal on a devnet without transactions. Send transactions to see whether the chain still works. A chain without any block is not shown.",
        (
            # A chain without a block reports the time of its genesis.
            "time() - (max by (chain) (avalanche_snowman_last_accepted_timestamp{{{s}}}) and on (chain) max by (chain) (avalanche_snowman_last_accepted_height{{{s}}}) > 0)".format(s=NODE),
            "{{chain}}",
        ),
        unit="s",
    )
    board.graph(
        "Blocks in processing",
        "Blocks that each node evaluates but has not decided, by chain. It should return to 0.",
        ("max by (node, chain) (avalanche_snowman_blks_processing{{{}}})".format(NODE), "{{node}} {{chain}}"),
    )
    board.graph(
        "Stake connected",
        "The lowest share of stake that a node is connected to, by chain. Below 85% a node cannot finalize blocks reliably.",
        ("min by (chain) (avalanche_stake_percent_connected{{{}}})".format(NODE), "{{chain}}"),
        unit="percentunit",
        minimum=0,
        maximum=1,
    )
    board.graph(
        "Consensus queries failed",
        "Consensus queries without an answer, by chain. The line stays empty while every query is answered.",
        ('sum by (chain) (rate(avalanche_handler_messages{{{}, op="query_failed"}}[{}]))'.format(NODE, RATE), "{{chain}}"),
        unit="ops",
        optional=True,
    )

    board.row("Nodes")
    board.timeline(
        "Node availability",
        "Green while a node answers the metrics scrape, red while it does not. The deployment starts the nodes one group after another.",
        "up{{{}}}".format(NODE),
        "{{node}}",
    )
    board.graph(
        "Peers",
        "Number of peers that each node is connected to.",
        ("avalanche_network_peers{{{}}}".format(NODE), "{{node}}"),
    )
    board.graph(
        "Failing health checks",
        "Number of failing health checks of each node. Above 0 the node reports itself as unhealthy.",
        ('max by (node) (avalanche_health_checks_failing{{{}, check="health"}})'.format(NODE), "{{node}}"),
    )
    board.graph(
        "CPU",
        "CPU cores that each node uses: AvalancheGo and, on an L1 node, the Subnet-EVM plugin process.",
        ('sum by (node) (rate({{__name__=~"avalanche_(subnetevm_)?process_process_cpu_seconds_total", {}}}[{}]))'.format(NODE, RATE), "{{node}}"),
        unit="short",
        minimum=0,
    )
    board.graph(
        "Memory",
        "Resident memory of each node: AvalancheGo and, on an L1 node, the Subnet-EVM plugin process. The package limits a node to 1.5 GB.",
        ('sum by (node) ({{__name__=~"avalanche_(subnetevm_)?process_process_resident_memory_bytes", {}}})'.format(NODE), "{{node}}"),
        unit="bytes",
        minimum=0,
    )
    board.graph(
        "Goroutines",
        "Number of goroutines of AvalancheGo. A number that only grows points to a leak.",
        ("avalanche_process_go_goroutines{{{}}}".format(NODE), "{{node}}"),
    )

    board.row("Collection")
    board.graph(
        "Targets up by job",
        "Number of services of each kind that answer the scrape: `avalanche` (nodes), `icm-relayer`, and `signature-aggregator`.",
        ("sum by (job) (up)", "{{job}}"),
        minimum=0,
    )
    board.graph(
        "Scrape duration",
        "Time that Alloy needs to scrape each node. The scrape runs every 5 seconds and times out after 4.",
        ("scrape_duration_seconds{{{}}}".format(NODE), "{{node}}"),
        unit="s",
    )
    board.graph(
        "Samples per scrape",
        "Number of samples that each node returns in one scrape.",
        ("scrape_samples_scraped{{{}}}".format(NODE), "{{node}}"),
    )
    return board


def l1():
    board = Dashboard(
        "avalanche-l1",
        "Avalanche devnet: L1",
        "One Avalanche L1: its consensus, the resources of its nodes, its messages, and its EVM. It follows the production L1 dashboard. Every panel shows the chain of the selected L1 on the selected nodes.",
        [
            PROMETHEUS_VARIABLE,
            query_variable("l1", "L1", 'label_values(up{job="avalanche", l1!=""}, l1)'),
            query_variable("node", "Node", 'label_values(up{job="avalanche", l1=~"$l1"}, node)'),
        ],
    )
    chain, node, evm, legend = L1_CHAIN, L1_NODE, L1_EVM, "{{node}}"

    def evm_gauge(metric):
        return ("max by (node) ({}{}{{{}}})".format(evm, metric, chain), legend)

    def evm_rate(metric, function="rate"):
        return ("max by (node) ({}({}{}{{{}}}[{}]))".format(function, evm, metric, chain, RATE), legend)

    board.row("Consensus")
    consensus(board, chain, "node", legend)

    board.row("System Usage")
    board.graph(
        "CPU",
        "CPU cores that each node uses, split into AvalancheGo and the Subnet-EVM plugin process, which runs the EVM.",
        ("rate(avalanche_process_process_cpu_seconds_total{{{}}}[{}])".format(node, RATE), "{{node}} avalanchego"),
        ("rate(avalanche_subnetevm_process_process_cpu_seconds_total{{{}}}[{}])".format(chain, RATE), "{{node}} subnet-evm"),
        minimum=0,
    )
    board.graph(
        "Memory",
        "Resident memory of each node, split into AvalancheGo and the Subnet-EVM plugin process. The package limits a node to 1.5 GB in total.",
        ("avalanche_process_process_resident_memory_bytes{{{}}}".format(node), "{{node}} avalanchego"),
        ("avalanche_subnetevm_process_process_resident_memory_bytes{{{}}}".format(chain), "{{node}} subnet-evm"),
        unit="bytes",
        minimum=0,
    )
    board.graph(
        "CPU used by the chains",
        "CPU that the resource tracker of AvalancheGo attributes to message handling, in cores. AvalancheGo throttles peers by this number.",
        ("avalanche_resource_tracker_cpu_usage{{{}}}".format(node), legend),
        minimum=0,
    )
    board.graph(
        "Disk available",
        "Free space on the disk that holds the database of each node. All nodes of a devnet share the disk of the machine.",
        ("avalanche_resource_tracker_disk_available_space{{{}}}".format(node), legend),
        unit="bytes",
        minimum=0,
    )
    board.graph(
        "Disk reads and writes",
        "Bytes per second that each node reads from and writes to its disk.",
        ("avalanche_resource_tracker_disk_reads{{{}}}".format(node), "{{node}} read"),
        ("avalanche_resource_tracker_disk_writes{{{}}}".format(node), "{{node}} write"),
        unit="Bps",
    )
    board.graph(
        "Goroutines and open files",
        "Goroutines and open file descriptors of AvalancheGo.",
        ("avalanche_process_go_goroutines{{{}}}".format(node), "{{node}} goroutines"),
        ("avalanche_process_process_open_fds{{{}}}".format(node), "{{node}} files"),
    )

    board.row("Chain Networking")
    board.graph(
        "Messages Received Per Second",
        "Consensus and application messages that each node handles for the chain.",
        ('sum by (node) (rate(avalanche_handler_messages{{{}, op=~"{}"}}[{}]))'.format(chain, CONSENSUS_OPS, RATE), legend),
        unit="ops",
    )
    board.graph(
        "Messages by Kind",
        "The same messages by kind, over the selected nodes. `chits` answer a consensus query; `put` and `push_query` carry a block.",
        ('sum by (op) (rate(avalanche_handler_messages{{{}, op=~"{}"}}[{}]))'.format(chain, CONSENSUS_OPS, RATE), "{{op}}"),
        unit="ops",
        stack=True,
    )
    board.graph(
        "Unprocessed Messages",
        "Messages that wait in the queues of the chain. A queue that grows means that the node handles messages too slowly.",
        ("sum by (node) (avalanche_handler_sync_unprocessed_msgs_count{{{s}}}) + sum by (node) (avalanche_handler_async_unprocessed_msgs_count{{{s}}})".format(s=chain), legend),
    )
    board.graph(
        "Messages Deferred for CPU",
        "Rate of messages whose handling was deferred because their sender used too much CPU of this node.",
        ("sum by (node) (rate(avalanche_handler_sync_unprocessed_msgs_excessive_cpu{{{s}}}[{w}])) + sum by (node) (rate(avalanche_handler_async_unprocessed_msgs_excessive_cpu{{{s}}}[{w}]))".format(s=chain, w=RATE), legend),
        unit="ops",
    )
    board.graph(
        "Stake Connected",
        "Share of the stake of the L1 that each node is connected to.",
        ("avalanche_stake_percent_connected{{{}}}".format(chain), legend),
        unit="percentunit",
        minimum=0,
        maximum=1,
    )
    board.graph(
        "Peers",
        "Number of peers of each node, on the Primary Network and the L1 together.",
        ("avalanche_network_peers{{{}}}".format(node), legend),
    )

    board.row("EVM Block Processing")
    board.graph(
        "Share of Block Insert Time",
        "Where the EVM spends the time to insert a block, over the selected nodes: validation, state initialization, execution, trie operations, and writes.",
        *[
            (
                "sum (increase({e}{m}{{{s}}}[{w}])) / sum (increase({e}chain_block_inserts{{{s}}}[{w}]))".format(e=evm, m=metric, s=chain, w=RATE),
                name,
            )
            for metric, name in (
                ("chain_block_validations_content", "Block validation"),
                ("chain_block_inits_state", "Init state"),
                ("chain_block_executions", "Execution"),
                ("chain_block_trie", "Trie ops"),
                ("chain_block_validations_state", "State validation"),
                ("chain_block_writes", "Writes"),
            )
        ],
        unit="percentunit",
        stack=True,
    )
    board.graph(
        "Gas Per Block",
        "Average gas that one block uses.",
        ("max by (node) (increase({e}chain_block_gas_used_processed{{{s}}}[{w}])) / max by (node) (increase({e}chain_block_inserts_count{{{s}}}[{w}]))".format(e=evm, s=chain, w=RATE), legend),
    )
    board.graph("Gas Processed Per Second", "Gas that each node executes per second.", evm_rate("chain_block_gas_used_processed"))
    board.graph(
        "Nanoseconds Per Gas",
        "Time to verify blocks, divided by the gas they use. It compares the cost of execution between nodes and over time.",
        ("sum by (node) (rate(avalanche_meterchainvm_verify_sum{{{s}}}[{w}])) / sum by (node) (rate({e}chain_block_gas_used_processed{{{s}}}[{w}]))".format(e=evm, s=chain, w=RATE), legend),
        unit="ns",
    )
    board.graph(
        "Acceptor Queue Size",
        "Blocks that consensus accepted and that wait for the EVM to finish them: index the transactions and write the state.",
        evm_gauge("chain_acceptor_queue_size"),
    )
    board.graph(
        "Bad Blocks",
        "Blocks that a node could not execute. Any bad block is serious.",
        evm_rate("chain_block_bad_count", "increase"),
        bars=True,
    )

    board.row("EVM Tx Pool")
    board.graph(
        "Transactions Per Second",
        "Transactions that each node executes per second.",
        evm_rate("chain_txs_processed"),
        unit="ops",
    )
    board.graph(
        "Pending Transactions",
        "Transactions in the pool that can go into the next block.",
        evm_gauge("txpool_pending"),
    )
    board.graph(
        "Queued Transactions",
        "Transactions in the pool that wait for an earlier nonce of their sender.",
        evm_gauge("txpool_queued"),
    )
    board.graph("Tx Pool Slots", "Slots of the transaction pool in use. One slot holds 32 KB.", evm_gauge("txpool_slots"))
    board.graph(
        "Transactions Admitted and Rejected",
        "Transactions that the pool accepted as valid, rejected as invalid, or rejected because their fee was too low.",
        ("sum (increase({}txpool_valid{{{}}}[{}]))".format(evm, chain, RATE), "valid"),
        ("sum (increase({}txpool_invalid{{{}}}[{}]))".format(evm, chain, RATE), "invalid"),
        ("sum (increase({}txpool_underpriced{{{}}}[{}]))".format(evm, chain, RATE), "underpriced"),
        bars=True,
    )
    board.graph(
        "RPC Requests Per Second",
        "Requests to the EVM RPC API of each node, and the ones that failed.",
        ("max by (node) (rate({}rpc_requests{{{}}}[{}]))".format(evm, chain, RATE), "{{node}} requests"),
        ("max by (node) (rate({}rpc_failure{{{}}}[{}]))".format(evm, chain, RATE), "{{node}} failed"),
        unit="reqps",
    )

    board.row("EVM DB", collapsed=True)
    board.graph("TrieDB Dirty Size", "Size of the trie nodes that are in memory and not yet written to disk.", evm_gauge("hashdb_memcache_dirty_size"), unit="bytes")
    board.graph("TrieDB Dirty Nodes", "Number of trie nodes that are in memory and not yet written to disk.", evm_gauge("hashdb_memcache_dirty_nodes"))
    board.graph("Memcache Flush Bytes", "Bytes of trie nodes that were flushed from memory to disk to stay under the memory limit.", evm_rate("hashdb_memcache_flush_bytes", "increase"), unit="bytes")
    board.graph("Commit Bytes", "Bytes of trie nodes that were committed to disk with a block.", evm_rate("hashdb_memcache_commit_bytes", "increase"), unit="bytes")
    board.graph(
        "Trie Memcache Clean Hit Rate",
        "Share of reads of clean trie nodes that the memory cache answered.",
        ("sum by (node) (rate({e}hashdb_memcache_clean_hit{{{s}}}[{w}])) / (sum by (node) (rate({e}hashdb_memcache_clean_hit{{{s}}}[{w}])) + sum by (node) (rate({e}hashdb_memcache_clean_miss{{{s}}}[{w}])))".format(e=evm, s=chain, w=RATE), legend),
        unit="percentunit",
    )
    board.graph(
        "Snapshot Account Hit Rate",
        "Share of account reads that the state snapshot answered from its clean cache.",
        ("sum by (node) (rate({e}state_snapshot_clean_account_hit{{{s}}}[{w}])) / (sum by (node) (rate({e}state_snapshot_clean_account_hit{{{s}}}[{w}])) + sum by (node) (rate({e}state_snapshot_clean_account_miss{{{s}}}[{w}])))".format(e=evm, s=chain, w=RATE), legend),
        unit="percentunit",
    )

    board.row("Chain State Cache", collapsed=True)
    for cache, title in (("decided", "Decided"), ("missing", "Missing"), ("bytes_to_id", "Bytes to ID"), ("unverified", "Unverified")):
        metric = "avalanche_subnetevm_vm_chain_state_{}_cache_get_count".format(cache)
        board.graph(
            "{} Block Cache Hit Ratio".format(title),
            "Share of lookups in the cache of {} blocks that found their block.".format(title.lower()),
            ('sum by (node) (increase({m}{{{s}, result="hit"}}[{w}])) / sum by (node) (increase({m}{{{s}}}[{w}]))'.format(m=metric, s=chain, w=RATE), legend),
            unit="percentunit",
            width=6,
            # A cache that never had a hit has no series for hits.
            optional=True,
        )

    board.row("Bootstrapping", collapsed=True)
    board.graph("Bootstrap Finished", "1 once a node has caught up with the chain and takes part in consensus.", ("avalanche_snowman_bootstrap_finished{{{}}}".format(chain), legend))
    board.graph("Bootstrapping Fetched Blocks", "Blocks that a node fetched from its peers while it caught up.", ("avalanche_snowman_bs_fetched{{{}}}".format(chain), legend))
    board.graph(
        "Blocks per Get Ancestors",
        "Average number of blocks in one answer to a request for the ancestors of a block.",
        ("avalanche_snowman_get_ancestors_blks_sum{{{s}}} / (avalanche_snowman_get_ancestors_blks_count{{{s}}} + 1)".format(s=chain), legend),
    )
    return board


def primary_network():
    board = Dashboard(
        "avalanche-primary-network",
        "Avalanche devnet: Primary Network",
        "The Primary Network validators and their three chains: the P-Chain (staking, validator sets, and the registry of every L1), the X-Chain (assets), and the C-Chain (EVM contracts).",
        [
            PROMETHEUS_VARIABLE,
            custom_variable("chain", "Chain", ["P", "X", "C"]),
            query_variable("node", "Node", 'label_values(up{job="avalanche", role="primary"}, node)'),
        ],
    )
    node, legend = PRIMARY_NODE, "{{node}}"

    board.row("Consensus")
    consensus(board, PRIMARY_CHAIN, "node, chain", "{{node}} {{chain}}")

    board.row("P-Chain")
    board.graph(
        "Total Staked",
        "AVAX staked on the Primary Network, as the P-Chain records it.",
        ('max(avalanche_platformvm_total_staked{{{}, chain="P"}}) / 1e9'.format(node), "AVAX"),
    )
    board.graph(
        "Validators",
        "Number of validators of each chain, as each node sees it.",
        ("max by (chain) (avalanche_stake_num_validators{{{}}})".format(PRIMARY_CHAIN), "{{chain}}"),
    )
    board.graph(
        "Active L1 Validators",
        "Number of active validators of all L1s, as the P-Chain records it. The setup of a Proof of Stake L1 adds its staked validators and then removes the bootstrap validators.",
        ('max(avalanche_platformvm_active_l1_validators{{{}, chain="P"}})'.format(node), "validators"),
    )
    board.graph(
        "Accepted Blocks by Type",
        "P-Chain blocks that were accepted, by block type.",
        ('max by (blk) (increase(avalanche_platformvm_blks_accepted{{{}, chain="P"}}[{}]))'.format(node, RATE), "{{blk}}"),
        bars=True,
        stack=True,
    )
    board.graph(
        "Accepted Transactions by Type",
        "P-Chain transactions that were accepted, by type. The deployment sends the transactions that create each L1 and register its validators.",
        ('max by (tx) (increase(avalanche_platformvm_txs_accepted{{{}, chain="P"}}[{}]))'.format(node, RATE), "{{tx}}"),
        bars=True,
        stack=True,
    )
    board.graph(
        "Node Uptime",
        "Uptime of each validator as its peers report it, weighted by their stake. A validator earns its reward above 80%.",
        ("avalanche_network_node_uptime_weighted_average{{{}}}".format(node), legend),
        unit="percent",
    )

    board.row("C-Chain")
    board.graph(
        "Accepted, Executed, and Settled Height",
        "The C-Chain executes blocks after consensus accepted them (streaming asynchronous execution). Accepted is the consensus height, executed is how far execution got, and settled is the height whose results a later block has recorded.",
        ('max(avalanche_snowman_last_accepted_height{{{}, chain="C"}})'.format(node), "accepted"),
        ("max({}last_executed_height{{{}}})".format(SAE, node), "executed"),
        ("max({}last_settled_height{{{}}})".format(SAE, node), "settled"),
    )
    board.graph(
        "Execution Queue",
        "Accepted blocks that wait for execution. A queue that grows means that execution is slower than consensus.",
        ("max by (node) ({}execution_queue_blocks{{{}}})".format(SAE, node), legend),
    )
    board.graph(
        "Block Execution Time",
        "Average time to execute one block.",
        ("sum by (node) (rate({m}_sum{{{s}}}[{w}])) / sum by (node) (rate({m}_count{{{s}}}[{w}]))".format(m=SAE + "execute_block_duration_seconds", s=node, w=RATE), legend),
        unit="s",
    )
    board.graph(
        "Gas Charged Per Second",
        "Gas that executed transactions were charged, per second.",
        ("max by (node) (rate({}executed_gas_charged_total{{{}}}[{}]))".format(SAE, node, RATE), legend),
    )
    board.graph(
        "Base Fee",
        "Base fee of the last executed block, in wei per gas.",
        ("max by (node) ({}executed_base_fee{{{}}})".format(SAE, node), legend),
    )
    board.graph(
        "Transaction Pool",
        "Transactions in the C-Chain pool: pending ones can go into the next block, queued ones wait for an earlier nonce.",
        ("max({}txpool_pending{{{}}})".format(C_EVM, node), "pending"),
        ("max({}txpool_queued{{{}}})".format(C_EVM, node), "queued"),
    )

    board.row("Network")
    board.graph("Peers", "Number of peers that each validator is connected to.", ("avalanche_network_peers{{{}}}".format(node), legend))
    board.graph(
        "Messages Per Second",
        "Network messages that the validators send and receive, over the selected nodes.",
        ("sum by (io) (rate(avalanche_network_msgs{{{}}}[{}]))".format(node, RATE), "{{io}}"),
        unit="ops",
    )
    board.graph(
        "Bytes Per Second",
        "Network bytes that the validators send and receive, over the selected nodes.",
        ("sum by (io) (rate(avalanche_network_msgs_bytes{{{}}}[{}]))".format(node, RATE), "{{io}}"),
        unit="Bps",
    )
    board.graph(
        "Request Latency",
        "Average time until a peer answers a request of this node.",
        ("avalanche_requests_average_latency{{{}}} / 1e9".format(node), legend),
        unit="s",
    )
    board.graph(
        "Send Failure Rate",
        "Share of messages that a node could not send, as a moving average.",
        ("avalanche_network_send_fail_rate{{{}}}".format(node), legend),
        unit="percentunit",
    )
    board.graph(
        "Disconnects",
        "Number of times a node lost the connection to a peer.",
        ("increase(avalanche_network_times_disconnected{{{}}}[{}])".format(node, RATE), legend),
        bars=True,
    )

    board.row("Node")
    board.graph(
        "CPU",
        "CPU cores that each validator uses.",
        ("rate(avalanche_process_process_cpu_seconds_total{{{}}}[{}])".format(node, RATE), legend),
        minimum=0,
    )
    board.graph(
        "Memory",
        "Resident memory of each validator. The package limits a node to 1.5 GB.",
        ("avalanche_process_process_resident_memory_bytes{{{}}}".format(node), legend),
        unit="bytes",
        minimum=0,
    )
    board.graph(
        "Database Operation Latency",
        "Average time of one database operation, by kind, over the selected nodes.",
        ('sum by (method) (rate(avalanche_meterdb_duration{{{s}, chain="all"}}[{w}])) / sum by (method) (rate(avalanche_meterdb_calls{{{s}, chain="all"}}[{w}])) / 1e9'.format(s=node, w=RATE), "{{method}}"),
        unit="s",
    )
    board.graph(
        "API Calls Per Second",
        "Calls to the HTTP API of the validators, by API. The deployment tools and the relayer call these.",
        ("sum by (base) (rate(avalanche_api_calls{{{}}}[{}]))".format(node, RATE), "{{base}}"),
        unit="reqps",
    )
    board.graph(
        "Failing Health Checks",
        "Number of failing health checks of each validator.",
        ('max by (node) (avalanche_health_checks_failing{{{}, check="health"}})'.format(node), legend),
    )
    board.graph(
        "Disk Available",
        "Free space on the disk that holds the database of each validator.",
        ("avalanche_resource_tracker_disk_available_space{{{}}}".format(node), legend),
        unit="bytes",
        minimum=0,
    )
    return board


def icm():
    board = Dashboard(
        "avalanche-icm",
        "Avalanche devnet: interchain messaging",
        "Avalanche Interchain Messaging (ICM) between the C-Chain and each L1. A signature aggregator collects the signatures of the validators for a Warp message. With `bridge`, an ICM relayer delivers the messages of the token bridge.",
        [PROMETHEUS_VARIABLE, query_variable("l1", "L1", 'label_values(up{job="signature-aggregator"}, l1)')],
    )
    relayer = 'job="icm-relayer", l1=~"$l1"'
    aggregator = 'job="signature-aggregator", l1=~"$l1"'

    board.row("Signature aggregator")
    board.number(
        "Aggregators up",
        "Number of signature aggregators that answer the metrics scrape. Each L1 has one.",
        "count(up{{{}}} == 1) or vector(0)".format(aggregator),
        steps=[("red", None), ("green", 1)],
    )
    board.number(
        "Signatures aggregated",
        "Number of aggregation requests since the aggregators started. The deployment asks for one whenever the validator set of an L1 changes.",
        "sum(signature_aggregator_agg_sigs_req_count{{{}}})".format(aggregator),
    )
    board.number(
        "Stake connected",
        "Lowest share of the stake of an L1 that its aggregator is connected to, in percent. A Warp message needs signatures from 67%.",
        "min(signature_aggregator_connected_stake_weight_percentage{{{}}})".format(aggregator),
        unit="percent",
        steps=[("red", None), ("green", 67)],
    )
    board.number(
        "Aggregation failures",
        "Number of failures since the aggregators started: no validator set, not enough connected stake, or a message that could not be sent to a validator.",
        "sum(signature_aggregator_failures_to_get_validator_set{{{s}}}) + sum(signature_aggregator_failures_to_connect_to_sufficient_stake{{{s}}}) + sum(signature_aggregator_failures_sending_to_node{{{s}}})".format(s=aggregator),
        steps=[("green", None), ("red", 1)],
    )
    board.graph(
        "Aggregation Requests",
        "Requests for an aggregate signature in each interval.",
        ("sum by (l1) (increase(signature_aggregator_agg_sigs_req_count{{{}}}[{}]))".format(aggregator, RATE), "{{l1}}"),
        bars=True,
    )
    board.graph(
        "Aggregation Latency",
        "Time that the last aggregation took.",
        ("signature_aggregator_agg_sigs_latency_ms{{{}}}".format(aggregator), "{{l1}}"),
        unit="ms",
    )
    board.graph(
        "Signature Requests to Validators",
        "Requests for a signature that the aggregators sent to validators in each interval.",
        ("sum by (l1) (increase(signature_aggregator_app_request_count{{{}}}[{}]))".format(aggregator, RATE), "{{l1}}"),
        bars=True,
    )
    board.graph(
        "Validator Timeouts and Invalid Signatures",
        "Validators that did not answer in time, and answers with an invalid signature.",
        ("sum (increase(signature_aggregator_validator_timeouts{{{}}}[{}]))".format(aggregator, RATE), "timeouts"),
        ("sum (increase(signature_aggregator_invalid_signature_responses{{{}}}[{}]))".format(aggregator, RATE), "invalid signatures"),
        bars=True,
    )
    board.graph(
        "Connected Stake",
        "Share of the stake of each L1 that its aggregator is connected to, in percent.",
        ("signature_aggregator_connected_stake_weight_percentage{{{}}}".format(aggregator), "{{l1}}"),
        unit="percent",
        minimum=0,
        maximum=100,
    )
    board.graph(
        "Signature Cache",
        "Signatures that the aggregators found in their cache, and the ones they had to request.",
        ("sum (increase(signature_aggregator_signature_cache_hits{{{}}}[{}]))".format(aggregator, RATE), "hits"),
        ("sum (increase(signature_aggregator_signature_cache_misses{{{}}}[{}]))".format(aggregator, RATE), "misses"),
        bars=True,
    )

    board.row("ICM relayer")
    board.number(
        "Relayers up",
        "Number of ICM relayers that answer the metrics scrape. With `bridge`, each L1 has one.",
        "count(up{{{}}} == 1) or vector(0)".format(relayer),
        steps=[("red", None), ("green", 1)],
        requires="bridge",
    )
    board.number(
        "Messages relayed",
        "Number of messages that the relayers delivered since they started. The bridge setup and its test send a few.",
        "sum(app_successful_relay_message_count{{{}}})".format(relayer),
        requires="bridge",
    )
    board.number(
        "Messages failed",
        "Number of messages that the relayers could not deliver.",
        "sum(app_failed_relay_message_count{{{}}}) or vector(0)".format(relayer),
        steps=[("green", None), ("red", 1)],
        requires="bridge",
    )
    board.number(
        "P-Chain API latency",
        "Average time of a P-Chain API call of the relayers, which read the validator sets there.",
        "sum(rate(app_p_chain_api_call_latency_ms_sum{{{s}}}[{w}])) / sum(rate(app_p_chain_api_call_latency_ms_count{{{s}}}[{w}]))".format(s=relayer, w="$__range"),
        unit="ms",
        optional=True,
        requires="bridge",
    )
    board.graph(
        "Messages Relayed by Route",
        "Delivered messages in each interval, by source and destination blockchain.",
        ("sum by (l1, source_chain_id, destination_chain_id) (increase(app_successful_relay_message_count{{{}}}[{}]))".format(relayer, RATE), "{{source_chain_id}} to {{destination_chain_id}}"),
        bars=True,
        requires="bridge",
    )
    board.graph(
        "Messages Failed by Reason",
        "Messages that could not be delivered, by reason. The line stays empty while every message is delivered.",
        ("sum by (l1, failure_reason) (increase(app_failed_relay_message_count{{{}}}[{}]))".format(relayer, RATE), "{{l1}} {{failure_reason}}"),
        bars=True,
        optional=True,
        requires="bridge",
    )
    board.graph(
        "Checkpoint Height",
        "Height up to which a relayer has processed each source blockchain. After a restart it continues from here.",
        ("max by (l1, source_blockchain_id) (app_checkpoint_committed_height{{{}}})".format(relayer), "{{source_blockchain_id}}"),
        optional=True,
        requires="bridge",
    )
    board.graph(
        "Signed Message Latency",
        "Time that the relayer needed to collect the signatures for its last message.",
        ("max by (l1) (app_create_signed_message_latency_ms{{{}}})".format(relayer), "{{l1}}"),
        unit="ms",
        optional=True,
        requires="bridge",
    )
    board.graph(
        "Signature Requests to Validators",
        "Requests for a signature that the relayers sent to validators in each interval.",
        ("sum by (l1) (increase(app_fetch_signature_app_request_count{{{}}}[{}]))".format(relayer, RATE), "{{l1}}"),
        bars=True,
        optional=True,
        requires="bridge",
    )
    board.graph(
        "Peer Connects and Disconnects",
        "Connections that the relayers opened to validators, and the ones they lost.",
        ("sum (increase(app_connects{{{}}}[{}]))".format(relayer, RATE), "connects"),
        ("sum (increase(app_disconnects{{{}}}[{}]))".format(relayer, RATE), "disconnects"),
        bars=True,
        optional=True,
        requires="bridge",
    )
    return board


def logs():
    selector = 'job="avalanche", node=~"$node"'
    stream = "{" + selector + ', logger=~"$logger"}'
    board = Dashboard(
        "avalanche-logs",
        "Avalanche devnet: logs",
        "The log files of every AvalancheGo node. `logger` is the log file: `main` for the node itself, `P`, `X`, and `C` for the chains of the Primary Network, and a blockchain ID for the chain of an L1. The logs of the temporary bootstrap validators stay here after their removal. The relayer and the signature aggregator are not collected: use `kurtosis service logs`.",
        [
            datasource_variable("loki", "loki", "Datasource"),
            query_variable("node", "Node", "{job=\"avalanche\"}", datasource=LOKI),
            query_variable("logger", "Logger", "{job=\"avalanche\"}", datasource=LOKI),
            custom_variable("level", "Level", ["fatal", "error", "warn", "info", "debug", "trace", "verbo"]),
            text_variable("search", "Search (regular expression)"),
        ],
    )
    # A custom "All" of the level variable must also match a line without level.
    board.variables[3]["allValue"] = ".*"

    def count(matcher, line_filter=""):
        return "sum(count_over_time({{{}{}}}{} [$__range])) or vector(0)".format(selector, matcher, line_filter)

    board.row("Status")
    board.number(
        "Errors",
        "Number of log lines with level error or fatal in the selected time range. Open the lines below to read them.",
        count(', level=~"error|fatal"'),
        steps=[("green", None), ("red", 1)],
        width=6,
        datasource=LOKI,
        requires="logs",
    )
    board.number(
        "Warnings",
        "Number of log lines with level warn in the selected time range. A deployment logs some warnings while nodes connect.",
        count(', level="warn"'),
        steps=[("green", None), ("yellow", 1)],
        width=6,
        datasource=LOKI,
        requires="logs",
    )
    board.number(
        "Panic or fatal",
        "Number of log lines that report a panic or a fatal error in the selected time range. A node that logs one has stopped or is about to.",
        count("", ' |~ "(?i)\\\\bCRIT\\\\b|\\\\bFATAL\\\\b|fatal error|panic: "'),
        steps=[("green", None), ("red", 1)],
        width=6,
        datasource=LOKI,
        requires="logs",
    )
    board.number(
        "Ungraceful shutdowns",
        "Number of node starts that found a database that was not closed cleanly: the node had crashed, was killed for using too much memory, or was stopped by force.",
        count("", ' |= "detected previous ungraceful shutdown"'),
        steps=[("green", None), ("red", 1)],
        width=6,
        datasource=LOKI,
        requires="logs",
    )

    board.row("Volume")
    board.log_graph(
        "Log lines by level",
        "Number of log lines in each interval, by level. `none` counts the lines without a level, such as a stack trace.",
        (
            # A line without a level gets the name "none" instead of an empty one.
            'label_replace(sum by (level) (count_over_time({} [$__interval])), "level", "none", "level", "^$")'.format(stream),
            "{{level}}",
        ),
    )
    board.log_graph(
        "Log lines by node",
        "Number of log lines in each interval, by node. A node that logs far more than the others deserves a look.",
        ("sum by (node) (count_over_time({} [$__interval]))".format(stream), "{{node}}"),
    )
    board.log_graph(
        "Errors and warnings by node",
        "Number of lines with level warn, error, or fatal in each interval, by node.",
        ('sum by (node) (count_over_time({{{}, logger=~"$logger", level=~"warn|error|fatal"}} [$__interval]))'.format(selector), "{{node}}"),
    )
    board.log_graph(
        "Log lines by logger",
        "Number of log lines in each interval, by log file: `main`, a chain of the Primary Network, or the blockchain ID of an L1.",
        ("sum by (logger) (count_over_time({} [$__interval]))".format(stream), "{{logger}}"),
    )

    board.row("Lines")
    board.logs(
        "Errors and warnings",
        "Lines with level warn, error, or fatal of the selected nodes and loggers, newest first.",
        '{{{}, logger=~"$logger", level=~"warn|error|fatal"}} |~ "(?i)$search"'.format(selector),
        height=10,
    )
    board.logs(
        "Log lines",
        "Lines of the selected nodes, loggers, and levels, newest first. The search box filters them with a regular expression that ignores case.",
        '{{{}, logger=~"$logger", level=~"$level"}} |~ "(?i)$search"'.format(selector),
    )
    return board


# Folder of the Grafana provider, then the dashboards in it. Grafana gets the
# `logs` folder only when the package collects logs.
DASHBOARDS = {
    "metrics": [overview, l1, primary_network, icm],
    "logs": [logs],
}


def build():
    """Returns {relative path: dashboard} for every dashboard."""
    return {
        "{}/{}.json".format(folder, board.uid.removeprefix("avalanche-")): board
        for folder, builders in DASHBOARDS.items()
        for board in [builder() for builder in builders]
    }


def metric_names(expr):
    """Returns the metric names that a PromQL query reads (the plain ones)."""
    return set(re.findall(r"\b((?:avalanche|app|signature_aggregator|scrape)_[a-z0-9_]+|up)\b(?=\s*[{\[)]|\s*$)", expr))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--queries", action="store_true", help="print every query as JSON instead of writing files")
    args = parser.parse_args()
    boards = build()
    if args.queries:
        print(json.dumps([query for board in boards.values() for query in board.queries], indent=2))
        return
    for path, board in boards.items():
        file = OUTPUT / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(board.json(), indent=2) + "\n")
        print("Wrote {}".format(file.relative_to(ROOT)))


if __name__ == "__main__":
    main()
