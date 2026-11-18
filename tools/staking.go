package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/vms/platformvm/signer"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/message"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/payload"
	pwallet "github.com/ava-labs/avalanchego/wallet/chain/p/wallet"
	options "github.com/ava-labs/avalanchego/wallet/subnet/primary/common"
	ethereum "github.com/ava-labs/libevm"
	"github.com/ava-labs/libevm/accounts/abi"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/crypto"
	"github.com/ava-labs/libevm/ethclient"
)

// epochHeight returns the P-Chain height of the current ProposerVM epoch of a
// chain. Validators check a Warp message against the validator set at that
// height.
func epochHeight(ctx context.Context, endpoint string) (uint64, error) {
	var raw map[string]json.RawMessage
	if e := rpc(ctx, endpoint, "proposervm.getCurrentEpoch", map[string]any{}, &raw); e != nil {
		return 0, e
	}
	var height uint64
	_, e := fmt.Sscan(strings.Trim(string(raw["pChainHeight"]), "\""), &height)
	return height, e
}

// proof returns an aggregated Warp signature and keeps it in a file. A rerun
// must reuse the same proof, because the proof is an input of a journaled
// transaction.
func proof(ctx context.Context, aggregator, path string, request any) ([]byte, error) {
	b, e := os.ReadFile(path)
	if e == nil {
		return b, nil
	}
	if !os.IsNotExist(e) {
		return nil, e
	}
	b, e = aggregate(ctx, aggregator, request)
	if e != nil {
		return nil, e
	}
	if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return nil, e
	}
	f, e := os.CreateTemp(filepath.Dir(path), "proof-")
	if e != nil {
		return nil, e
	}
	defer os.Remove(f.Name())
	if _, e = f.Write(b); e != nil {
		f.Close()
		return nil, e
	}
	if e = f.Sync(); e != nil {
		f.Close()
		return nil, e
	}
	if e = f.Close(); e != nil {
		return nil, e
	}
	if e = os.Rename(f.Name(), path); e != nil {
		return nil, e
	}
	return b, nil
}

// view calls a read-only contract method and returns the decoded outputs.
func view(ctx context.Context, url, contract string, address common.Address, method string, args ...any) ([]any, error) {
	_, a, e := artifact(contract)
	if e != nil {
		return nil, e
	}
	data, e := a.Pack(method, args...)
	if e != nil {
		return nil, e
	}
	client, e := ethclient.DialContext(ctx, url)
	if e != nil {
		return nil, e
	}
	defer client.Close()
	result, e := client.CallContract(ctx, ethereum.CallMsg{To: &address, Data: data}, nil)
	if e != nil {
		return nil, e
	}
	return a.Unpack(method, result)
}

// migrate moves an L1 from Proof of Authority to Proof of Stake and stakes one
// validator, the node with the given index.
//
// The first call deploys the staking manager (NativeTokenStakingManager or
// ERC20TokenStakingManager) and a reward calculator, and makes the staking
// manager the owner of the ValidatorManager. Later calls find these steps in
// the journals and skip them. Each call then registers one validator:
//
//  1. initiateValidatorRegistration on the L1 locks the stake and sends a Warp
//     message.
//  2. RegisterL1ValidatorTx carries that message, signed by the L1 validators,
//     to the P-Chain. It also pays 100 AVAX into the validator's fee balance.
//  3. completeValidatorRegistration returns the P-Chain's confirmation to the L1.
//
// The validators named at conversion hold no stake. finalizePoS removes them.
func migrate(ctx context.Context, uri, url, dir, aggregator string, nodeIndex int, mode string) error {
	if e := localOnly(ctx, uri); e != nil {
		return e
	}
	var c Chain
	b, e := os.ReadFile(filepath.Join(dir, "chain.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &c); e != nil {
		return e
	}
	if !strings.HasSuffix(url, "/ext/bc/"+c.Chain+"/rpc") {
		return fmt.Errorf("migration RPC must be the deployed L1")
	}
	var managerInfo struct{ Address, Library string }
	b, e = os.ReadFile(filepath.Join(dir, "manager.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &managerInfo); e != nil {
		return e
	}
	manager := common.HexToAddress(managerInfo.Address)
	library := common.HexToAddress(managerInfo.Library)
	sid, e := ids.FromString(c.Subnet)
	if e != nil {
		return e
	}
	cid, e := ids.FromString(c.Chain)
	if e != nil {
		return e
	}
	if mode != "native-pos" && mode != "erc20-pos" {
		return fmt.Errorf("unsupported staking mode")
	}
	contract := "NativeTokenStakingManager"
	if mode == "erc20-pos" {
		contract = "ERC20TokenStakingManager"
	}
	profilePath := filepath.Join(dir, "migration-profile.json")
	var profile struct {
		Mode string `json:"mode"`
	}
	if b, e = os.ReadFile(profilePath); e == nil {
		if e = json.Unmarshal(b, &profile); e != nil {
			return e
		}
		if profile.Mode != mode {
			return fmt.Errorf("deployment already selected migration profile %s", profile.Mode)
		}
	} else if os.IsNotExist(e) {
		if e = save(profilePath, map[string]string{"mode": mode}); e != nil {
			return e
		}
	} else {
		return e
	}
	migration := filepath.Join(dir, mode)
	staking, e := deploy(ctx, url, migration, contract, library, uint8(0))
	if e != nil {
		return e
	}
	reward, e := deploy(ctx, url, migration, "ExampleRewardCalculator", common.Address{}, uint64(0))
	if e != nil {
		return e
	}
	// Staking rules of the L1, in field order:
	//
	//	minimum stake              1 token
	//	maximum stake              10 tokens
	//	minimum stake duration     60 seconds
	//	minimum delegation fee     1 basis point (0.01%)
	//	maximum stake multiplier   4: stake plus delegations of at most 4 times
	//	                           the stake, so delegations of up to 3 times
	//	weight-to-value factor     5e12 wei per unit of P-Chain weight, so a
	//	                           stake of 1 token has weight 200000
	//	reward calculator          ExampleRewardCalculator with a rate of 0
	//	uptime blockchain          the L1 itself
	settings := struct {
		Manager                  common.Address
		MinimumStakeAmount       *big.Int
		MaximumStakeAmount       *big.Int
		MinimumStakeDuration     uint64
		MinimumDelegationFeeBips uint16
		MaximumStakeMultiplier   uint8
		WeightToValueFactor      *big.Int
		RewardCalculator         common.Address
		UptimeBlockchainID       [32]byte
	}{manager, big.NewInt(1e18), new(big.Int).Mul(big.NewInt(10), big.NewInt(1e18)), 60, 1, 4, big.NewInt(5000000000000), reward, cid}
	var token common.Address
	if mode == "erc20-pos" {
		token, e = deploy(ctx, url, migration, "StakingToken", common.Address{})
		if e != nil {
			return e
		}
		if e = invoke(ctx, url, filepath.Join(migration, fmt.Sprintf("fund-%d", nodeIndex)), "mint", "StakingToken", token, nil, genesis.EWOQKey.EthAddress(), big.NewInt(1e18)); e != nil {
			return e
		}
		if e = invoke(ctx, url, migration, "setRewardMinter", "StakingToken", token, nil, staking); e != nil {
			return e
		}
		if e = invoke(ctx, url, filepath.Join(migration, fmt.Sprintf("fund-%d", nodeIndex)), "approve", "StakingToken", token, nil, staking, big.NewInt(1e18)); e != nil {
			return e
		}
		if e = invoke(ctx, url, migration, "initialize", contract, staking, nil, settings, token); e != nil {
			return e
		}
	} else {
		if e = invoke(ctx, url, migration, "initialize", contract, staking, nil, settings); e != nil {
			return e
		}
	}
	if e = invoke(ctx, url, migration, "transferOwnership", "ValidatorManager", manager, nil, staking); e != nil {
		return e
	}
	owner, e := view(ctx, url, "ValidatorManager", manager, "owner")
	if e != nil {
		return e
	}
	if owner[0].(common.Address) != staking {
		return fmt.Errorf("manager ownership did not transfer")
	}
	var network struct {
		Nodes []struct {
			ID  string                   `json:"node_id"`
			POP signer.ProofOfPossession `json:"pop"`
		} `json:"nodes"`
	}
	b, e = os.ReadFile("/state/network/network.json")
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &network); e != nil {
		return e
	}
	// Register the node: stake 1 token with a delegation fee of 1 basis point
	// and a minimum duration of 60 seconds. The EWOQ account owns the
	// validator and receives its rewards.
	if nodeIndex < 0 || nodeIndex >= len(network.Nodes) {
		return fmt.Errorf("invalid fixture index")
	}
	n := network.Nodes[nodeIndex]
	nid, e := ids.NodeIDFromString(n.ID)
	if e != nil {
		return e
	}
	paddr := genesis.EWOQKey.Address()
	pOwner := struct {
		Threshold uint32
		Addresses []common.Address
	}{1, []common.Address{common.BytesToAddress(paddr[:])}}
	_, a, e := artifact(contract)
	if e != nil {
		return e
	}
	migration = filepath.Join(migration, fmt.Sprintf("validator-%d", nodeIndex))
	registrationArgs := []any{nid[:], n.POP.PublicKey[:], pOwner, pOwner, uint16(1), uint64(60)}
	value := big.NewInt(1e18)
	if mode == "erc20-pos" {
		registrationArgs = append(registrationArgs, big.NewInt(1e18))
		value = big.NewInt(0)
	}
	registrationArgs = append(registrationArgs, genesis.EWOQKey.EthAddress())
	data, e := a.Pack("initiateValidatorRegistration", registrationArgs...)
	if e != nil {
		return e
	}
	if e = waitChurn(ctx, url, manager, migration); e != nil {
		return e
	}
	receipt, e := evmTx(ctx, url, migration, "register-request", &staking, data, value, nil)
	if e != nil {
		return e
	}
	bytesType, _ := abi.NewType("bytes", "", nil)
	var unsignedBytes []byte
	for _, log := range receipt.Logs {
		if log.Address == common.HexToAddress("0x0200000000000000000000000000000000000005") && len(log.Topics) > 0 && log.Topics[0] == crypto.Keccak256Hash([]byte("SendWarpMessage(address,bytes32,bytes)")) {
			values, e := (abi.Arguments{{Type: bytesType}}).Unpack(log.Data)
			if e != nil {
				return e
			}
			unsignedBytes = values[0].([]byte)
		}
	}
	if len(unsignedBytes) == 0 {
		return fmt.Errorf("registration receipt has no Warp message")
	}
	unsigned, e := warp.ParseUnsignedMessage(unsignedBytes)
	if e != nil {
		return e
	}
	call, e := payload.ParseAddressedCall(unsigned.Payload)
	if e != nil {
		return e
	}
	registration, e := message.ParseRegisterL1Validator(call.Payload)
	if e != nil {
		return e
	}
	validationID := registration.ValidationID()
	var validators struct {
		Validators []struct {
			ValidationID string `json:"validationID"`
		} `json:"validators"`
	}
	if e = rpc(ctx, uri+"/ext/bc/P", "platform.getCurrentValidators", map[string]any{"subnetID": c.Subnet}, &validators); e != nil {
		return e
	}
	if len(validators.Validators) == 0 {
		return fmt.Errorf("no initial validators")
	}
	// Add 1 AVAX to the fee balance of an existing validator. The transaction
	// makes the P-Chain produce a block before its epoch height is read below.
	initialTarget := filepath.Join(migration, "topup-target.json")
	initialText := validators.Validators[0].ValidationID
	if b, e = os.ReadFile(initialTarget); e == nil {
		if e = json.Unmarshal(b, &initialText); e != nil {
			return e
		}
	} else if os.IsNotExist(e) {
		if e = save(initialTarget, initialText); e != nil {
			return e
		}
	} else {
		return e
	}
	initial, e := ids.FromString(initialText)
	if e != nil {
		return e
	}
	if _, e = issue(ctx, uri, filepath.Join(migration, "topup.json"), initial.String(), func() (pwallet.Wallet, txs.UnsignedTx, error) {
		w, e := pWallet(ctx, uri)
		if e != nil {
			return nil, nil, e
		}
		u, e := w.Builder().NewIncreaseL1ValidatorBalanceTx(initial, 1000000000, options.WithContext(ctx))
		return w, u, e
	}); e != nil {
		return e
	}
	height, e := epochHeight(ctx, uri+"/ext/bc/P/proposervm")
	if e != nil {
		return e
	}
	signed, e := proof(ctx, aggregator, filepath.Join(migration, "register-proof.bin"), map[string]any{"message": "0x" + hex.EncodeToString(unsignedBytes), "justification": "", "signing-subnet-id": sid.String(), "quorum-percentage": 67, "pchain-height": height})
	if e != nil {
		return e
	}
	if _, e = issue(ctx, uri, filepath.Join(migration, "registration.json"), map[string]any{"validation_id": validationID.String(), "signed": signed}, func() (pwallet.Wallet, txs.UnsignedTx, error) {
		w, e := pWallet(ctx, uri)
		if e != nil {
			return nil, nil, e
		}
		u, e := w.Builder().NewRegisterL1ValidatorTx(100000000000, n.POP.ProofOfPossession, signed, options.WithContext(ctx))
		return w, u, e
	}); e != nil {
		return e
	}
	height, e = observePChain(ctx, uri, url, migration)
	if e != nil {
		return e
	}
	ack, e := message.NewL1ValidatorRegistration(validationID, true)
	if e != nil {
		return e
	}
	envelope, e := payload.NewAddressedCall(nil, ack.Bytes())
	if e != nil {
		return e
	}
	ackMsg, e := warp.NewUnsignedMessage(networkID, ids.Empty, envelope.Bytes())
	if e != nil {
		return e
	}
	signedAck, e := proof(ctx, aggregator, filepath.Join(migration, "ack-proof.bin"), map[string]any{"message": "0x" + hex.EncodeToString(ackMsg.Bytes()), "justification": "", "signing-subnet-id": c.Subnet, "quorum-percentage": 67, "pchain-height": height})
	if e != nil {
		return e
	}
	if e = invoke(ctx, url, migration, "completeValidatorRegistration", contract, staking, predicate(signedAck), uint32(0)); e != nil {
		return e
	}
	state, e := view(ctx, url, "ValidatorManager", manager, "getValidator", [32]byte(validationID))
	if e != nil {
		return e
	}
	raw, e := json.Marshal(state[0])
	if e != nil {
		return e
	}
	var validator struct {
		Status uint8
		Weight uint64
	}
	if e = json.Unmarshal(raw, &validator); e != nil {
		return e
	}
	if validator.Status != 2 || validator.Weight != 200000 {
		return fmt.Errorf("unexpected validator state %s", raw)
	}
	return save(filepath.Join(dir, fmt.Sprintf("migration-%d.json", nodeIndex)), map[string]any{"mode": mode + "-admission", "fully_pos": false, "manager": manager.Hex(), "staking": staking.Hex(), "validation_id": validationID.String(), "weight": validator.Weight, "rpc_node_promoted": false, "reward_rate": 0})
}
