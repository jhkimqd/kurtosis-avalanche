"""Loki: stores the log lines that Alloy reads and sends to it."""

constants = import_module("../config/constants.star")

SERVICE_NAME = "loki"


def launch(plan, args):
    """Starts one Loki process that keeps its data in the container.

    Returns:
        struct(url, push_url): the query API, and the endpoint that accepts
        log lines from Alloy.
    """
    config = plan.render_templates(
        name="loki-config",
        config={
            "config.yaml": struct(
                template="{{.content}}",
                # JSON is valid YAML.
                data={"content": json.encode(_config())},
            )
        },
    )
    plan.add_service(
        name=SERVICE_NAME,
        config=ServiceConfig(
            image=args["images"]["loki"],
            ports={
                "http": PortSpec(
                    number=constants.LOKI_PORT_NUMBER, application_protocol="http"
                )
            },
            files={"/etc/loki": config},
            cmd=["-config.file=/etc/loki/config.yaml"],
            max_memory=constants.LOKI_MAX_MEMORY,
        ),
    )
    url = "http://{}:{}".format(SERVICE_NAME, constants.LOKI_PORT_NUMBER)
    return struct(url=url, push_url=url + "/loki/api/v1/push")


def _config():
    """Returns the configuration of a single-process Loki without replication."""
    return {
        # One tenant, no login. The devnet is a closed local network.
        "auth_enabled": False,
        "server": {"http_listen_port": constants.LOKI_PORT_NUMBER},
        "common": {
            "instance_addr": "127.0.0.1",
            # The image runs as a user that owns /loki.
            "path_prefix": "/loki",
            "storage": {
                "filesystem": {
                    "chunks_directory": "/loki/chunks",
                    "rules_directory": "/loki/rules",
                }
            },
            "replication_factor": 1,
            "ring": {"kvstore": {"store": "inmemory"}},
        },
        "schema_config": {
            "configs": [
                {
                    "from": "2024-01-01",
                    "store": "tsdb",
                    "object_store": "filesystem",
                    "schema": "v13",
                    "index": {"prefix": "index_", "period": "24h"},
                }
            ]
        },
        "limits_config": {
            # Lets Grafana draw the volume of log lines per label.
            "volume_enabled": True,
            # When Alloy starts or restarts it sends every log file from its
            # start. The default limits would reject part of that burst.
            "ingestion_rate_mb": 64,
            "ingestion_burst_size_mb": 128,
            "per_stream_rate_limit": "32MB",
            "per_stream_rate_limit_burst": "64MB",
            # A devnet needs recent data only.
            "retention_period": "24h",
        },
        "compactor": {
            "working_directory": "/loki/compactor",
            "retention_enabled": True,
            "delete_request_store": "filesystem",
        },
        # A devnet is offline: send no usage report.
        "analytics": {"reporting_enabled": False},
    }
