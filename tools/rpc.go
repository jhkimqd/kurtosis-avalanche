package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"github.com/ava-labs/avalanchego/vms/platformvm"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 15 * time.Second}

func rpc(ctx context.Context, url, method string, params any, result any) error {
	payload, e := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	if e != nil {
		return e
	}
	req, e := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(payload))
	if e != nil {
		return e
	}
	req.Header.Set("Content-Type", "application/json")
	resp, e := httpClient.Do(req)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s: HTTP %d", method, resp.StatusCode)
	}
	var body struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    int
			Message string
		} `json:"error"`
	}
	if e = json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&body); e != nil {
		return e
	}
	if body.Error != nil {
		return fmt.Errorf("%s: RPC %d: %s", method, body.Error.Code, body.Error.Message)
	}
	if len(body.Result) == 0 {
		return fmt.Errorf("%s: missing RPC result", method)
	}
	return json.Unmarshal(body.Result, result)
}
func localOnly(ctx context.Context, uri string) error {
	var r struct {
		NetworkID string `json:"networkID"`
	}
	if e := rpc(ctx, strings.TrimRight(uri, "/")+"/ext/info", "info.getNetworkID", map[string]any{}, &r); e != nil {
		return e
	}
	if r.NetworkID != "88888" {
		return fmt.Errorf("local lab requires network 88888; got %s", r.NetworkID)
	}
	return nil
}

func waitRPC(ctx context.Context, url string, expected uint64) error {
	for {
		var chain string
		e := rpc(ctx, url, "eth_chainId", []any{}, &chain)
		id, parseErr := strconv.ParseUint(strings.TrimPrefix(chain, "0x"), 16, 64)
		if e == nil && parseErr == nil && id == expected {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("L1 RPC readiness: %v: %w", e, ctx.Err())
		case <-time.After(time.Second):
		}
	}
}

func deploymentIdentity(ctx context.Context, uri string) (string, error) {
	if e := localOnly(ctx, uri); e != nil {
		return "", e
	}
	block, err := platformvm.NewClient(uri).GetBlockByHeight(ctx, 0)
	if err != nil {
		return "", err
	}
	if len(block) == 0 {
		return "", fmt.Errorf("missing P-chain genesis identity")
	}
	return fmt.Sprintf("%s:%x", os.Getenv("LAB_INSTANCE"), sha256.Sum256(block)), nil
}
