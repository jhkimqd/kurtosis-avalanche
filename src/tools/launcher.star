"""The tools service: a container with the `lab` Go binary (see tools/main.go).

The package runs `lab` commands in this service to generate node identities,
sign transactions, and verify the result. `lab` records each step under /state,
so the directory holds the complete history of a deployment. At the end, a
shell script describes each network of the devnet in /opt/networks.
"""

constants = import_module("../config/constants.star")

SERVICE_NAME = "tools"

# Persistent state: one journal per transaction, plus all generated files.
STATE_PATH = "/state"
# Genesis, upgrade schedule, and node keys (written by `lab prepare`).
NETWORK_PATH = STATE_PATH + "/network"
# Description of the devnet for its users, one directory per network: IDs, RPC
# URLs, validators, genesis, and development accounts.
DESCRIPTION_PATH = "/opt/networks"
# The files of ./static_files. The tools read the base L1 genesis, the contract
# artifacts, and the scripts; the observability files are for other services.
STATIC_FILES_PATH = "/fixtures"
# The shell script that writes `DESCRIPTION_PATH` (needs bash, curl, and jq).
DESCRIBE_SCRIPT = STATIC_FILES_PATH + "/scripts/describe-networks.sh"


def launch(plan, args):
    """Starts the tools service. It idles until the package runs a command."""
    static_files = plan.upload_files(name="static-files", src="../../static_files")
    image = args["images"]["tools"]
    if image == "":
        image = ImageBuildSpec(
            image_name="avalanche-tools:local", build_context_dir="../../tools"
        )
    plan.add_service(
        name=SERVICE_NAME,
        config=ServiceConfig(
            image=image,
            files={
                STATIC_FILES_PATH: static_files,
                STATE_PATH: Directory(persistent_key="tools-state"),
            },
            # `lab` signs only where this variable is set. It guards against
            # an accidental run of the binary outside the tools service.
            env_vars={"LAB_INSTANCE": "devnet"},
            entrypoint=["sleep"],
            cmd=["infinity"],
        ),
    )


def run(plan, description, command):
    """Runs a command in the tools service and fails the deployment on error."""
    return plan.exec(
        service_name=SERVICE_NAME,
        description=description,
        recipe=ExecRecipe(command=command),
    )


def read_json(plan, path, fields):
    """Reads fields of a JSON file in the tools service.

    Args:
        path: file inside the tools service.
        fields: mapping of result name to jq path, for example {"id": ".subnet_id"}.
    Returns:
        A dict of result name to runtime value.
    """
    result = plan.exec(
        service_name=SERVICE_NAME,
        description="Reading {}".format(path),
        recipe=ExecRecipe(
            command=["cat", path],
            extract={name: "fromjson | " + query for name, query in fields.items()},
        ),
    )
    return {name: result["extract." + name] for name in fields}


def generate_network(plan, node_count, primary_validator_count):
    """Generates the genesis, the upgrade schedule, and the keys of every node.

    Args:
        node_count: total number of nodes the deployment will ever start.
        primary_validator_count: the first nodes become Primary Network validators.
    Returns:
        struct(artifact, bootstrap_node_id): the files to mount at `/network`
        and the node ID of node 0, which every other node syncs from.
    """
    run(
        plan,
        "Generating the Primary Network genesis and {} node identities".format(
            node_count
        ),
        ["lab", "prepare", NETWORK_PATH, str(node_count), str(primary_validator_count)],
    )
    artifact = plan.store_service_files(
        name="network", service_name=SERVICE_NAME, src=NETWORK_PATH
    )
    node = read_json(plan, NETWORK_PATH + "/network.json", {"id": ".nodes[0].node_id"})
    return struct(artifact=artifact, bootstrap_node_id=node["id"])


def describe(plan, manifest):
    """Describes each network of the devnet in `DESCRIPTION_PATH`.

    A shell script writes one directory per network: `primary-network` and
    one per L1. A user can edit the script under /fixtures and run it again.

    Args:
        manifest: the deployment manifest (main.star).
    Returns:
        The files artifact `network-description` with the same files.
    """
    run(
        plan,
        "Describing each network of the devnet in {}".format(DESCRIPTION_PATH),
        ["bash", DESCRIBE_SCRIPT, DESCRIPTION_PATH, json.encode(manifest)],
    )
    return plan.store_service_files(
        name="network-description", service_name=SERVICE_NAME, src=DESCRIPTION_PATH
    )
