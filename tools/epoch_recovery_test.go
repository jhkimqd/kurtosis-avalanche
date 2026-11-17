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
)

func TestObservePChainRetryProgressesPastAcceptedJournal(t *testing.T) {
	f := newEVMRPCFixture(t)
	f.estimate = 21000
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	self := genesis.EWOQKey.EthAddress()
	// An earlier interrupted observation already burned its first transaction.
	if _, err := evmTx(ctx, f.url(), dir, "epoch-100-0", &self, nil, big.NewInt(0), nil); err != nil {
		t.Fatal(err)
	}
	prior, err := os.ReadFile(filepath.Join(dir, "epoch-100-0.evm.json"))
	if err != nil {
		t.Fatal(err)
	}
	f.extra = func(method string, _ []json.RawMessage) (any, bool) {
		switch method {
		case "platform.getHeight":
			return map[string]string{"height": "100"}, true
		case "proposervm.getCurrentEpoch":
			if len(f.sent) > 1 {
				return map[string]string{"pChainHeight": "100"}, true
			}
			return map[string]string{"pChainHeight": "99"}, true
		}
		return nil, false
	}
	height, err := observePChain(ctx, f.server.URL, f.url(), dir)
	if err != nil || height != 100 {
		t.Fatalf("retry failed to produce a fresh block past the replayed transaction: height=%d err=%v", height, err)
	}
	if len(f.sent) != 2 || f.sent[0].Hash() == f.sent[1].Hash() {
		t.Fatal("retry must preserve the accepted transaction and sign a new progress transaction")
	}
	current, err := os.ReadFile(filepath.Join(dir, "epoch-100-0.evm.json"))
	if err != nil || string(prior) != string(current) {
		t.Fatal("retry replaced the accepted transaction journal")
	}
	if _, err := os.Stat(filepath.Join(dir, "epoch-100-1.evm.json")); err != nil {
		t.Fatal("retry did not advance past the journaled operation:", err)
	}
}
