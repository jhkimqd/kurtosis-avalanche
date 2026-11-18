"""Optional Prometheus service that scrapes the metrics of every node."""

constants = import_module("../config/constants.star")


def launch(plan, args, nodes):
    """Starts Prometheus.

    Args:
        nodes: context of every node to scrape (see src/node/launcher.star).
    """
    targets = [
        {
            "targets": ["{}:{}".format(node.name, constants.NODE_HTTP_PORT_NUMBER)],
            "labels": {"node": node.name, "role": node.role},
        }
        for node in nodes
    ]
    config = plan.render_templates(
        name="prometheus-config",
        config={
            "prometheus.yml": struct(
                template="{{.content}}",
                data={
                    # JSON is valid YAML.
                    "content": json.encode(
                        {
                            "global": {"scrape_interval": "5s"},
                            "scrape_configs": [
                                {
                                    "job_name": "avalanche",
                                    "metrics_path": "/ext/metrics",
                                    "static_configs": targets,
                                }
                            ],
                        }
                    )
                },
            )
        },
    )
    plan.add_service(
        name="prometheus",
        config=ServiceConfig(
            image=args["images"]["prometheus"],
            ports={
                "http": PortSpec(
                    number=constants.PROMETHEUS_PORT_NUMBER, application_protocol="http"
                )
            },
            files={"/etc/prometheus": config},
            cmd=[
                "--config.file=/etc/prometheus/prometheus.yml",
                # A devnet needs recent data only.
                "--storage.tsdb.retention.time=30m",
            ],
            max_memory=constants.PROMETHEUS_MAX_MEMORY,
        ),
    )
