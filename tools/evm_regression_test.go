package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/common/hexutil"
	"github.com/ava-labs/libevm/core/types"
	"github.com/ava-labs/libevm/crypto"
)

// Exercise the real RPC client, transaction signing, and persistent journals.
// Only the remote Avalanche node is replaced.
type evmRPCFixture struct {
	mu        sync.Mutex
	server    *httptest.Server
	gasLimit  uint64
	estimate  uint64
	estimates int
	sent      []*types.Transaction
	receipts  map[common.Hash]*types.Receipt
	extra     func(string, []json.RawMessage) (any, bool)
}

func newEVMRPCFixture(t *testing.T) *evmRPCFixture {
	t.Helper()
	f := &evmRPCFixture{gasLimit: 7000000, estimate: 6000000, receipts: make(map[common.Hash]*types.Receipt)}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Error(err)
			return
		}
		var params []json.RawMessage
		if len(req.Params) > 0 && req.Params[0] == '[' {
			if err := json.Unmarshal(req.Params, &params); err != nil {
				t.Error(err)
				return
			}
		}
		f.mu.Lock()
		defer f.mu.Unlock()
		var result any
		handled := false
		if f.extra != nil {
			result, handled = f.extra(req.Method, params)
		}
		if !handled {
			switch req.Method {
			case "info.getNetworkID":
				result = map[string]string{"networkID": "88888"}
			case "platform.getBlockByHeight":
				result = map[string]string{"block": "0x010203", "encoding": "hexnc"}
			case "eth_chainId":
				result = "0x12fd2"
			case "eth_getTransactionCount":
				result = hexutil.EncodeUint64(uint64(len(f.sent)))
			case "eth_gasPrice":
				result = "0x1"
			case "eth_getBlockByNumber":
				result = &types.Header{Number: big.NewInt(1), Difficulty: big.NewInt(0), GasLimit: f.gasLimit, Extra: []byte{}}
			case "eth_estimateGas":
				f.estimates++
				result = hexutil.EncodeUint64(f.estimate)
			case "eth_getTransactionReceipt":
				var hash common.Hash
				if err := json.Unmarshal(params[0], &hash); err != nil {
					t.Error(err)
				}
				result = f.receipts[hash]
			case "eth_sendRawTransaction":
				var raw hexutil.Bytes
				if err := json.Unmarshal(params[0], &raw); err != nil {
					t.Error(err)
				}
				tx := new(types.Transaction)
				if err := tx.UnmarshalBinary(raw); err != nil {
					t.Error(err)
				}
				f.sent = append(f.sent, tx)
				f.receipts[tx.Hash()] = &types.Receipt{Type: tx.Type(), Status: 1, TxHash: tx.Hash(), GasUsed: 21000, CumulativeGasUsed: 21000, EffectiveGasPrice: big.NewInt(1), BlockNumber: big.NewInt(1), Logs: []*types.Log{}}
				result = tx.Hash()
			default:
				t.Errorf("unexpected RPC %s", req.Method)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result}); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *evmRPCFixture) url() string { return f.server.URL + "/ext/bc/test/rpc" }

func TestEVMTxDeploymentRespectsBlockGasLimit(t *testing.T) {
	f := newEVMRPCFixture(t)
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, err := evmTxAs(ctx, f.url(), dir, "deploy", nil, []byte{0x60, 0x00}, big.NewInt(0), nil, devKey(8)); err != nil {
		t.Fatal(err)
	}
	if len(f.sent) != 1 || f.sent[0].Gas() != f.gasLimit {
		t.Fatalf("deployment must cap headroom/floor at block gas limit %d; signed %v", f.gasLimit, signedGasLimits(f.sent))
	}
	if sender, err := types.Sender(types.LatestSignerForChainID(f.sent[0].ChainId()), f.sent[0]); err != nil || sender != crypto.PubkeyToAddress(devKey(8).PublicKey) {
		t.Fatalf("transaction was not signed by requested key: %s %v", sender, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "deploy.evm.json")); err != nil {
		t.Fatal(err)
	}
}

func signedGasLimits(txs []*types.Transaction) string {
	var values []string
	for _, tx := range txs {
		values = append(values, fmt.Sprint(tx.Gas()))
	}
	return strings.Join(values, ",")
}

func TestEVMTxPredicateFallbackRespectsBlockGasLimit(t *testing.T) {
	f := newEVMRPCFixture(t)
	to := common.Address{1}
	access := predicate([]byte("signed Warp message"))
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, err := evmTxAs(ctx, f.url(), t.TempDir(), "predicate", &to, []byte{1}, big.NewInt(0), access, devKey(8)); err != nil {
		t.Fatal(err)
	}
	if f.estimates != 0 {
		t.Fatal("Warp predicates must not be estimated without predicate verification")
	}
	if len(f.sent) != 1 || f.sent[0].Gas() != f.gasLimit {
		t.Fatalf("predicate fallback must cap gas at block limit %d; signed %v", f.gasLimit, signedGasLimits(f.sent))
	}
	if got, _ := json.Marshal(f.sent[0].AccessList()); string(got) != mustJSON(t, access) {
		t.Fatal("signed transaction lost Warp predicate")
	}
}

func mustJSON(t *testing.T, value any) string {
	t.Helper()
	b, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestEVMTxRejectsEstimateAboveBlockLimitBeforeJournal(t *testing.T) {
	f := newEVMRPCFixture(t)
	f.estimate = f.gasLimit + 1
	dir := t.TempDir()
	to := common.Address{1}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, err := evmTxAs(ctx, f.url(), dir, "impossible", &to, []byte{1}, big.NewInt(0), nil, devKey(8))
	if err == nil || !strings.Contains(err.Error(), "block gas limit") {
		t.Fatalf("expected actionable block gas limit error, got %v", err)
	}
	if len(f.sent) != 0 {
		t.Fatal("impossible transaction was broadcast")
	}
	if _, err := os.Stat(filepath.Join(dir, "impossible.evm.json")); !os.IsNotExist(err) {
		t.Fatalf("impossible transaction must not poison retry journal: %v", err)
	}
}

func TestEVMTxEstimatedGasHeadroom(t *testing.T) {
	for _, tc := range []struct {
		name                  string
		limit, estimate, want uint64
		deploy                bool
	}{
		{name: "normal-call", limit: 7000000, estimate: 21000, want: 25200},
		{name: "deployment-floor", limit: 15000000, estimate: 1000000, want: 8000000, deploy: true},
		{name: "overflow", limit: ^uint64(0), estimate: ^uint64(0) - 1, want: ^uint64(0)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newEVMRPCFixture(t)
			f.gasLimit, f.estimate = tc.limit, tc.estimate
			address := common.Address{1}
			to := &address
			if tc.deploy {
				to = nil
			}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if _, err := evmTxAs(ctx, f.url(), t.TempDir(), "headroom", to, []byte{1}, big.NewInt(0), nil, devKey(8)); err != nil {
				t.Fatal(err)
			}
			if len(f.sent) != 1 || f.sent[0].Gas() != tc.want {
				t.Fatalf("expected gas %d, signed %s", tc.want, signedGasLimits(f.sent))
			}
		})
	}
}
