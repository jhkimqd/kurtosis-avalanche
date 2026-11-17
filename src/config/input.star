def parse(args):
    allowed = ["image_id", "metrics", "staking", "instance_id", "schema_version", "l1_count", "validator_count", "smoke_transactions", "node_memory_mb", "node_cpu_millicores", "image"]
    for key in args:
        if key not in allowed:
            fail("Unknown input '{}'; supported inputs: {}".format(key, allowed))
    config = {"image_id": "unverified", "metrics": True, "staking": "poa", "instance_id": "manual", "schema_version": 1, "l1_count": 1, "validator_count": 4, "smoke_transactions": 5, "node_memory_mb": 1536, "node_cpu_millicores": 1000, "image": "avalanche-lab:local"}
    config.update(args)
    if config["schema_version"] != 1:
        fail("Unsupported schema_version")
    for key, low, high in [("l1_count", 1, 2), ("validator_count", 1, 4), ("smoke_transactions", 1, 1000), ("node_memory_mb", 512, 16384), ("node_cpu_millicores", 100, 16000)]:
        value = config[key]
        if type(value) != "int" or value < low or value > high:
            fail("{} must be an integer in [{}, {}]".format(key, low, high))
    if type(config["image"]) != "string" or not config["image"]:
        fail("image must name the locally built image")
    if config["staking"] not in ["poa", "native-pos", "erc20-pos"]:
        fail("staking must be poa, native-pos or erc20-pos; other profiles are not certified")
    if type(config["metrics"]) != "bool":
        fail("metrics must be a boolean")
    if type(config["instance_id"]) != "string" or not config["instance_id"] or config["instance_id"] == "manual":
        fail("instance_id must be a nonempty string")
    return config
