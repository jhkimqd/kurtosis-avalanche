package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
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
func inspect(ctx context.Context, uri string, out io.Writer) error {
	if e := localOnly(ctx, uri); e != nil {
		return e
	}
	result := map[string]any{"version": 1, "observed_at": time.Now().UTC()}
	for _, q := range []struct{ Path, Method, Key string }{{"/ext/info", "info.getNodeID", "identity"}, {"/ext/bc/P", "platform.getHeight", "p_chain"}, {"/ext/bc/P", "platform.getBlockchains", "blockchains"}, {"/ext/health", "health.health", "health"}} {
		var value any
		if e := rpc(ctx, uri+q.Path, q.Method, map[string]any{}, &value); e != nil {
			return e
		}
		result[q.Key] = value
	}
	return json.NewEncoder(out).Encode(result)
}
func collect(ctx context.Context, uri, dir string) error {
	if e := os.MkdirAll(dir, 0700); e != nil {
		return e
	}
	f, e := os.Create(filepath.Join(dir, "inspection.json"))
	if e != nil {
		return e
	}
	defer f.Close()
	return inspect(ctx, uri, f)
}

func waitRPC(ctx context.Context, url string) error {
	for {
		var chain string
		e := rpc(ctx, url, "eth_chainId", []any{}, &chain)
		if e == nil && chain == "0x12fd1" {
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
	var block struct {
		Hash string `json:"hash"`
	}
	if e := rpc(ctx, uri+"/ext/bc/C/rpc", "eth_getBlockByNumber", []any{"0x0", false}, &block); e != nil {
		return "", e
	}
	if block.Hash == "" {
		return "", fmt.Errorf("missing genesis identity")
	}
	return os.Getenv("LAB_INSTANCE") + ":" + block.Hash, nil
}
