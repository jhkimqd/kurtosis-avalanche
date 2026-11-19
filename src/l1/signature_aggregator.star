"""Signature aggregator: collects validator signatures for a Warp message.

A Warp message is valid once validators that hold 67% of the stake have signed
it. The Go tools ask this service for those signatures whenever the validator
set of an L1 changes.
"""

constants = import_module("../config/constants.star")


def launch(plan, args, l1_name, subnet_id, primary_rpc_url):
    """Starts the signature aggregator of one L1 and returns its API URL."""
    name = generate_name(l1_name)
    config = plan.render_templates(
        name=name + "-config",
        config={
            "config.json": struct(
                template="{{.content}}",
                data={
                    "content": json.encode(
                        {
                            "p-chain-api": {"base-url": primary_rpc_url},
                            "info-api": {"base-url": primary_rpc_url},
                            "tracked-subnet-ids": [subnet_id],
                            "api-port": constants.SIGNATURE_AGGREGATOR_API_PORT_NUMBER,
                            "metrics-port": constants.SIGNATURE_AGGREGATOR_METRICS_PORT_NUMBER,
                            # Every peer of a local network has a private IP address.
                            "allow-private-ips": True,
                        }
                    )
                },
            )
        },
    )
    plan.add_service(
        name=name,
        config=ServiceConfig(
            image=args["images"]["signature_aggregator"],
            ports={
                "api": PortSpec(
                    number=constants.SIGNATURE_AGGREGATOR_API_PORT_NUMBER,
                    application_protocol="http",
                    wait="2m",
                ),
                "metrics": PortSpec(
                    number=constants.SIGNATURE_AGGREGATOR_METRICS_PORT_NUMBER,
                    application_protocol="http",
                ),
            },
            files={"/config": config},
            entrypoint=["/usr/bin/signature-aggregator"],
            cmd=["--config-file=/config/config.json"],
        ),
    )
    return "http://{}:{}".format(name, constants.SIGNATURE_AGGREGATOR_API_PORT_NUMBER)


def generate_name(l1_name):
    """Returns the service name of the signature aggregator of an L1."""
    return l1_name + "-aggregator"


def metrics_address(l1_name):
    """Returns the host and port that serve the aggregator's metrics."""
    return "{}:{}".format(
        generate_name(l1_name), constants.SIGNATURE_AGGREGATOR_METRICS_PORT_NUMBER
    )
