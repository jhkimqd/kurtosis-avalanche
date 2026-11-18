"""One AvalancheGo node. Every node of the devnet is started here.

A node's role decides its image and what it syncs:

  primary    Primary Network validator. Runs the P-, X-, and C-Chain.
  validator  L1 validator. Runs the L1 chain and follows the P-Chain.
  bootstrap  Temporary L1 validator, removed after PoS setup.
  rpc        L1 node that serves the RPC API and does not validate.
"""

constants = import_module("../config/constants.star")

# Mount points inside the node container.
CONFIG_PATH = "/config"  # node.json, and the P-, X-, and C-Chain configs
L1_CONFIG_PATH = "/l1"  # chain config and subnet config of the node's L1
NETWORK_PATH = "/network"  # genesis, upgrade schedule, node keys
DATA_PATH = "/data"  # database and logs


def launch(plan, args, network, name, role, index, bootstrap_peer=None, l1=None):
    """Starts one AvalancheGo node and returns its context.

    Args:
        args: parsed package arguments.
        network: struct(artifact, ...) from `tools.generate_network`.
        name: service name, also the node's hostname inside the enclave.
        role: one of `constants.NODE_ROLE`.
        index: which generated identity (`/network/nodes/<index>`) the node uses.
        bootstrap_peer: struct(node_id, ip_address) of the node to sync from,
            or None for the first node of the network.
        l1: struct(subnet_id, blockchain_id, config_artifact) of the L1 the
            node tracks, or None for a Primary Network validator.
    Returns:
        struct(name, role, ip_address, rpc_url).
    """
    is_primary = role == constants.NODE_ROLE.primary
    is_bootstrap = role == constants.NODE_ROLE.bootstrap
    section = args["primary_network"] if is_primary else args["l1"]
    keys_path = "{}/nodes/{}".format(NETWORK_PATH, index)

    # User flags first; the flags below wire the node into this devnet and win.
    flags = dict(section["node_config"])
    flags.update(
        {
            # Network identity.
            "network-id": str(constants.NETWORK_ID),
            "genesis-file": NETWORK_PATH + "/genesis.json",
            "upgrade-file": NETWORK_PATH + "/upgrade.json",
            # Node identity: the TLS key pair defines the node ID, the BLS key
            # signs Warp messages.
            "staking-tls-key-file": keys_path + "/staker.key",
            "staking-tls-cert-file": keys_path + "/staker.crt",
            "staking-signer-key-file": keys_path + "/signer.key",
            # Storage and listeners.
            "data-dir": DATA_PATH,
            "http-host": "0.0.0.0",
            "http-port": constants.NODE_HTTP_PORT_NUMBER,
            "staking-port": constants.NODE_STAKING_PORT_NUMBER,
            # Peers. AvalancheGo accepts only IP addresses here, not hostnames.
            "bootstrap-ids": bootstrap_peer.node_id if bootstrap_peer else "",
            "bootstrap-ips": (
                "{}:{}".format(
                    bootstrap_peer.ip_address, constants.NODE_STAKING_PORT_NUMBER
                )
                if bootstrap_peer
                else ""
            ),
        }
    )

    files = {NETWORK_PATH: network.artifact}
    # A temporary node keeps its data in the container, which is removed with it.
    if not is_bootstrap:
        files[DATA_PATH] = Directory(persistent_key=name + "-data")
    config_files = {"node.json": flags}
    if is_primary:
        flags["chain-config-dir"] = CONFIG_PATH + "/chains"
        config_files.update(
            {
                "chains/P/config.json": section["p_chain_config"],
                "chains/X/config.json": section["x_chain_config"],
                "chains/C/config.json": section["c_chain_config"],
            }
        )
    else:
        flags.update(
            {
                # Sync the L1 chain, and of the Primary Network only the P-Chain.
                "track-subnets": l1.subnet_id,
                "partial-sync-primary-network": True,
                "chain-config-dir": L1_CONFIG_PATH + "/chains",
                "subnet-config-dir": L1_CONFIG_PATH + "/subnets",
                # The Subnet-EVM image ships the VM plugin in this directory.
                "plugin-dir": "/avalanchego/build/plugins",
            }
        )
        files[L1_CONFIG_PATH] = l1.config_artifact
    files[CONFIG_PATH] = plan.render_templates(
        name=name + "-config",
        config={path: _json_file(content) for path, content in config_files.items()},
    )

    service = plan.add_service(
        name=name,
        config=ServiceConfig(
            image=args["images"]["avalanchego" if is_primary else "subnet_evm"],
            ports={
                constants.NODE_HTTP_PORT_ID: PortSpec(
                    number=constants.NODE_HTTP_PORT_NUMBER,
                    application_protocol="http",
                    wait="2m",
                ),
                constants.NODE_STAKING_PORT_ID: PortSpec(
                    number=constants.NODE_STAKING_PORT_NUMBER, wait="2m"
                ),
            },
            files=files,
            entrypoint=["/avalanchego/build/avalanchego"],
            cmd=[
                "--config-file={}/node.json".format(CONFIG_PATH),
                # Kurtosis replaces the placeholder with the container's IP address.
                "--public-ip=KURTOSIS_IP_ADDR_PLACEHOLDER",
            ],
            max_cpu=(
                constants.BOOTSTRAP_NODE_MAX_CPU
                if is_bootstrap
                else constants.NODE_MAX_CPU
            ),
            max_memory=(
                constants.BOOTSTRAP_NODE_MAX_MEMORY
                if is_bootstrap
                else constants.NODE_MAX_MEMORY
            ),
        ),
    )

    return struct(
        name=name,
        role=role,
        ip_address=service.ip_address,
        rpc_url="http://{}:{}".format(name, constants.NODE_HTTP_PORT_NUMBER),
    )


def _json_file(content):
    """Returns a template that writes `content` as a JSON file."""
    return struct(template="{{.content}}", data={"content": json.encode(content)})
