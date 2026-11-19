"""Optional observability stack: what the devnet does, as metrics and logs.

  alloy       collects: scrapes the metrics of every node and support
              service, and reads the log files of every node
  prometheus  stores the metrics
  loki        stores the logs

The stack starts before the network. It then records the whole deployment,
and it keeps running when a later step fails.
"""

alloy = import_module("./alloy.star")
loki = import_module("./loki.star")
prometheus = import_module("./prometheus.star")


def launch(plan, args, primary_nodes, l1s):
    """Starts the enabled services of the stack and returns their URLs.

    The nodes do not exist yet. The arguments name the services that the
    network launchers will start; Alloy reports a target as down until then.

    Args:
        primary_nodes: `primary_network_launcher.planned_nodes(args)`.
        l1s: `l1_launcher.planned(args, l1_index)` of each L1.
    Returns:
        struct(prometheus_url, loki_url, alloy_url). A URL is "" when its
        service does not run.
    """
    # Alloy and Prometheus hold the metric series of every node; see their limits.
    node_count = len(primary_nodes)
    for l1 in l1s:
        node_count += len(l1.nodes)

    # The stores start first: Alloy sends to them as soon as it runs.
    prometheus_context = None
    if args["metrics"]:
        prometheus_context = prometheus.launch(plan, args, node_count)
    loki_context = None
    if args["logs"]:
        loki_context = loki.launch(plan, args)
    alloy_context = None
    if prometheus_context or loki_context:
        alloy_context = alloy.launch(
            plan, args, primary_nodes, l1s, node_count, prometheus_context, loki_context
        )

    return struct(
        prometheus_url=prometheus_context.url if prometheus_context else "",
        loki_url=loki_context.url if loki_context else "",
        alloy_url=alloy_context.url if alloy_context else "",
    )
