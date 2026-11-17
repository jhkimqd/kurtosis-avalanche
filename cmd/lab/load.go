package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/core/types"
	"github.com/ava-labs/libevm/ethclient"
)

// This bounded correctness runner is intentionally separate from capacity benchmarking.
func runTransfers(ctx context.Context, url string, n int) error {
	if n < 1 || n > 10000 {
		return fmt.Errorf("count must be between 1 and 10000")
	}
	base, _, found := strings.Cut(url, "/ext/bc/")
	if !found {
		return fmt.Errorf("expected Avalanche RPC URL")
	}
	if e := localOnly(ctx, base); e != nil {
		return e
	}
	client, e := ethclient.DialContext(ctx, url)
	if e != nil {
		return e
	}
	defer client.Close()
	chain, e := client.ChainID(ctx)
	if e != nil {
		return e
	}
	key := genesis.EWOQKey.ToECDSA()
	sender := genesis.EWOQKey.EthAddress()
	nonce, e := client.PendingNonceAt(ctx, sender)
	if e != nil {
		return e
	}
	recipient := common.HexToAddress("0x0000000000000000000000000000000000001234")
	before, e := client.BalanceAt(ctx, recipient, nil)
	if e != nil {
		return e
	}
	start := time.Now()
	success := 0
	for i := 0; i < n; i++ {
		fee, e := client.SuggestGasPrice(ctx)
		if e != nil {
			return e
		}
		tx, e := types.SignTx(types.NewTransaction(nonce+uint64(i), recipient, big.NewInt(1), 21000, fee, nil), types.LatestSignerForChainID(chain), key)
		if e != nil {
			return e
		}
		submitted := time.Now()
		sendErr := client.SendTransaction(ctx, tx)
		// Receipt lookup also reconciles an ambiguous transport error.
		var receipt *types.Receipt
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			receipt, e = client.TransactionReceipt(ctx, tx.Hash())
			if e == nil && receipt != nil {
				break
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(200 * time.Millisecond):
			}
		}
		outcome := "unknown"
		if receipt != nil {
			if receipt.Status == 1 {
				success++
				outcome = "accepted-success"
			} else {
				outcome = "accepted-revert"
			}
		}
		json.NewEncoder(os.Stdout).Encode(map[string]any{"business_id": i, "tx_id": tx.Hash().Hex(), "outcome": outcome, "latency_ms": time.Since(submitted).Milliseconds()})
		if receipt == nil {
			return fmt.Errorf("unresolved transaction %s (submission error: %v)", tx.Hash(), sendErr)
		}
	}
	after, e := client.BalanceAt(ctx, recipient, nil)
	if e != nil {
		return e
	}
	delta := new(big.Int).Sub(after, before)
	if delta.Cmp(big.NewInt(int64(success))) != 0 {
		return fmt.Errorf("balance reconciliation failed")
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{"version": 1, "kind": "correctness-smoke", "submitted": n, "accepted_success": success, "elapsed_ms": time.Since(start).Milliseconds(), "balance_reconciled": true})
	if success != n {
		return fmt.Errorf("%d transactions reverted", n-success)
	}
	return nil
}
