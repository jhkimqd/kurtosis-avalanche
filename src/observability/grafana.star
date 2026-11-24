"""Grafana: shows the metrics and logs of the devnet on ready-made dashboards.

Grafana reads its setup from files at start ("provisioning"): the datasources
that this module renders, and the dashboards in
static_files/observability/grafana/dashboards/. helpers/gen-dashboards.py
generates those dashboards.
"""

constants = import_module("../config/constants.star")

SERVICE_NAME = "grafana"

# Mount points inside the Grafana container.
PROVISIONING_PATH = "/config"  # datasources and the dashboard provider
DASHBOARDS_PATH = "/dashboards"  # one subdirectory per dashboard group

DASHBOARDS_SOURCE = "../../static_files/observability/grafana/dashboards"

# Datasource UIDs. The dashboards select a datasource by type, so a UID only
# has to be stable for links and for helpers/check-observability.sh.
PROMETHEUS_UID = "prometheus"
LOKI_UID = "loki"


def launch(plan, args, prometheus, loki):
    """Starts Grafana with a datasource and dashboards for each running store.

    Args:
        prometheus: context of Prometheus (see ./prometheus.star), or None.
        loki: context of Loki (see ./loki.star), or None.
    Returns:
        struct(url). Open the address that `kurtosis port print <enclave>
        grafana http` prints; no login is needed to look.
    """
    datasources = []
    files = {}
    # The first group that exists opens as the home page.
    home = ""
    if prometheus:
        datasources.append(
            {
                "name": "Prometheus",
                "uid": PROMETHEUS_UID,
                "type": "prometheus",
                "access": "proxy",
                "url": prometheus.url,
                "isDefault": True,
                "editable": False,
                # The scrape interval of Alloy; `$__rate_interval` follows it.
                "jsonData": {"timeInterval": "5s", "httpMethod": "POST"},
            }
        )
        files[DASHBOARDS_PATH + "/metrics"] = _upload_dashboards(plan, "metrics")
        home = DASHBOARDS_PATH + "/metrics/overview.json"
    if loki:
        datasources.append(
            {
                "name": "Loki",
                "uid": LOKI_UID,
                "type": "loki",
                "access": "proxy",
                "url": loki.url,
                "isDefault": not prometheus,
                "editable": False,
            }
        )
        files[DASHBOARDS_PATH + "/logs"] = _upload_dashboards(plan, "logs")
        if not home:
            home = DASHBOARDS_PATH + "/logs/logs.json"

    files[PROVISIONING_PATH] = plan.render_templates(
        name="grafana-provisioning",
        config={
            # JSON is valid YAML.
            "datasources/datasources.yml": _json_file(
                {"apiVersion": 1, "datasources": datasources}
            ),
            # Grafana logs an error for a provisioning directory that is
            # missing. These two stay empty.
            "plugins/plugins.yml": _json_file({"apiVersion": 1}),
            "alerting/alerting.yml": _json_file({"apiVersion": 1}),
            "dashboards/dashboards.yml": _json_file(
                {
                    "apiVersion": 1,
                    "providers": [
                        {
                            "name": "avalanche-devnet",
                            "folder": "Avalanche devnet",
                            "type": "file",
                            # The files are the source: change a dashboard in
                            # helpers/gen-dashboards.py, not in the UI.
                            "allowUiUpdates": False,
                            "disableDeletion": True,
                            "options": {
                                "path": DASHBOARDS_PATH,
                                "foldersFromFilesStructure": False,
                            },
                        }
                    ],
                }
            ),
        },
    )

    plan.add_service(
        name=SERVICE_NAME,
        config=ServiceConfig(
            image=args["images"]["grafana"],
            ports={
                "http": PortSpec(
                    number=constants.GRAFANA_PORT_NUMBER, application_protocol="http"
                )
            },
            files=files,
            env_vars={
                "GF_PATHS_PROVISIONING": PROVISIONING_PATH,
                "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH": home,
                # The dashboards refresh every 10 seconds; Alloy scrapes every 5.
                "GF_DASHBOARDS_MIN_REFRESH_INTERVAL": "5s",
                # Anyone who reaches the port may look, without a login.
                # Grafana 13 gives such a visitor the viewer role only. To edit
                # or to use Explore, sign in as admin with the password admin:
                # a devnet has no secret to protect.
                "GF_AUTH_ANONYMOUS_ENABLED": "true",
                "GF_AUTH_ANONYMOUS_ORG_ROLE": "Viewer",
                # A devnet is offline: no usage report, no update check, no
                # news feed, and no plugin download at start.
                "GF_ANALYTICS_REPORTING_ENABLED": "false",
                "GF_ANALYTICS_CHECK_FOR_UPDATES": "false",
                "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES": "false",
                "GF_NEWS_NEWS_FEED_ENABLED": "false",
                "GF_PLUGINS_PREINSTALL_DISABLED": "true",
            },
            max_memory=constants.GRAFANA_MAX_MEMORY,
        ),
    )
    return struct(
        url="http://{}:{}".format(SERVICE_NAME, constants.GRAFANA_PORT_NUMBER)
    )


def _upload_dashboards(plan, group):
    """Uploads one directory of dashboards and returns the name of its artifact."""
    return plan.upload_files(
        name="grafana-{}-dashboards".format(group),
        src="{}/{}".format(DASHBOARDS_SOURCE, group),
    )


def _json_file(content):
    """Returns a template that writes `content` as a JSON file."""
    return struct(template="{{.content}}", data={"content": json.encode(content)})
