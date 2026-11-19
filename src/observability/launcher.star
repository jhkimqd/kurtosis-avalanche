"""Optional observability stack: what the devnet does, as metrics.

  alloy       collects: scrapes the metrics of every node and support service
  prometheus  stores the metrics

The stack starts before the network. It then records the whole deployment,
and it keeps running when a later step fails.
"""

alloy = import_module("./alloy.star")
prometheus = import_module("./prometheus.star")


def launch(plan, args, primary_nodes, l1s):
    """Starts the enabled services of the stack and returns their URLs.

    The nodes do not exist yet. The arguments name the services that the
    network launchers will start; Alloy reports a target as down until then.

    Args:
        primary_nodes: `primary_network_launcher.planned_nodes(args)`.
        l1s: `l1_launcher.planned(args, l1_index)` of each L1.
    Returns:
        struct(prometheus_url, alloy_url). A URL is "" when its service does
        not run.
    """
    if not args["metrics"]:
        return struct(prometheus_url="", alloy_url="")

    # Both services hold the metric series of every node; see their limits.
    node_count = len(primary_nodes)
    for l1 in l1s:
        node_count += len(l1.nodes)
    prometheus_context = prometheus.launch(plan, args, node_count)
    alloy_context = alloy.launch(
        plan, args, primary_nodes, l1s, node_count, prometheus_context
    )
    return struct(prometheus_url=prometheus_context.url, alloy_url=alloy_context.url)
