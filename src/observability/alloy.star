"""Grafana Alloy: the collector of the devnet.

Alloy scrapes the metrics endpoint of every node, relayer, and signature
aggregator, and sends the samples to Prometheus. Its pipeline is the static
file static_files/observability/alloy/metrics.alloy. That file reads its
targets from the JSON files that this module renders, in the `file_sd` format
of Prometheus: a list of {"targets": [...], "labels": {...}}.
"""

constants = import_module("../config/constants.star")

SERVICE_NAME = "alloy"

# Mount points inside the Alloy container.
CONFIG_PATH = "/etc/alloy"  # the pipeline files; Alloy loads every *.alloy file
TARGETS_PATH = "/etc/alloy-targets"  # what to scrape

PIPELINES_SOURCE = "../../static_files/observability/alloy"


def launch(plan, args, primary_nodes, l1s, node_count, prometheus):
    """Starts Alloy and returns its context.

    Args:
        primary_nodes: planned Primary Network validators, each a
            struct(name, role) (see src/primary_network/launcher.star).
        l1s: planned L1s, each a struct(name, nodes, bootstrap_nodes,
            metrics_targets) (see src/l1/launcher.star).
        node_count: number of scraped nodes; sizes the memory limit.
        prometheus: context of Prometheus (see ./prometheus.star).
    Returns:
        struct(url): the address of Alloy's own UI, which shows each
        component of the pipeline and its health.
    """
    targets = plan.render_templates(
        name="alloy-targets",
        config={
            job + ".json": _json_file(entries)
            for job, entries in metrics_targets(primary_nodes, l1s).items()
        },
    )
    pipelines = [
        plan.upload_files(
            name="alloy-metrics-pipeline", src=PIPELINES_SOURCE + "/metrics.alloy"
        )
    ]
    plan.add_service(
        name=SERVICE_NAME,
        config=ServiceConfig(
            image=args["images"]["alloy"],
            ports={
                "http": PortSpec(
                    number=constants.ALLOY_PORT_NUMBER, application_protocol="http"
                )
            },
            files={
                CONFIG_PATH: Directory(artifact_names=pipelines),
                TARGETS_PATH: targets,
            },
            cmd=[
                "run",
                "--server.http.listen-addr=0.0.0.0:{}".format(
                    constants.ALLOY_PORT_NUMBER
                ),
                "--storage.path=/var/lib/alloy/data",
                # A devnet is offline: send no usage report.
                "--disable-reporting",
                CONFIG_PATH,
            ],
            env_vars={"PROMETHEUS_REMOTE_WRITE_URL": prometheus.remote_write_url},
            max_memory=constants.ALLOY_BASE_MEMORY
            + constants.ALLOY_NODE_MEMORY * node_count,
        ),
    )
    return struct(url="http://{}:{}".format(SERVICE_NAME, constants.ALLOY_PORT_NUMBER))


def metrics_targets(primary_nodes, l1s):
    """Returns the scrape targets of each job as {job: [file_sd entry]}.

    Every job has an entry list, empty when no such service runs, because the
    pipeline reads one file per job. Temporary bootstrap nodes are left out: a
    removed node would count as a node that is down.
    """
    nodes = [_node_target(node, None) for node in primary_nodes]
    services = {
        constants.METRICS_JOB.icm_relayer: [],
        constants.METRICS_JOB.signature_aggregator: [],
    }
    for l1 in l1s:
        nodes.extend([_node_target(node, l1.name) for node in l1.nodes])
        for target in l1.metrics_targets:
            services[target.job].append(
                {"targets": [target.address], "labels": {"l1": l1.name}}
            )
    return {constants.METRICS_JOB.node: nodes} | services


def _node_target(node, l1_name):
    labels = {"node": node.name, "role": node.role}
    if l1_name:
        labels["l1"] = l1_name
    return {
        "targets": ["{}:{}".format(node.name, constants.NODE_HTTP_PORT_NUMBER)],
        "labels": labels,
    }


def _json_file(content):
    """Returns a template that writes `content` as a JSON file."""
    return struct(template="{{.content}}", data={"content": json.encode(content)})
