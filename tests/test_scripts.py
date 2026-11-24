"""The bash helpers of the setup scripts (static_files/scripts) encode what Avalanche expects.

The expected bytes come from the AvalancheGo code at the pinned commit
(ids, vms/platformvm/warp, proto/pb/platformvm), computed once with Go.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import starlark

SCRIPTS = starlark.ROOT / "static_files/scripts"
CONTRACTS = starlark.ROOT / "static_files/contracts"

HAS_JQ = shutil.which("jq") is not None
HAS_CAST = shutil.which("cast") is not None
if os.environ.get("CI") and not HAS_JQ:
    raise RuntimeError("the script tests need jq")


def bash(script, source="lib.sh", check=True):
    """Runs bash code after sourcing a script and returns its stdout."""
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; ' + script, "bash", str(SCRIPTS / source)],
        capture_output=True,
        text=True,
        env=dict(os.environ, CONTRACTS=str(CONTRACTS)),
    )
    if check and result.returncode != 0:
        raise AssertionError("bash failed: {}\n{}".format(script, result.stderr))
    return result


def out(script, source="lib.sh"):
    return bash(script, source).stdout.strip()


SUBNET = "18507519c552a7b98b138ed04dacd2f7d126534fcafea5deb68b496316e814d8"
CONVERSION = "0b236a746870a6b8646123c53e8ba14c1db50d9a961c5160188d7e4621038318"
VALIDATION = "98c41dcd20b86b86830ec0794559835614458ceaae0f0ec77a3ed1cd3a1f7d55"
# Unsigned Warp message from the P-Chain of network 88888 (0x15b38), with an
# AddressedCall payload around the message.
WARP_PREFIX = "0x000000015b38" + "00" * 32


class EncodingTest(unittest.TestCase):
    def test_cb58_round_trip(self):
        for hex_value, text in [
            ("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
             "2YDwHaXxuAcsLRTLcHEFaF1xQkbgzjM5rQu3mMzuCHamTuqiGo"),
            ("3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d",
             "UNHo2MdxVtikDN9FX6U6URGnUwxoqYgRXKpr7Hp1FETr64Rkt"),
            ("00" * 32, "11111111111111111111111111111111LpoYY"),
        ]:
            with self.subTest(text=text):
                self.assertEqual(out("cb58_decode " + text), hex_value)
                self.assertEqual(out("cb58_encode 0x" + hex_value), text)
        # A node ID: 20 bytes, with leading zero bytes, and its prefix.
        self.assertEqual(out("cb58_decode NodeID-11GsCgfjY9YaLSHXWomQhdKsWBPgh2P"), "0000010203" + "00" * 15)

    def test_cb58_rejects_a_bad_checksum(self):
        result = bash("cb58_decode 2YDwHaXxuAcsLRTLcHEFaF1xQkbgzjM5rQu3mMzuCHamTuqiGa", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stderr)

    def test_fingerprint_covers_every_argument(self):
        # Flags, spaces, newlines, and empty strings stay distinct arguments.
        self.assertEqual(
            json.loads(out('json_array chain create --subnet-id "a b" $'"'"'x\\ny'"'"' ""')),
            ["chain", "create", "--subnet-id", "a b", "x\ny", ""],
        )
        self.assertEqual(out("json_array"), "[]")
        self.assertNotEqual(out("fingerprint create --subnet-id X"), out("fingerprint create --subnet-id Y"))
        self.assertNotEqual(out("fingerprint a b"), out("fingerprint 'a b'"))

    def test_a_failure_inside_a_substitution_stops_the_function(self):
        result = bash("f() { local x; x=$(false; echo after); echo reached; }; f", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reached", result.stdout)

    def test_pchain_journals_do_not_replace_result_files(self):
        # l1.sh writes chain.json and conversion.json as results; the P-Chain
        # journals of the same steps must have other names.
        lib = (SCRIPTS / "lib.sh").read_text()
        self.assertIn("finished=$dir/$name.pchain.json", lib)
        self.assertIn("pending=$dir/$name.pending.pchain.json", lib)

    def test_large_numbers(self):
        self.assertEqual(out("big_add 999999999999999999999 1"), "1000000000000000000000")
        self.assertEqual(out("big_add 0 0"), "0")
        self.assertEqual(out("big_ge 10 9 && big_ge 5 5 && ! big_ge 9 10 && echo ok"), "ok")


@unittest.skipUnless(HAS_JQ, "needs jq")
class WarpMessageTest(unittest.TestCase):
    def test_conversion_message(self):
        self.assertEqual(
            out("conversion_message " + CONVERSION),
            WARP_PREFIX + "00000034" + "0000000000010000000000000026" + "000000000000" + CONVERSION,
        )

    def test_registration_messages(self):
        for registered, flag in (("true", "01"), ("false", "00")):
            with self.subTest(registered=registered):
                self.assertEqual(
                    out("registration_message 0x{} {}".format(VALIDATION, registered)),
                    WARP_PREFIX + "00000035" + "0000000000010000000000000027" + "000000000002" + VALIDATION + flag,
                )

    def test_removal_justification(self):
        # Protobuf leaves out an index of 0 and writes larger ones as varints.
        for index, tail in (("0", ""), ("1", "1001"), ("3", "1003"), ("200", "10c801"), ("70000", "10f0a204")):
            with self.subTest(index=index):
                inner = "0a20" + SUBNET + tail
                self.assertEqual(
                    out("removal_justification {} {}".format(SUBNET, index)),
                    "0x0a{:02x}{}".format(len(inner) // 2, inner),
                )

    def test_payload_message_and_validation_id(self):
        message = out("warp_payload_message $(registration_message {} true)".format(VALIDATION))
        self.assertEqual(message, "000000000002" + VALIDATION + "01")

    def test_predicate_packs_the_message_into_storage_keys(self):
        access = json.loads(out("predicate 0x" + "ab" * 40))
        self.assertEqual(access[0]["address"], "0x0200000000000000000000000000000000000005")
        data = "".join(key[2:] for key in access[0]["storageKeys"])
        # The message, the end marker 0xff, and zero padding to whole words.
        self.assertEqual(data, "ab" * 40 + "ff" + "00" * 23)

    def test_contract_signatures_come_from_the_artifacts(self):
        # Every method that the scripts call, with its cast signature.
        for contract, method, signature in [
            ("ValidatorManager", "initialize", "initialize((address,bytes32,uint64,uint8))()"),
            ("ValidatorManager", "initializeValidatorSet",
             "initializeValidatorSet((bytes32,bytes32,address,(bytes,bytes,uint64)[]),uint32)()"),
            ("ValidatorManager", "getChurnTracker", "getChurnTracker()(uint64,uint8,(uint256,uint64,uint64,uint64))"),
            ("ValidatorManager", "getValidator", "getValidator(bytes32)((uint8,bytes,uint64,uint64,uint64,uint64,uint64,uint64))"),
            ("ValidatorManager", "getNodeValidationID", "getNodeValidationID(bytes)(bytes32)"),
            ("ValidatorManager", "transferOwnership", "transferOwnership(address)()"),
            ("ValidatorManager", "owner", "owner()(address)"),
            ("NativeTokenStakingManager", "initialize",
             "initialize((address,uint256,uint256,uint64,uint16,uint8,uint256,address,bytes32))()"),
            ("NativeTokenStakingManager", "initiateValidatorRegistration",
             "initiateValidatorRegistration(bytes,bytes,(uint32,address[]),(uint32,address[]),uint16,uint64,address)(bytes32)"),
            ("ERC20TokenStakingManager", "initiateValidatorRegistration",
             "initiateValidatorRegistration(bytes,bytes,(uint32,address[]),(uint32,address[]),uint16,uint64,uint256,address)(bytes32)"),
            ("ERC20TokenStakingManager", "initialize",
             "initialize((address,uint256,uint256,uint64,uint16,uint8,uint256,address,bytes32),address)()"),
            ("NativeTokenStakingManager", "initiateValidatorRemoval", "initiateValidatorRemoval(bytes32,bool,uint32)()"),
            ("NativeTokenStakingManager", "completeValidatorRegistration", "completeValidatorRegistration(uint32)(bytes32)"),
            ("NativeTokenStakingManager", "completeValidatorRemoval", "completeValidatorRemoval(uint32)(bytes32)"),
            ("NativeTokenStakingManager", "getStakingValidator", "getStakingValidator(bytes32)((address,uint16,uint64,uint64))"),
            ("StakingToken", "mint", "mint(address,uint256)()"),
            ("StakingToken", "setRewardMinter", "setRewardMinter(address)()"),
            ("StakingToken", "balanceOf", "balanceOf(address)(uint256)"),
            ("CashToken", "approve", "approve(address,uint256)(bool)"),
            ("CashToken", "balanceOf", "balanceOf(address)(uint256)"),
            ("ERC20TokenHome", "send", "send((bytes32,address,address,address,uint256,uint256,uint256,address),uint256)()"),
            ("ERC20TokenHome", "addCollateral", "addCollateral(bytes32,address,uint256)()"),
            ("ERC20TokenHome", "getRemoteTokenTransferrerSettings",
             "getRemoteTokenTransferrerSettings(bytes32,address)((bool,uint256,uint256,bool))"),
            ("NativeTokenRemote", "registerWithHome", "registerWithHome((address,uint256))()"),
            ("NativeTokenRemote", "getIsCollateralized", "getIsCollateralized()(bool)"),
            ("TeleporterMessenger", "sendCrossChainMessage",
             "sendCrossChainMessage((bytes32,address,(address,uint256),uint256,address[],bytes))(bytes32)"),
            ("TeleporterMessenger", "messageReceived", "messageReceived(bytes32)(bool)"),
            ("MessageReceiver", "receivedMessages", "receivedMessages(bytes32)(bool)"),
        ]:
            with self.subTest(contract=contract, method=method):
                self.assertEqual(out("abi_signature {} {}".format(contract, method)), signature)
        self.assertNotEqual(bash("abi_signature ValidatorManager missing", check=False).returncode, 0)

    def test_library_linking(self):
        code = out('link_bytecode ValidatorManager 0x' + "ab" * 20)
        self.assertNotIn("__$", code)
        self.assertIn("ab" * 20, code)
        self.assertNotEqual(bash("link_bytecode ValidatorManager ''", check=False).returncode, 0)


@unittest.skipUnless(HAS_JQ, "needs jq")
class L1GenesisTest(unittest.TestCase):
    BASE = str(starlark.ROOT / "static_files/l1-genesis.json")

    def genesis(self, overrides, bridge="false"):
        return json.loads(out("l1_genesis {} 77777 '{}' {}".format(self.BASE, json.dumps(overrides), bridge), "l1.sh"))

    def test_chain_id_and_header_gas_limit(self):
        genesis = self.genesis({"config": {"feeConfig": {"gasLimit": 15000000}}})
        self.assertEqual(genesis["config"]["chainId"], 77777)
        # Subnet-EVM refuses a genesis whose header limit differs from the fee config.
        self.assertEqual(genesis["gasLimit"], "0xe4e1c0")
        self.assertNotIn("contractNativeMinterConfig", genesis["config"])

    def test_alloc_override_replaces_the_base_account(self):
        # The base genesis funds EWOQ in lowercase without 0x.
        genesis = self.genesis({"alloc": {"0x8DB97C7CECE249C2B98BDC0226CC4C2A57BF52FC": {"balance": "0x1"}}})
        self.assertEqual(genesis["alloc"], {"8db97c7cece249c2b98bdc0226cc4c2a57bf52fc": {"balance": "0x1"}})

    def test_null_keeps_and_lists_replace(self):
        genesis = self.genesis({"config": {"feeConfig": None, "warpConfig": {"quorumNumerator": 80}}, "extraData": None})
        self.assertEqual(genesis["config"]["feeConfig"]["gasLimit"], 20000000)
        self.assertEqual(genesis["config"]["warpConfig"]["quorumNumerator"], 80)
        self.assertTrue(genesis["config"]["warpConfig"]["requirePrimaryNetworkSigners"])
        self.assertEqual(genesis["extraData"], "0x00")

    def test_invalid_gas_limit_fails(self):
        for limit in (0, 1.5, "20000000"):
            with self.subTest(limit=limit):
                result = bash("l1_genesis {} 1 '{}' false".format(
                    self.BASE, json.dumps({"config": {"feeConfig": {"gasLimit": limit}}})), "l1.sh", check=False)
                self.assertNotEqual(result.returncode, 0)

    def test_duplicate_alloc_account_fails(self):
        result = bash("l1_genesis {} 1 '{}' false".format(self.BASE, json.dumps(
            {"alloc": {"0xAB" + "00" * 19: {"balance": "0x1"}, "ab" + "00" * 19: {"balance": "0x2"}}})), "l1.sh", check=False)
        self.assertNotEqual(result.returncode, 0)

    @unittest.skipUnless(HAS_CAST, "needs cast")
    def test_bridge_lets_the_remote_mint(self):
        genesis = self.genesis({}, "true")
        # NativeTokenRemote is the first contract of development key 10.
        self.assertEqual(
            genesis["config"]["contractNativeMinterConfig"],
            {"blockTimestamp": 0, "enabledAddresses": ["0x48c078E40EB579de197F291E128C632aFDa2EF21"]},
        )


@unittest.skipUnless(HAS_JQ, "needs jq")
class JournalTest(unittest.TestCase):
    """pchain_step and atomic_write, with platform-cli and the node replaced."""

    STUBS = (
        'deployment_identity() { echo test-deployment; }; '
        'platform() { echo "$*" >>"$DIR/calls"; echo "Increase L1 Validator Balance TX: tx$(($(wc -l <"$DIR/calls")))"; }; '
        'none() { echo -; }; again() { echo retry; }; '
    )

    def step(self, directory, check="-"):
        return bash(self.STUBS + 'DIR={0}; pchain_step uri {0} topup {1} "TX: ([[:alnum:]]+)" -- l1 increase-validator-balance --balance 1'
                    .format(directory, check), check=False)

    def test_a_finished_step_sends_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.step(directory).stdout.strip(), "tx1")
            self.assertEqual(self.step(directory).stdout.strip(), "tx1")
            self.assertEqual(Path(directory, "calls").read_text().count("\n"), 1)
            self.assertFalse(Path(directory, "topup.pending.pchain.json").exists())

    def test_a_pending_step_without_proof_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "topup.pending.pchain.json").write_text(json.dumps({"fingerprint": out(
                "fingerprint test-deployment l1 increase-validator-balance --balance 1")}))
            for check in ("-", "none"):
                result = self.step(directory, check)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("may have been sent", result.stderr)
            self.assertFalse(Path(directory, "calls").exists())
            # A step that is harmless to repeat sends again.
            self.assertEqual(self.step(directory, "again").stdout.strip(), "tx1")

    def test_other_inputs_do_not_reuse_a_journal(self):
        with tempfile.TemporaryDirectory() as directory:
            self.step(directory)
            result = bash(self.STUBS + 'DIR={0}; pchain_step uri {0} topup - "TX: (\\w+)" -- l1 increase-validator-balance --balance 2'
                          .format(directory), check=False)
            self.assertIn("journal input mismatch", result.stderr)

    def test_atomic_write_refuses_empty_input(self):
        with tempfile.TemporaryDirectory() as directory:
            result = bash("false | atomic_write {}/x.json".format(directory), check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(Path(directory, "x.json").exists())
            self.assertEqual(out("echo 1 | atomic_write {0}/x.json; cat {0}/x.json".format(directory)), "1")

    def test_view_reads_both_json_shapes_of_cast(self):
        # `cast call --json` prints a bare array; other cast commands wrap it.
        for printed in ('[1,["2",3]]', '{"schema_version":1,"data":[1,["2",3]]}'):
            with self.subTest(printed=printed):
                self.assertEqual(
                    out("cast() {{ echo '{}'; }}; view url ValidatorManager 0x0 getChurnTracker".format(printed)),
                    '[1,["2",3]]',
                )


class GuardTest(unittest.TestCase):
    def test_signing_scripts_refuse_to_run_outside_the_tools_service(self):
        for script, args in [("l1.sh", ["create"]), ("staking.sh", ["migrate"]), ("bridge.sh", ["deploy"]),
                             ("icm.sh", ["config"]), ("checks.sh", ["transfers", "http://x", "1"])]:
            with self.subTest(script=script):
                env = {key: value for key, value in os.environ.items() if key != "TOOLS_INSTANCE"}
                result = subprocess.run(["bash", str(SCRIPTS / script)] + args, capture_output=True, text=True, env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("only in the tools service", result.stderr)

    def test_scripts_sign_only_for_the_local_network(self):
        self.assertEqual(out("echo $NETWORK_ID"), "88888")
        self.assertIn('[[ $got == "$NETWORK_ID" ]]', (SCRIPTS / "lib.sh").read_text())


if __name__ == "__main__":
    unittest.main()
