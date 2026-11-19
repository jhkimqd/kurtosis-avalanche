"""Grafana Alloy: the collector of the devnet.

Alloy runs two pipelines, each a static file in
static_files/observability/alloy/:

  metrics.alloy  scrapes the metrics endpoint of every node, relayer, and
                 signature aggregator, and sends the samples to Prometheus
  logs.alloy     reads the log files of every node from the shared log
                 volume, and sends the lines to Loki

The pipelines read what to collect from the JSON files that this module
renders, in the `file_sd` format of Prometheus: a list of
{"targets": [...], "labels": {...}}. Metrics and logs of a node carry the
same labels: `job`, `node`, `role`, and for an L1 node `l1`.
"""

constants = import_module("../config/constants.star")
node_launcher = import_module("../node/launcher.star")

SERVICE_NAME = "alloy"

# Mount points inside the Alloy container.
CONFIG_PATH = "/etc/alloy"  # the pipeline files; Alloy loads every *.alloy file
TARGETS_PATH = "/etc/alloy-targets"  # what to collect

PIPELINES_SOURCE = "../../static_files/observability/alloy"


def launch(plan, args, primary_nodes, l1s, node_count, prometheus, loki):
    """Starts Alloy with the pipelines that have a store, and returns its context.

    Args:
        primary_nodes: planned Primary Network validators, each a
            struct(name, role) (see src/primary_network/launcher.star).
        l1s: planned L1s, each a struct(name, nodes, bootstrap_nodes,
            metrics_targets) (see src/l1/launcher.star).
        node_count: number of scraped nodes; sizes the memory limit.
        prometheus: context of Prometheus (see ./prometheus.star), or None
            when metrics are not collected.
        loki: context of Loki (see ./loki.star), or None when logs are not
            collected.
    Returns:
        struct(url): the address of Alloy's own UI, which shows each
        component of the pipelines and its health.
    """
    pipelines = []
    target_files = {}
    env_vars = {}
    files = {}
    if prometheus:
        pipelines.append(_upload_pipeline(plan, "metrics"))
        for job, entries in metrics_targets(primary_nodes, l1s).items():
            target_files[job + ".json"] = _json_file(entries)
        env_vars["PROMETHEUS_REMOTE_WRITE_URL"] = prometheus.remote_write_url
    if loki:
        pipelines.append(_upload_pipeline(plan, "logs"))
        target_files["logs.json"] = _json_file(log_targets(primary_nodes, l1s))
        env_vars["LOKI_PUSH_URL"] = loki.push_url
        # The same volume that every node mounts (see src/node/launcher.star).
        files[node_launcher.LOGS_PATH] = Directory(
            persistent_key=constants.NODE_LOGS_VOLUME_KEY
        )
    files[CONFIG_PATH] = Directory(artifact_names=pipelines)
    files[TARGETS_PATH] = plan.render_templates(
        name="alloy-targets", config=target_files
    )

    plan.add_service(
        name=SERVICE_NAME,
        config=ServiceConfig(
            image=args["images"]["alloy"],
            ports={
                "http": PortSpec(
                    number=constants.ALLOY_PORT_NUMBER, application_protocol="http"
                )
            },
            files=files,
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
            env_vars=env_vars,
            # AvalancheGo runs as root and owns the log files.
            user=User(uid=0, gid=0),
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


def log_targets(primary_nodes, l1s):
    """Returns the log files to read as a list of file_sd entries.

    One entry per node, temporary bootstrap nodes included: their log files
    stay in the shared volume after the nodes are removed.
    """
    targets = [_log_target(node, None) for node in primary_nodes]
    for l1 in l1s:
        targets.extend(
            [_log_target(node, l1.name) for node in l1.nodes + l1.bootstrap_nodes]
        )
    return targets


def _node_labels(node, l1_name):
    labels = {"node": node.name, "role": node.role}
    if l1_name:
        labels["l1"] = l1_name
    return labels


def _node_target(node, l1_name):
    return {
        "targets": ["{}:{}".format(node.name, constants.NODE_HTTP_PORT_NUMBER)],
        "labels": _node_labels(node, l1_name),
    }


def _log_target(node, l1_name):
    directory = node_launcher.log_dir(node.name)
    labels = {
        "job": constants.METRICS_JOB.node,
        "__path__": directory + "/*.log",
        # AvalancheGo renames a full file to <logger>-<date>T<time>.log and
        # starts a new one. Alloy has read the renamed file already.
        "__path_exclude__": directory
        + "/*-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*.log",
    }
    return {
        # The file_sd format requires an address. A log target has none.
        "targets": ["localhost"],
        "labels": labels | _node_labels(node, l1_name),
    }


def _upload_pipeline(plan, name):
    """Uploads one pipeline file and returns the name of its artifact."""
    return plan.upload_files(
        name="alloy-{}-pipeline".format(name),
        src="{}/{}.alloy".format(PIPELINES_SOURCE, name),
    )


def _json_file(content):
    """Returns a template that writes `content` as a JSON file."""
    return struct(template="{{.content}}", data={"content": json.encode(content)})
