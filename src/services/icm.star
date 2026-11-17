"""Public signature-aggregator service for validator-management messages."""


def launch_aggregator(plan, cfg, name, uri, subnet):
    aggregator_config = plan.render_templates(
        name=name + "-aggregator-config",
        config={
            "config.json": struct(
                template="{{.content}}",
                data={
                    "content": json.encode(
                        {
                            "p-chain-api": {"base-url": uri},
                            "info-api": {"base-url": uri},
                            "tracked-subnet-ids": [subnet],
                            "api-port": 8080,
                            "metrics-port": 8081,
                            "allow-private-ips": True,
                        }
                    )
                },
            )
        },
    )
    aggregator = plan.add_service(
        name=name + "-aggregator",
        config=ServiceConfig(
            image=cfg["aggregator_image"],
            entrypoint=["/usr/bin/signature-aggregator"],
            cmd=["--config-file=/config/config.json"],
            files={"/config": aggregator_config},
            ports={
                "api": PortSpec(number=8080, application_protocol="http", wait="2m")
            },
        ),
    )
    return aggregator
