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

// rpc sends one JSON-RPC request and decodes the result.
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

// localOnly fails unless the node at uri reports the network ID of the local
// devnet. Every path that signs a transaction calls it first, so lab never
// signs for Fuji or Mainnet.
func localOnly(ctx context.Context, uri string) error {
	var r struct {
		NetworkID string `json:"networkID"`
	}
	if e := rpc(ctx, strings.TrimRight(uri, "/")+"/ext/info", "info.getNetworkID", map[string]any{}, &r); e != nil {
		return e
	}
	if r.NetworkID != strconv.Itoa(networkID) {
		return fmt.Errorf("local lab requires network %d; got %s", networkID, r.NetworkID)
	}
	return nil
}

// waitRPC waits until an EVM RPC endpoint serves the expected chain ID.
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

// deploymentIdentity identifies one deployment: the instance name and the hash
// of the P-Chain genesis block. Every journal includes it, so the state of one
// enclave is never replayed against another.
func deploymentIdentity(ctx context.Context, uri string) (string, error) {
	if e := localOnly(ctx, uri); e != nil {
		return "", e
	}
	block, err := platformvm.NewClient(uri).GetBlockByHeight(ctx, 0)
	if err != nil {
		return followerIdentity(ctx, uri, err)
	}
	if len(block) == 0 {
		return "", fmt.Errorf("missing P-chain genesis identity")
	}
	return fmt.Sprintf("%s:%x", os.Getenv("LAB_INSTANCE"), sha256.Sum256(block)), nil
}

// followerIdentity identifies a node whose P-Chain does not answer platform
// calls: a node that runs --p-chain-follow-only never finishes P-Chain
// bootstrapping. It returns the identity of the Primary Network node in
// LAB_PRIMARY_URI, but only if the node at uri reports its P-Chain as not
// bootstrapped and is connected to that Primary Network node. Otherwise it
// returns cause, the error of the platform call.
func followerIdentity(ctx context.Context, uri string, cause error) (string, error) {
	primary := strings.TrimRight(os.Getenv("LAB_PRIMARY_URI"), "/")
	if primary == "" || primary == strings.TrimRight(uri, "/") {
		return "", cause
	}
	var bootstrapped struct {
		IsBootstrapped bool `json:"isBootstrapped"`
	}
	if e := rpc(ctx, uri+"/ext/info", "info.isBootstrapped", map[string]any{"chain": "P"}, &bootstrapped); e != nil || bootstrapped.IsBootstrapped {
		return "", cause
	}
	identity, e := deploymentIdentity(ctx, primary)
	if e != nil {
		return "", e
	}
	var node struct {
		NodeID string `json:"nodeID"`
	}
	if e = rpc(ctx, primary+"/ext/info", "info.getNodeID", map[string]any{}, &node); e != nil {
		return "", e
	}
	var peers struct {
		Peers []struct {
			NodeID string `json:"nodeID"`
		} `json:"peers"`
	}
	if e = rpc(ctx, uri+"/ext/info", "info.peers", map[string]any{"nodeIDs": []string{node.NodeID}}, &peers); e != nil {
		return "", e
	}
	for _, peer := range peers.Peers {
		if peer.NodeID == node.NodeID {
			return identity, nil
		}
	}
	return "", fmt.Errorf("%s is not connected to %s (%s): %w", uri, primary, node.NodeID, cause)
}
