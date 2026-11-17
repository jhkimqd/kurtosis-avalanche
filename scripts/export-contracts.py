import hashlib
import json
import pathlib

out = pathlib.Path("static_files/contracts")
out.mkdir(parents=True, exist_ok=True)
manifest = {}
for directory, names in (
    (
        ".build/icm/out",
        (
            "ValidatorMessages",
            "ValidatorManager",
            "NativeTokenStakingManager",
            "ERC20TokenStakingManager",
            "ExampleRewardCalculator",
            "TeleporterMessenger",
            "TeleporterRegistry",
            "ERC20TokenHome",
            "NativeTokenRemote",
        ),
    ),
    ("contracts/out", ("StakingToken", "CashToken")),
):
    for name in names:
        source = pathlib.Path(directory) / (name + ".sol") / (name + ".json")
        data = json.loads(source.read_text())
        content = (
            json.dumps(
                {"abi": data["abi"], "bytecode": data["bytecode"]}, sort_keys=True
            )
            + "\n"
        )
        (out / (name + ".json")).write_text(content)
        manifest[name] = hashlib.sha256(content.encode()).hexdigest()
(out / "hashes.json").write_text(json.dumps(manifest, indent=2) + "\n")
