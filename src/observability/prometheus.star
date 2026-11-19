"""Prometheus: stores the metrics that Alloy scrapes and sends to it."""

constants = import_module("../config/constants.star")

SERVICE_NAME = "prometheus"


def launch(plan, args, node_count):
    """Starts Prometheus as a store. It scrapes nothing itself.

    Args:
        node_count: number of scraped nodes; sizes the memory limit.
    Returns:
        struct(url, remote_write_url): the query API, and the endpoint that
        accepts samples from Alloy.
    """
    config = plan.render_templates(
        name="prometheus-config",
        config={
            "prometheus.yml": struct(
                template="{{.content}}",
                # JSON is valid YAML. Alloy owns the scrape configuration.
                data={"content": json.encode({"global": {}})},
            )
        },
    )
    plan.add_service(
        name=SERVICE_NAME,
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
                # Accept the samples that Alloy pushes.
                "--web.enable-remote-write-receiver",
                # A devnet needs recent data only.
                "--storage.tsdb.retention.time=2h",
            ],
            max_memory=constants.PROMETHEUS_BASE_MEMORY
            + constants.PROMETHEUS_NODE_MEMORY * node_count,
        ),
    )
    url = "http://{}:{}".format(SERVICE_NAME, constants.PROMETHEUS_PORT_NUMBER)
    return struct(url=url, remote_write_url=url + "/api/v1/write")
