package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/core/types"
	"github.com/ava-labs/libevm/ethclient"
)

type Attempt struct {
	BusinessID int       `json:"business_id"`
	TxID       string    `json:"tx_id,omitempty"`
	Outcome    string    `json:"outcome"`
	Scheduled  time.Time `json:"scheduled"`
	Submitted  time.Time `json:"submitted,omitempty"`
	LatencyMS  int64     `json:"latency_ms,omitempty"`
	Error      string    `json:"error,omitempty"`
}

func percentile(values []int64, p int) int64 {
	if len(values) == 0 {
		return 0
	}
	i := (len(values)*p+99)/100 - 1
	if i < 0 {
		i = 0
	}
	return values[i]
}
func benchmark(ctx context.Context, url string, rate, seconds int, dir string) error {
	if rate < 1 || rate > 5000 || seconds < 1 || seconds > 120 || rate*seconds > 100000 {
		return fmt.Errorf("rate 1..5000, seconds 1..120, at most 100000 offered operations")
	}
	base, _, ok := strings.Cut(url, "/ext/bc/")
	if !ok {
		return fmt.Errorf("expected Avalanche RPC")
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
	nonce, e := client.PendingNonceAt(ctx, genesis.EWOQKey.EthAddress())
	if e != nil {
		return e
	}
	fee, e := client.SuggestGasPrice(ctx)
	if e != nil {
		return e
	}
	fee.Mul(fee, big.NewInt(2))
	recipient := common.HexToAddress("0x000000000000000000000000000000000000bEEF")
	before, e := client.BalanceAt(ctx, recipient, nil)
	if e != nil {
		return e
	}
	n := rate * seconds
	results := make([]Attempt, n)
	type job struct {
		index int
		tx    *types.Transaction
	}
	jobs := make(chan job, 128)
	var wg sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				r := &results[j.index]
				r.Submitted = time.Now()
				callCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
				err := client.SendTransaction(callCtx, j.tx)
				cancel()
				r.Outcome = "unknown"
				if err != nil {
					r.Error = err.Error()
				} else {
					r.Outcome = "pending"
				}
			}
		}()
	}
	start := time.Now()
	sent := 0
	for i := 0; i < n; i++ {
		due := start.Add(time.Duration(i) * time.Second / time.Duration(rate))
		delay := time.Until(due)
		if delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				close(jobs)
				wg.Wait()
				return ctx.Err()
			case <-timer.C:
			}
		}
		results[i] = Attempt{BusinessID: i, Outcome: "not-submitted", Scheduled: due}
		// Sign only with the next assignable nonce. A saturated generator never leaves nonce gaps.
		tx, err := types.SignTx(types.NewTransaction(nonce+uint64(sent), recipient, big.NewInt(1), 21000, fee, nil), types.LatestSignerForChainID(chain), genesis.EWOQKey.ToECDSA())
		if err != nil {
			close(jobs)
			wg.Wait()
			return err
		}
		select {
		case jobs <- job{i, tx}:
			results[i].TxID = tx.Hash().Hex()
			sent++
		default:
			results[i].Error = "generator queue saturated"
		}
	}
	close(jobs)
	wg.Wait()
	drainDeadline := time.Now().Add(30 * time.Second)
	for {
		unresolved := 0
		for i := range results {
			r := &results[i]
			if r.TxID == "" || strings.HasPrefix(r.Outcome, "accepted-") {
				continue
			}
			receipt, err := client.TransactionReceipt(ctx, common.HexToHash(r.TxID))
			if err == nil && receipt != nil {
				r.Outcome = "accepted-revert"
				if receipt.Status == 1 {
					r.Outcome = "accepted-success"
				}
				r.LatencyMS = time.Since(r.Submitted).Milliseconds()
			} else {
				unresolved++
			}
		}
		if unresolved == 0 || time.Now().After(drainDeadline) {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
	counts := map[string]int{}
	latencies := []int64{}
	for i := range results {
		r := &results[i]
		if r.Outcome == "pending" || r.Outcome == "unknown" {
			_, pending, err := client.TransactionByHash(ctx, common.HexToHash(r.TxID))
			if err == nil && pending {
				r.Outcome = "pending"
			} else {
				r.Outcome = "unknown"
			}
		}
		counts[r.Outcome]++
		if r.Outcome == "accepted-success" {
			latencies = append(latencies, r.LatencyMS)
		}
	}
	after, e := client.BalanceAt(ctx, recipient, nil)
	if e != nil {
		return e
	}
	delta := new(big.Int).Sub(after, before)
	reconciled := delta.Cmp(big.NewInt(int64(counts["accepted-success"]))) == 0
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	if e = save(filepath.Join(dir, "attempts.json"), results); e != nil {
		return e
	}
	report := map[string]any{"schema_version": 1, "kind": "open-loop-native-transfer", "offered": n, "submitted": sent, "rate": rate, "duration_seconds": seconds, "outcomes": counts, "balance_delta": delta.String(), "balance_reconciled": reconciled, "latency_observation": "receipt polling after submission phase; upper bounds, not precise acceptance timing", "latency_upper_bound_ms": map[string]int64{"p50": percentile(latencies, 50), "p95": percentile(latencies, 95), "p99": percentile(latencies, 99)}, "performance_verdict": "informational; no SLO configured", "elapsed_ms": time.Since(start).Milliseconds()}
	if e = save(filepath.Join(dir, "result.json"), report); e != nil {
		return e
	}
	json.NewEncoder(os.Stdout).Encode(report)
	if !reconciled || counts["pending"] > 0 || counts["unknown"] > 0 {
		return fmt.Errorf("incomplete reconciliation; inspect attempts.json")
	}
	return nil
}
func compare(ctx context.Context, urls []string) error {
	if len(urls) < 2 {
		return fmt.Errorf("compare requires at least two RPC URLs")
	}
	clients := []*ethclient.Client{}
	defer func() {
		for _, c := range clients {
			c.Close()
		}
	}()
	minimum := ^uint64(0)
	for _, url := range urls {
		base, _, ok := strings.Cut(url, "/ext/bc/")
		if !ok {
			return fmt.Errorf("expected Avalanche RPC")
		}
		if e := localOnly(ctx, base); e != nil {
			return e
		}
		c, e := ethclient.DialContext(ctx, url)
		if e != nil {
			return e
		}
		clients = append(clients, c)
		h, e := c.BlockNumber(ctx)
		if e != nil {
			return e
		}
		if h < minimum {
			minimum = h
		}
	}
	var hash common.Hash
	for i, c := range clients {
		h, e := c.HeaderByNumber(ctx, new(big.Int).SetUint64(minimum))
		if e != nil {
			return e
		}
		if i == 0 {
			hash = h.Hash()
		} else if h.Hash() != hash {
			return fmt.Errorf("accepted chain disagreement at height %d", minimum)
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"common_height": minimum, "hash": hash.Hex(), "nodes": len(urls), "agreement": true})
}
