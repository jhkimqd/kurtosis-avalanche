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
			if err := os.WriteFile(source, []byte(`{"config":{}}`), 0600); err != nil {
				t.Fatal(err)
			}
			state := filepath.Join(dir, "state")
			if err := create(context.Background(), server.URL, state, source, "77777", "{}", enabled); err == nil {
				t.Fatal("expected transaction preparation to stop at unavailable P-chain")
			}
			data, err := os.ReadFile(filepath.Join(state, "genesis.json"))
			if err != nil {
				t.Fatal(err)
			}
			var g struct{ Config map[string]any }
			if err := json.Unmarshal(data, &g); err != nil {
				t.Fatal(err)
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
