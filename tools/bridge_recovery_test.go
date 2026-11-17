package main

import (
	"context"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/common/hexutil"
	"github.com/ava-labs/libevm/core/types"
	"github.com/ava-labs/libevm/crypto"
)

func TestBridgeSmokeRecoversSpendJournalWithoutReceipt(t *testing.T) {
	// artifact() deliberately uses the same fixture location as the production
	// tools image. Run this test with static_files mounted at /fixtures.
	for _, name := range []string{"CashToken", "ERC20TokenHome", "NativeTokenRemote"} {
		if _, _, err := artifact(name); err != nil {
			t.Skipf("requires /fixtures/contracts production artifacts: %v", err)
		}
	}
	f := newEVMRPCFixture(t)
	f.estimate = 21000
	state := BridgeState{Token: common.Address{1}, Home: common.Address{2}, Remote: common.Address{3}, InitialSupply: units(10)}
	admin := genesis.EWOQKey.EthAddress()
	recipient := crypto.PubkeyToAddress(devKey(8).PublicKey)
	f.extra = func(method string, params []json.RawMessage) (any, bool) {
		sent, spent := false, false
		for _, tx := range f.sent {
			if tx.To() != nil && *tx.To() == state.Home {
				sent = true
			}
			if from, err := types.Sender(types.LatestSignerForChainID(tx.ChainId()), tx); err == nil && from == recipient {
				spent = true
			}
		}
		switch method {
		case "eth_getBalance":
			balance := new(big.Int)
			if sent {
				balance = units(7)
			}
			if spent {
				balance.Sub(balance, big.NewInt(21001))
			}
			return hexutil.EncodeBig(balance), true
		case "eth_call":
			var call struct {
				To    common.Address
				Input hexutil.Bytes
				Data  hexutil.Bytes
			}
			if err := json.Unmarshal(params[0], &call); err != nil {
				t.Error(err)
				return nil, true
			}
			result := big.NewInt(1) // getIsCollateralized
			if call.To == state.Token {
				data := call.Input
				if len(data) == 0 {
					data = call.Data
				}
				if len(data) < 36 {
					t.Errorf("invalid balanceOf calldata %x", data)
					return nil, true
				}
				if common.BytesToAddress(data[4:36]) == admin {
					result = units(100)
					if sent {
						result.Sub(result, units(7))
					}
				} else {
					result = units(10)
					if sent {
						result.Add(result, units(7))
					}
				}
			}
			return hexutil.Encode(common.LeftPadBytes(result.Bytes(), 32)), true
		}
		return nil, false
	}
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := bridgeSmoke(ctx, f.url(), f.url(), dir, state, ids.Empty); err != nil {
		t.Fatalf("initial bridge smoke: %v", err)
	}
	if len(f.sent) != 3 {
		t.Fatalf("initial smoke must approve, send, and spend, got %d broadcasts", len(f.sent))
	}
	spendHash := f.sent[2].Hash()
	for _, journalState := range []string{"accepted", "submitted", "prepared"} {
		t.Run(journalState, func(t *testing.T) {
			journalPath := filepath.Join(dir, "spend.evm.json")
			b, err := os.ReadFile(journalPath)
			if err != nil {
				t.Fatal(err)
			}
			var journal Journal
			if err := json.Unmarshal(b, &journal); err != nil {
				t.Fatal(err)
			}
			// Acceptance may race any local journal-state or receipt write.
			journal.State = journalState
			if err := atomicJSON(journalPath, journal); err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"spend.receipt.json", "verified.json"} {
				if err := os.Remove(filepath.Join(dir, name)); err != nil {
					t.Fatal(err)
				}
			}
			retry, stop := context.WithTimeout(context.Background(), time.Second)
			defer stop()
			if err := bridgeSmoke(retry, f.url(), f.url(), dir, state, ids.Empty); err != nil {
				t.Fatalf("spend journal must reconcile without awaiting the pre-spend balance: %v", err)
			}
			if len(f.sent) != 3 || f.sent[2].Hash() != spendHash {
				t.Fatal("recovery broadcast a new spend instead of reconciling the journal")
			}
			for _, name := range []string{"spend.receipt.json", "verified.json"} {
				if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
					t.Fatalf("recovery did not restore %s: %v", name, err)
				}
			}
		})
	}
}
