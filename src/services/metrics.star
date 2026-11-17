def launch(plan, targets):
    prometheus_config = plan.render_templates(
        name="prometheus-config",
        config={
            "prometheus.yml": struct(
                template="{{.content}}",
                data={
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
            image="prom/prometheus@sha256:6927e0919a144aa7616fd0137d4816816d42f6b816de3af269ab065250859a62",
            cmd=[
                "--config.file=/etc/prometheus/prometheus.yml",
                "--storage.tsdb.retention.time=30m",
            ],
            files={"/etc/prometheus": prometheus_config},
            ports={"http": PortSpec(number=9090, application_protocol="http")},
            max_memory=512,
        ),
    )
