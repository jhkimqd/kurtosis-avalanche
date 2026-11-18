"""Optional ICM token bridge between the C-Chain and one L1.

The C-Chain side (ERC20TokenHome) locks CASH, an ERC-20 token the package
deploys. The L1 side (NativeTokenRemote) mints the same amount as the L1's
native token. An ICM relayer carries the messages between the two chains.
"""

constants = import_module("../config/constants.star")
tools = import_module("../tools/launcher.star")


def launch(plan, args, l1_name, state_path, primary_rpc_url, l1_rpc_url):
    """Deploys the bridge contracts, starts the relayer, and funds the bridge.

    Returns:
        A dict of contract addresses: `token` and `home` on the C-Chain,
        `remote` on the L1, and `messenger` on both.
    """
    chains = [primary_rpc_url, l1_rpc_url, state_path]

    tools.run(
        plan,
        "Deploying the ICM messenger and bridge contracts for {}".format(l1_name),
        ["lab", "bridge-deploy"] + chains,
    )
    addresses = tools.read_json(
        plan,
        state_path + "/bridge/contracts.json",
        {
            "token": ".Token",
            "home": ".Home",
            "remote": ".Remote",
            "messenger": ".Messenger",
        },
    )

    # `lab bridge-deploy` also wrote the relayer configuration.
    relayer_config = plan.store_service_files(
        name=l1_name + "-relayer-config",
        service_name=tools.SERVICE_NAME,
        src=state_path + "/bridge/relayer",
    )
    plan.add_service(
        name=l1_name + "-relayer",
        config=ServiceConfig(
            image=args["images"]["icm_relayer"],
            ports={
                "api": PortSpec(
                    number=constants.ICM_RELAYER_API_PORT_NUMBER,
                    application_protocol="http",
                    wait="2m",
                )
            },
            files={
                "/config": relayer_config,
                # Remembers the last relayed block of each chain across restarts.
                "/data": Directory(persistent_key=l1_name + "-relayer-data"),
            },
            entrypoint=["/usr/bin/icm-relayer"],
            cmd=["--config-file=/config/config.json"],
            # The persistent directory is owned by root.
            user=User(uid=0, gid=0),
        ),
    )

    # The L1 side registers with the C-Chain side through the relayer. The
    # C-Chain side then receives collateral for the L1's genesis token supply.
    tools.run(
        plan,
        "Registering the {} bridge and adding collateral".format(l1_name),
        ["lab", "bridge-activate"] + chains,
    )
    return addresses


def verify(plan, l1_name, state_path, primary_rpc_url, l1_rpc_url):
    """Bridges tokens from the C-Chain and spends them as gas on the L1."""
    tools.run(
        plan,
        "Bridging tokens from the C-Chain to {}".format(l1_name),
        ["lab", "bridge-smoke", primary_rpc_url, l1_rpc_url, state_path],
    )
