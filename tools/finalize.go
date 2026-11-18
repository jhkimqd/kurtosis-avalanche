package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/ids"
	platformpb "github.com/ava-labs/avalanchego/proto/pb/platformvm"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/message"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/payload"
	pwallet "github.com/ava-labs/avalanchego/wallet/chain/p/wallet"
	options "github.com/ava-labs/avalanchego/wallet/subnet/primary/common"
	"github.com/ava-labs/libevm/accounts/abi"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/core/types"
	"github.com/ava-labs/libevm/crypto"
	"github.com/ava-labs/libevm/ethclient"
	"google.golang.org/protobuf/proto"
)

// waitChurn waits until the L1 has entered a new churn period, so that the next
// validator change gets the full allowance of 20% of the total weight. Chain
// time moves only with new blocks, so waitChurn sends empty transactions until
// a block is late enough.
func waitChurn(ctx context.Context, url string, manager common.Address, dir string) error {
	values, err := view(ctx, url, "ValidatorManager", manager, "getChurnTracker")
	if err != nil {
		return err
	}
	b, err := json.Marshal(values[2])
	if err != nil {
		return err
	}
	var tracker struct{ StartTime uint64 }
	if err = json.Unmarshal(b, &tracker); err != nil {
		return err
	}
	target := tracker.StartTime + values[0].(uint64)
	client, err := ethclient.DialContext(ctx, url)
	if err != nil {
		return err
	}
	defer client.Close()
	for i := 0; ; i++ {
		header, err := client.HeaderByNumber(ctx, nil)
		if err != nil {
			return err
		}
		if header.Time >= target {
			return nil
		}
		self := genesis.EWOQKey.EthAddress()
		if _, err = evmTx(ctx, url, dir, fmt.Sprintf("churn-%d-%d", target, i), &self, nil, big.NewInt(0), nil); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// receiptWarp returns the unsigned Warp message that a transaction sent through
// the Warp precompile.
func receiptWarp(receipt *types.Receipt) ([]byte, error) {
	t, _ := abi.NewType("bytes", "", nil)
	for _, log := range receipt.Logs {
		if log.Address == common.HexToAddress("0x0200000000000000000000000000000000000005") && len(log.Topics) > 0 && log.Topics[0] == crypto.Keccak256Hash([]byte("SendWarpMessage(address,bytes32,bytes)")) {
			values, err := (abi.Arguments{{Type: t}}).Unpack(log.Data)
			if err != nil {
				return nil, err
			}
			return values[0].([]byte), nil
		}
	}
	return nil, fmt.Errorf("transaction emitted no Warp message")
}

// observePChain waits until the ProposerVM epoch of the L1 has reached the
// current P-Chain height, and returns the epoch height. Only then do the L1
// validators sign a Warp message about the latest P-Chain change. The epoch
// moves with new blocks, so observePChain sends empty transactions.
func observePChain(ctx context.Context, uri, url, dir string) (uint64, error) {
	var current struct {
		Height string `json:"height"`
	}
	if err := rpc(ctx, uri+"/ext/bc/P", "platform.getHeight", map[string]any{}, &current); err != nil {
		return 0, err
	}
	target, err := strconv.ParseUint(current.Height, 10, 64)
	if err != nil {
		return 0, err
	}
	epochURL := strings.TrimSuffix(url, "/rpc") + "/proposervm"
	for i := 0; ; i++ {
		height, err := epochHeight(ctx, epochURL)
		if err != nil {
			return 0, err
		}
		if height >= target {
			return height, nil
		}
		self := genesis.EWOQKey.EthAddress()
		if _, err = evmTx(ctx, url, dir, fmt.Sprintf("epoch-%d-%d", target, i), &self, nil, big.NewInt(0), nil); err != nil {
			return 0, err
		}
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// finalizePoS removes every bootstrap validator and verifies the result.
//
// args: primary URI, L1 RPC, state directory, aggregator URI, staking mode, and
// the node indexes of the staked validators.
//
// Each removal takes three steps:
//
//  1. initiateValidatorRemoval on the L1 sends a Warp message.
//  2. SetL1ValidatorWeightTx carries it to the P-Chain and sets the weight to 0.
//  3. completeValidatorRemoval returns the P-Chain's confirmation to the L1.
//
// The final checks: the P-Chain lists exactly the staked validators; each is
// active with the expected weight, owner, and a P-Chain balance; and the
// staking manager holds one token for each of them.
func finalizePoS(ctx context.Context, args []string) error {
	uri, url, dir, aggregator, mode := args[0], args[1], args[2], args[3], args[4]
	contract := "NativeTokenStakingManager"
	if mode == "erc20-pos" {
		contract = "ERC20TokenStakingManager"
	} else if mode != "native-pos" {
		return fmt.Errorf("unsupported staking mode")
	}
	read := func(name string, v any) error {
		b, e := os.ReadFile(filepath.Join(dir, name))
		if e != nil {
			return e
		}
		return json.Unmarshal(b, v)
	}
	var chain Chain
	if err := read("chain.json", &chain); err != nil {
		return err
	}
	var managerInfo struct{ Address string }
	if err := read("manager.json", &managerInfo); err != nil {
		return err
	}
	manager := common.HexToAddress(managerInfo.Address)
	var migration struct{ Staking string }
	if err := read("migration-"+args[5]+".json", &migration); err != nil {
		return err
	}
	staking := common.HexToAddress(migration.Staking)
	var conversion struct {
		Validators []*txs.ConvertSubnetToL1Validator
	}
	if err := read("conversion.json", &conversion); err != nil {
		return err
	}
	for i, v := range conversion.Validators {
		stage := filepath.Join(dir, "remove-bootstrap", strconv.Itoa(i))
		// Persist ID before removal deletes the manager's NodeID lookup.
		var validationID [32]byte
		saved, e := os.ReadFile(filepath.Join(stage, "id.json"))
		if e == nil {
			if e = json.Unmarshal(saved, &validationID); e != nil {
				return e
			}
		} else if os.IsNotExist(e) {
			values, e := view(ctx, url, "ValidatorManager", manager, "getNodeValidationID", []byte(v.NodeID))
			if e != nil {
				return e
			}
			validationID = values[0].([32]byte)
			if validationID == ([32]byte{}) {
				return fmt.Errorf("bootstrap validator missing before removal")
			}
			if e = save(filepath.Join(stage, "id.json"), validationID); e != nil {
				return e
			}
		} else {
			return e
		}
		if e = waitChurn(ctx, url, manager, stage); e != nil {
			return e
		}
		_, a, e := artifact(contract)
		if e != nil {
			return e
		}
		data, e := a.Pack("initiateValidatorRemoval", validationID, false, uint32(0))
		if e != nil {
			return e
		}
		receipt, e := evmTx(ctx, url, stage, "initiate", &staking, data, big.NewInt(0), nil)
		if e != nil {
			return e
		}
		unsigned, e := receiptWarp(receipt)
		if e != nil {
			return e
		}
		height, e := epochHeight(ctx, uri+"/ext/bc/P/proposervm")
		if e != nil {
			return e
		}
		signed, e := proof(ctx, aggregator, filepath.Join(stage, "weight-proof.bin"), map[string]any{"message": "0x" + hex.EncodeToString(unsigned), "justification": "", "signing-subnet-id": chain.Subnet, "quorum-percentage": 67, "pchain-height": height})
		if e != nil {
			return e
		}
		if _, e = issue(ctx, uri, filepath.Join(stage, "weight.json"), hex.EncodeToString(signed), func() (pwallet.Wallet, txs.UnsignedTx, error) {
			w, e := pWallet(ctx, uri)
			if e != nil {
				return nil, nil, e
			}
			u, e := w.Builder().NewSetL1ValidatorWeightTx(signed, options.WithContext(ctx))
			return w, u, e
		}); e != nil {
			return e
		}
		height, e = observePChain(ctx, uri, url, stage)
		if e != nil {
			return e
		}
		ack, e := message.NewL1ValidatorRegistration(ids.ID(validationID), false)
		if e != nil {
			return e
		}
		envelope, e := payload.NewAddressedCall(nil, ack.Bytes())
		if e != nil {
			return e
		}
		msg, e := warp.NewUnsignedMessage(networkID, ids.Empty, envelope.Bytes())
		if e != nil {
			return e
		}
		sid, e := ids.FromString(chain.Subnet)
		if e != nil {
			return e
		}
		justification, e := proto.Marshal(&platformpb.L1ValidatorRegistrationJustification{Preimage: &platformpb.L1ValidatorRegistrationJustification_ConvertSubnetToL1TxData{ConvertSubnetToL1TxData: &platformpb.SubnetIDIndex{SubnetId: sid[:], Index: uint32(i)}}})
		if e != nil {
			return e
		}
		signedAck, e := proof(ctx, aggregator, filepath.Join(stage, "ack-proof.bin"), map[string]any{"message": "0x" + hex.EncodeToString(msg.Bytes()), "justification": "0x" + hex.EncodeToString(justification), "signing-subnet-id": chain.Subnet, "quorum-percentage": 67, "pchain-height": height})
		if e != nil {
			return e
		}
		if e = invoke(ctx, url, stage, "completeValidatorRemoval", contract, staking, predicate(signedAck), uint32(0)); e != nil {
			return e
		}
		values, e := view(ctx, url, "ValidatorManager", manager, "getNodeValidationID", []byte(v.NodeID))
		if e != nil {
			return e
		}
		if values[0].([32]byte) != ([32]byte{}) {
			return fmt.Errorf("bootstrap removal not reflected by manager")
		}
	}
	var network struct {
		Nodes []struct {
			ID string `json:"node_id"`
		}
	}
	b, e := os.ReadFile("/state/network/network.json")
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &network); e != nil {
		return e
	}
	expected := map[string]bool{}
	for _, text := range args[5:] {
		index, e := strconv.Atoi(text)
		if e != nil || index < 0 || index >= len(network.Nodes) {
			return fmt.Errorf("invalid final validator index")
		}
		expected[network.Nodes[index].ID] = true
	}
	var current struct {
		Validators []struct {
			NodeID       string `json:"nodeID"`
			ValidationID string `json:"validationID"`
		}
	}
	if e = rpc(ctx, uri+"/ext/bc/P", "platform.getCurrentValidators", map[string]any{"subnetID": chain.Subnet}, &current); e != nil {
		return e
	}
	if len(current.Validators) != len(expected) {
		return fmt.Errorf("final validator count mismatch")
	}
	for _, v := range current.Validators {
		if !expected[v.NodeID] {
			return fmt.Errorf("unexpected validator %s", v.NodeID)
		}
		id, e := ids.FromString(v.ValidationID)
		if e != nil {
			return e
		}
		state, e := view(ctx, url, "ValidatorManager", manager, "getValidator", [32]byte(id))
		if e != nil {
			return e
		}
		b, e := json.Marshal(state[0])
		if e != nil {
			return e
		}
		var validator struct {
			Status uint8
			Weight uint64
		}
		if e = json.Unmarshal(b, &validator); e != nil {
			return e
		}
		if validator.Status != 2 || validator.Weight != 200000 {
			return fmt.Errorf("final validator not active at expected weight")
		}
		info, e := view(ctx, url, contract, staking, "getStakingValidator", [32]byte(id))
		if e != nil {
			return e
		}
		raw, e := json.Marshal(info[0])
		if e != nil {
			return e
		}
		var owner struct{ Owner common.Address }
		if e = json.Unmarshal(raw, &owner); e != nil {
			return e
		}
		if owner.Owner != genesis.EWOQKey.EthAddress() {
			return fmt.Errorf("final validator has no expected staking owner")
		}
		var pInfo struct {
			Balance string `json:"balance"`
		}
		if e = rpc(ctx, uri+"/ext/bc/P", "platform.getL1Validator", map[string]any{"validationID": v.ValidationID}, &pInfo); e != nil {
			return e
		}
		balance, ok := new(big.Int).SetString(pInfo.Balance, 10)
		if !ok || balance.Sign() <= 0 {
			return fmt.Errorf("final validator has no operating balance")
		}

	}
	expectedStake := new(big.Int).Mul(big.NewInt(int64(len(expected))), big.NewInt(1e18))
	var locked *big.Int
	if mode == "native-pos" {
		client, e := ethclient.DialContext(ctx, url)
		if e != nil {
			return e
		}
		defer client.Close()
		locked, e = client.BalanceAt(ctx, staking, nil)
		if e != nil {
			return e
		}
	} else {
		var receipt types.Receipt
		if e = read("erc20-pos/deploy-StakingToken.receipt.json", &receipt); e != nil {
			return e
		}
		values, e := view(ctx, url, "StakingToken", receipt.ContractAddress, "balanceOf", staking)
		if e != nil {
			return e
		}
		locked = values[0].(*big.Int)
	}
	if locked.Cmp(expectedStake) != 0 {
		return fmt.Errorf("locked stake mismatch: got %s want %s", locked, expectedStake)
	}
	return save(filepath.Join(dir, "staking.json"), map[string]any{"fully_pos": true, "mode": mode, "validators": current.Validators, "staking": staking.Hex(), "manager": manager.Hex(), "rpc_node_promoted": false})
}
