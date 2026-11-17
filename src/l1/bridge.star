commands = import_module("../tools.star")


def launch(plan, cfg, name, uri, rpc, state):
    commands.execute(plan, ["lab", "bridge-deploy", uri, rpc, state])
    bridge_addresses = commands.execute(
        plan,
        ["cat", state + "/bridge/contracts.json"],
        {
            "token": "fromjson | .Token",
            "home": "fromjson | .Home",
            "remote": "fromjson | .Remote",
            "messenger": "fromjson | .Messenger",
        },
    )
    bridge_addresses = {
        "token": bridge_addresses["extract.token"],
        "home": bridge_addresses["extract.home"],
        "remote": bridge_addresses["extract.remote"],
        "messenger": bridge_addresses["extract.messenger"],
    }
    relayer_config = plan.store_service_files(
        name=name + "-relayer-config",
        service_name="tools",
        src=state + "/bridge/relayer",
    )
    plan.add_service(
        name=name + "-relayer",
        config=ServiceConfig(
            image=cfg["relayer_image"],
            user=User(uid=0, gid=0),
            entrypoint=["/usr/bin/icm-relayer"],
            cmd=["--config-file=/config/config.json"],
            files={
                "/config": relayer_config,
                "/data": Directory(persistent_key=name + "-relayer"),
            },
            ports={
                "api": PortSpec(number=9091, application_protocol="http", wait="2m")
            },
        ),
    )
    commands.execute(plan, ["lab", "bridge-activate", uri, rpc, state])
    return bridge_addresses
