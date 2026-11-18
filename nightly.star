"""Deploys a devnet and tests direct ICM delivery between all pairs of L1s."""

constants = import_module("./src/config/constants.star")
input_parser = import_module("./src/config/input_parser.star")
main = import_module("./main.star")
tools = import_module("./src/tools/launcher.star")

RELAYER_NAME = "nightly-relayer"


def run(plan, args={}):
    """Creates the network, verifies L1 messages, and returns its manifest.

    Args:
        args: normal package arguments; bridge must be enabled with at least two L1s.
    Returns:
        The deployment manifest. The nightly-results artifact holds delivery receipts.
    """
    parsed = input_parser.parse(args)
    if not parsed["bridge"] or parsed["l1"]["count"] < 2:
        fail("nightly tests require bridge: true and l1.count of at least 2")
    manifest = main.run(plan, args)
    state = tools.STATE_PATH + "/nightly"
    command_args = [
        manifest["primary_network"]["rpc_url"],
        state,
        json.encode(manifest),
    ]
    tools.run(
        plan,
        "Preparing the relayer for messages between L1s",
        ["lab", "icm-config"] + command_args,
    )
    config = plan.store_service_files(
        name=RELAYER_NAME + "-config",
        service_name=tools.SERVICE_NAME,
        src=state + "/relayer",
    )
    plan.add_service(
        name=RELAYER_NAME,
        config=ServiceConfig(
            image=parsed["images"]["icm_relayer"],
            ports={
                "api": PortSpec(
                    number=constants.ICM_RELAYER_API_PORT_NUMBER,
                    application_protocol="http",
                    wait="2m",
                )
            },
            files={"/config": config},
            entrypoint=["/usr/bin/icm-relayer"],
            cmd=["--config-file=/config/config.json"],
            user=User(uid=0, gid=0),
        ),
    )
    tools.run(
        plan,
        "Sending and verifying application messages between every pair of L1s",
        ["lab", "icm-smoke"] + command_args,
    )
    plan.store_service_files(
        name="nightly-results",
        service_name=tools.SERVICE_NAME,
        src=state + "/results.json",
    )
    plan.remove_service(name=RELAYER_NAME)
    return manifest
