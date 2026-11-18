package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/ava-labs/libevm/crypto"
)

func TestGenesisBridgeMintAuthority(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct{ Method string }
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		if request.Method == "info.getNetworkID" {
			w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"networkID":"88888"}}`))
			return
		}
		// Stop before any P-chain transaction; inspect the generated genesis.
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	for _, enabled := range []bool{false, true} {
		t.Run(strconv.FormatBool(enabled), func(t *testing.T) {
			dir := t.TempDir()
			source := filepath.Join(dir, "base.json")
			if err := os.WriteFile(source, []byte(`{"config":{"feeConfig":{"gasLimit":20000000}}}`), 0600); err != nil {
				t.Fatal(err)
			}
			state := filepath.Join(dir, "state")
			if err := create(context.Background(), server.URL, state, source, "77777", "{}", enabled, "{}", "{}"); err == nil {
				t.Fatal("expected transaction preparation to stop at unavailable P-chain")
			}
			data, err := os.ReadFile(filepath.Join(state, "genesis.json"))
			if err != nil {
				t.Fatal(err)
			}
			var g struct {
				Config   map[string]any
				GasLimit string
			}
			if err := json.Unmarshal(data, &g); err != nil {
				t.Fatal(err)
			}
			if g.GasLimit != "0x1312d00" {
				t.Fatalf("header gas limit %q does not follow the fee config", g.GasLimit)
			}
			minter, exists := g.Config["contractNativeMinterConfig"]
			if exists != enabled {
				t.Fatalf("native mint authority enabled=%v, bridge=%v", exists, enabled)
			}
			if enabled {
				config := minter.(map[string]any)
				addresses := config["enabledAddresses"].([]any)
				want := crypto.CreateAddress(crypto.PubkeyToAddress(devKey(10).PublicKey), 0).Hex()
				if len(addresses) != 1 || addresses[0] != want {
					t.Fatalf("unexpected mint authority: %v", addresses)
				}
			}
		})
	}
}

// An override of a base account must replace it, whatever the address spelling.
// The bridge collateral equals the sum of all genesis balances.
func TestGenesisAllocOverrideReplacesBaseAccount(t *testing.T) {
	base := map[string]any{"alloc": map[string]any{"8db97c7cece249c2b98bdc0226cc4c2a57bf52fc": map[string]any{"balance": "0x1"}}}
	override := map[string]any{"alloc": map[string]any{"0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC": map[string]any{"balance": "0x2"}}}
	for _, g := range []map[string]any{base, override} {
		if err := normalizeAlloc(g); err != nil {
			t.Fatal(err)
		}
	}
	mergeJSON(base, override)
	alloc := base["alloc"].(map[string]any)
	account, ok := alloc["8db97c7cece249c2b98bdc0226cc4c2a57bf52fc"].(map[string]any)
	if len(alloc) != 1 || !ok || account["balance"] != "0x2" {
		t.Fatalf("override did not replace the base account: %v", alloc)
	}
	// A key without a value keeps the base value.
	mergeJSON(base, map[string]any{"alloc": nil, "config": map[string]any{"feeConfig": nil}})
	if len(base["alloc"].(map[string]any)) != 1 {
		t.Fatal("a null override removed the base accounts")
	}
	duplicate := map[string]any{"alloc": map[string]any{"0xAB": map[string]any{}, "ab": map[string]any{}}}
	if err := normalizeAlloc(duplicate); err == nil {
		t.Fatal("accepted the same account twice")
	}
}

// Subnet-EVM rejects a genesis whose header gas limit differs from the fee config.
func TestHeaderGasLimitFollowsTheFeeConfig(t *testing.T) {
	var g map[string]any
	if err := json.Unmarshal([]byte(`{"gasLimit":"0x1312D00","config":{"feeConfig":{"gasLimit":30000000}}}`), &g); err != nil {
		t.Fatal(err)
	}
	if err := setHeaderGasLimit(g, g["config"].(map[string]any)); err != nil || g["gasLimit"] != "0x1c9c380" {
		t.Fatalf("header gas limit %v, error %v", g["gasLimit"], err)
	}
	for _, config := range []string{`{}`, `{"feeConfig":{}}`, `{"feeConfig":{"gasLimit":"20000000"}}`, `{"feeConfig":{"gasLimit":0}}`, `{"feeConfig":{"gasLimit":1.5}}`} {
		var c map[string]any
		if err := json.Unmarshal([]byte(config), &c); err != nil {
			t.Fatal(err)
		}
		if err := setHeaderGasLimit(map[string]any{}, c); err == nil {
			t.Fatalf("accepted %s", config)
		}
	}
}

// AvalancheGo looks up both files by ID, so the names must carry the IDs.
func TestL1ConfigFilesAreNamedByID(t *testing.T) {
	dir := t.TempDir()
	if err := writeL1Config(dir, "subnetID", "chainID", `{"pruning-enabled":false}`, `{"proposerNumHistoricalBlocks":100}`); err != nil {
		t.Fatal(err)
	}
	for path, key := range map[string]string{"chains/chainID/config.json": "pruning-enabled", "subnets/subnetID.json": "proposerNumHistoricalBlocks"} {
		data, err := os.ReadFile(filepath.Join(dir, path))
		if err != nil {
			t.Fatal(err)
		}
		var config map[string]any
		if err = json.Unmarshal(data, &config); err != nil || len(config) != 1 {
			t.Fatalf("%s: %s", path, data)
		}
		if _, ok := config[key]; !ok {
			t.Fatalf("%s lacks %s", path, key)
		}
	}
	if err := writeL1Config(dir, "subnetID", "chainID", `[]`, `{}`); err == nil {
		t.Fatal("accepted a chain config that is not an object")
	}
}
