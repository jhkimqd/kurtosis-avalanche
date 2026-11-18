package main

import (
	"context"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/core/types"
)

func TestICMSettlementUsesTheNodesCanonicalBlockHash(t *testing.T) {
	hash := common.Hash{8}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		if request.Method != "eth_getBlockByNumber" {
			t.Errorf("unexpected method: %s", request.Method)
		}
		w.Header().Set("Content-Type", "application/json")
		// Extra Avalanche header fields need not round-trip through an Ethereum
		// header decoder. The RPC hash is the canonical block's identity.
		json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": map[string]any{"hash": hash, "blockGasCost": "0x0"}})
	}))
	defer server.Close()
	receipt := &types.Receipt{Status: 1, BlockNumber: big.NewInt(123), BlockHash: hash}
	if err := canonicalICMReceipt(context.Background(), server.URL, receipt); err != nil {
		t.Fatal(err)
	}
	receipt.BlockHash = common.Hash{9}
	if err := canonicalICMReceipt(context.Background(), server.URL, receipt); err == nil {
		t.Fatal("accepted a receipt from a different block")
	}
	receipt.Status = 0
	if err := canonicalICMReceipt(context.Background(), server.URL, receipt); err == nil {
		t.Fatal("accepted a reverted message")
	}
}

func TestICMDestinationRPCsMustAgreeOnTheExactSettlement(t *testing.T) {
	first := &types.Receipt{TxHash: common.Hash{1}, BlockHash: common.Hash{2}, BlockNumber: big.NewInt(123)}
	for _, other := range []*types.Receipt{
		{TxHash: common.Hash{9}, BlockHash: first.BlockHash, BlockNumber: first.BlockNumber},
		{TxHash: first.TxHash, BlockHash: common.Hash{9}, BlockNumber: first.BlockNumber},
		{TxHash: first.TxHash, BlockHash: first.BlockHash, BlockNumber: big.NewInt(124)},
	} {
		if err := sameICMSettlement(first, other); err == nil {
			t.Fatal("accepted disagreement between destination RPCs")
		}
	}
	copy := *first
	if err := sameICMSettlement(first, &copy); err != nil {
		t.Fatal(err)
	}
}

func TestICMUndeliveredMessageFailsAtDeadline(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		var request struct {
			ID json.RawMessage `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": []any{}})
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := waitICMDelivery(ctx, server.URL, common.Address{1}, common.Address{2}, common.Hash{3}, common.Hash{4}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("a source send alone must not count as delivery: %v", err)
	}
}

func icmTestManifest() icmManifest {
	var manifest icmManifest
	manifest.Primary.NetworkID = networkID
	for index := 0; index < 3; index++ {
		chain := ids.ID{byte(index + 1)}.String()
		network := icmNetwork{BlockchainID: chain, SubnetID: ids.ID{byte(index + 11)}.String(), ChainID: uint64(index + 77777), RPCURLs: []string{"http://node/ext/bc/" + chain + "/rpc"}}
		network.Bridge.Messenger = common.Address{1}
		manifest.L1s = append(manifest.L1s, network)
	}
	return manifest
}

func TestICMManifestRequiresDistinctLocalRoutes(t *testing.T) {
	for _, test := range []struct {
		name   string
		modify func(*icmManifest)
	}{
		{"one L1", func(m *icmManifest) { m.L1s = m.L1s[:1] }},
		{"public network", func(m *icmManifest) { m.Primary.NetworkID = 1 }},
		{"duplicate blockchain", func(m *icmManifest) { m.L1s[1].BlockchainID = m.L1s[0].BlockchainID }},
		{"duplicate EVM ID", func(m *icmManifest) { m.L1s[1].ChainID = m.L1s[0].ChainID }},
		{"missing messenger", func(m *icmManifest) { m.L1s[1].Bridge.Messenger = common.Address{} }},
		{"missing RPC", func(m *icmManifest) { m.L1s[1].RPCURLs = nil }},
		{"wrong RPC chain", func(m *icmManifest) { m.L1s[1].RPCURLs = m.L1s[0].RPCURLs }},
		{"invalid subnet", func(m *icmManifest) { m.L1s[1].SubnetID = "invalid" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			manifest := icmTestManifest()
			test.modify(&manifest)
			input, _ := json.Marshal(manifest)
			if _, err := parseICMManifest(string(input)); err == nil {
				t.Fatal("accepted an invalid ICM test topology")
			}
		})
	}
	input, _ := json.Marshal(icmTestManifest())
	got, err := parseICMManifest(string(input))
	if err != nil || len(got.L1s) != 3 {
		t.Fatalf("valid custom topology: %v", err)
	}
}

func TestICMEnvelopeBindsOriginAndPayload(t *testing.T) {
	source, sender, payload := [32]byte{1}, common.Address{2}, []byte("nightly payload")
	want, err := envelopeHash(source, sender, payload)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		source  [32]byte
		sender  common.Address
		payload []byte
	}{
		{[32]byte{3}, sender, payload},
		{source, common.Address{4}, payload},
		{source, sender, []byte("different payload")},
	} {
		got, err := envelopeHash(test.source, test.sender, test.payload)
		if err != nil || got == want {
			t.Fatalf("origin or payload was not bound to the received envelope: %v", err)
		}
	}
}

func TestICMSendRequiresOneCorrectlyRoutedEvent(t *testing.T) {
	messenger, event, destination, messageID := common.Address{1}, common.Hash{2}, common.Hash{3}, common.Hash{4}
	log := &types.Log{Address: messenger, Topics: []common.Hash{event, messageID, destination}}
	got, err := sentMessageID(&types.Receipt{Logs: []*types.Log{log}}, messenger, event, destination)
	if err != nil || got != messageID {
		t.Fatalf("valid send: %v", err)
	}
	for _, logs := range [][]*types.Log{
		nil,
		{log, log},
		{{Address: common.Address{9}, Topics: log.Topics}},
		{{Address: messenger, Topics: []common.Hash{event, messageID, common.Hash{8}}}},
		{{Address: messenger, Topics: []common.Hash{event, {}, destination}}},
	} {
		if _, err := sentMessageID(&types.Receipt{Logs: logs}, messenger, event, destination); err == nil {
			t.Fatal("accepted an absent, duplicate, or incorrectly routed message")
		}
	}
}
