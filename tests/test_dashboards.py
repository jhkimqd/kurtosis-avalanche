"""The generated Grafana dashboards: in step with their generator, and well formed."""

import importlib.util
import json
import re
import unittest

import starlark

ROOT = starlark.ROOT
spec = importlib.util.spec_from_file_location("gen_dashboards", ROOT / "helpers/gen-dashboards.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

# Labels that the package sets (docs/observability.md), then the labels of
# AvalancheGo, the relayer, and Prometheus that the dashboards use.
PACKAGE_LABELS = {"job", "node", "role", "l1", "logger", "level"}
UPSTREAM_LABELS = {"chain", "op", "check", "result", "__name__"}


def panels(dashboard):
    """Returns every panel, the ones inside a collapsed row included."""
    for panel in dashboard["panels"]:
        if panel["type"] == "row":
            yield from panel["panels"]
        else:
            yield panel


class DashboardsTest(unittest.TestCase):
    boards = generator.build()

    def test_committed_files_are_the_generator_output(self):
        directory = generator.OUTPUT
        self.assertEqual(
            sorted(str(file.relative_to(directory)) for file in directory.rglob("*.json")),
            sorted(self.boards),
            "run python3 helpers/gen-dashboards.py",
        )
        for path, board in self.boards.items():
            with self.subTest(dashboard=path):
                self.assertEqual(
                    json.loads((directory / path).read_text()),
                    board.json(),
                    "run python3 helpers/gen-dashboards.py",
                )

    def test_every_dashboard_can_be_found_and_linked(self):
        uids = [board.uid for board in self.boards.values()]
        self.assertEqual(len(uids), len(set(uids)))
        for path, board in self.boards.items():
            dashboard = board.json()
            with self.subTest(dashboard=path):
                self.assertTrue(dashboard["title"] and dashboard["description"])
                self.assertEqual(dashboard["tags"], [generator.TAG])
                self.assertEqual(dashboard["links"][0]["tags"], [generator.TAG])

    def test_every_panel_explains_itself_and_follows_the_datasource_variable(self):
        for path, board in self.boards.items():
            dashboard = board.json()
            variables = {variable["name"]: variable for variable in dashboard["templating"]["list"]}
            ids = []
            for panel in panels(dashboard):
                with self.subTest(dashboard=path, panel=panel["title"]):
                    self.assertGreater(len(panel["description"]), 30)
                    self.assertTrue(panel["targets"])
                    for target in [panel] + panel["targets"]:
                        # "${datasource}" or "${loki}": never a fixed datasource.
                        name = re.fullmatch(r"\$\{(\w+)\}", target["datasource"]["uid"])[1]
                        self.assertEqual(variables[name]["type"], "datasource")
                        self.assertEqual(variables[name]["query"], target["datasource"]["type"])
                    ids.append(panel["id"])
            self.assertEqual(len(ids), len(set(ids)), path)

    def test_panels_do_not_overlap(self):
        for path, board in self.boards.items():
            dashboard = board.json()
            groups = [[panel for panel in dashboard["panels"]]]
            groups += [panel["panels"] for panel in dashboard["panels"] if panel["type"] == "row"]
            for group in groups:
                cells = {}
                for panel in group:
                    position = panel["gridPos"]
                    self.assertLessEqual(position["x"] + position["w"], 24)
                    for x in range(position["x"], position["x"] + position["w"]):
                        for y in range(position["y"], position["y"] + position["h"]):
                            self.assertNotIn((x, y), cells, "{}: {} overlaps {}".format(path, panel["title"], cells.get((x, y))))
                            cells[(x, y)] = panel["title"]

    def test_queries_use_known_labels_and_every_variable(self):
        for path, board in self.boards.items():
            dashboard = board.json()
            variables = {variable["name"] for variable in dashboard["templating"]["list"]}
            used = set()
            for panel in panels(dashboard):
                for target in panel["targets"]:
                    expr = target["expr"]
                    with self.subTest(dashboard=path, panel=panel["title"]):
                        # Label matchers inside {...}, and `by (...)` clauses.
                        labels = set(re.findall(r'[{,]\s*([a-zA-Z_]+)\s*(?:=~|!~|!=|=)\s*"', expr))
                        for clause in re.findall(r"\bby \(([^)]*)\)", expr):
                            labels |= {label.strip() for label in clause.split(",")}
                        allowed = PACKAGE_LABELS | UPSTREAM_LABELS
                        if board.uid in ("avalanche-icm", "avalanche-primary-network"):
                            # Labels of the relayer and of the P-Chain metrics.
                            allowed |= {"source_chain_id", "destination_chain_id", "failure_reason",
                                        "source_blockchain_id", "blk", "tx", "io", "method", "base"}
                        self.assertLessEqual(labels, allowed)
                        # A fixed window hides a devnet that lives for minutes.
                        windows = set(re.findall(r"\[([^\]]+)\]", expr))
                        self.assertLessEqual(windows, {"$__rate_interval", "$__interval", "$__range", generator.NOW})
                        used |= set(re.findall(r"\$(\w+)", expr))
                        # Every variable has a value for the live check.
                        self.assertIsNone(re.search(r"\$\w", generator.resolve(expr)))
            self.assertLessEqual(variables - {"datasource", "loki"}, used, path)

    def test_the_live_check_asks_what_all_selects(self):
        # The check runs each query with a value per variable. For a variable
        # with "All", that value is what "All" stands for in Grafana.
        for path, board in self.boards.items():
            for variable in board.json()["templating"]["list"]:
                if variable.get("includeAll"):
                    with self.subTest(dashboard=path, variable=variable["name"]):
                        self.assertEqual(generator.RESOLVED["$" + variable["name"]], variable["allValue"])

    def test_all_l1s_leaves_out_the_primary_network(self):
        # A Primary Network validator has no `l1` label, which `.*` matches.
        for path in ("metrics/l1.json", "metrics/icm.json"):
            variables = {variable["name"]: variable for variable in self.boards[path].json()["templating"]["list"]}
            self.assertEqual(variables["l1"]["allValue"], ".+")

    def test_a_status_number_is_checked_without_its_fallback(self):
        fallbacks = 0
        for path, board in self.boards.items():
            for panel in panels(board.json()):
                for target in panel["targets"]:
                    fallbacks += target["expr"].endswith("or vector(0)")
        self.assertGreater(fallbacks, 3)
        for board in self.boards.values():
            for query in board.queries:
                self.assertNotIn("or vector(0)", query["expr"], query["panel"])

    def test_panel_titles_are_unique_in_a_dashboard(self):
        # The live check names a failing panel by dashboard and title.
        for path, board in self.boards.items():
            titles = [panel["title"] for panel in panels(board.json())]
            self.assertEqual(len(titles), len(set(titles)), path)

    def test_selectors_of_an_l1_leave_out_the_other_chains(self):
        # An L1 node also reports the P-Chain, and its database reports "all".
        self.assertIn('chain!~"P|X|C|all"', generator.L1_CHAIN)
        l1 = self.boards["metrics/l1.json"].json()
        for panel in panels(l1):
            for target in panel["targets"]:
                for metric in re.findall(r"(avalanche_(?:snowman|handler|subnetevm_vm|meterchainvm|benchlist|stake)_\w+)\{([^}]*)\}", target["expr"]):
                    with self.subTest(panel=panel["title"], metric=metric[0]):
                        self.assertIn('chain!~"P|X|C|all"', metric[1])

    def test_queries_for_the_live_check(self):
        queries = [query for board in self.boards.values() for query in board.queries]
        self.assertGreater(len(queries), 100)
        for query in queries:
            self.assertIn(query["datasource"], ("prometheus", "loki"))
            self.assertIn(query["requires"], (None, "bridge", "logs"))
            self.assertEqual(query["requires"] == "logs", query["datasource"] == "loki")
        # A panel of the relayer needs the bridge: without it no relayer runs.
        for query in queries:
            if "icm-relayer" in query["expr"] or re.search(r'(?<![\w|"])app_\w+\{', query["expr"]):
                self.assertEqual(query["requires"], "bridge", query["panel"])


if __name__ == "__main__":
    unittest.main()
