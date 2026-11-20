package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ava-labs/avalanchego/utils/formatting"
)

// fakeNode serves the info and platform calls that deploymentIdentity makes.
// follower=true makes the P-Chain refuse platform calls, as a node with
// --p-chain-follow-only does.
func fakeNode(t *testing.T, follower bool, bootstrapped bool, peers []string) *httptest.Server {
	t.Helper()
	genesis, err := formatting.Encode(formatting.Hex, []byte("p-chain genesis"))
	if err != nil {
		t.Fatal(err)
	}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Method string
			Params struct {
				Chain   string   `json:"chain"`
				NodeIDs []string `json:"nodeIDs"`
			}
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		reply := func(result any) {
			json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": result})
		}
		switch request.Method {
		case "info.getNetworkID":
			reply(map[string]string{"networkID": "88888"})
		case "info.getNodeID":
			reply(map[string]string{"nodeID": "NodeID-primary"})
		case "info.isBootstrapped":
			if request.Params.Chain != "P" {
				t.Errorf("isBootstrapped asked for chain %q, want P", request.Params.Chain)
			}
			reply(map[string]bool{"isBootstrapped": bootstrapped})
		case "info.peers":
			// Like AvalancheGo, return only the requested peers.
			list := []map[string]string{}
			for _, id := range peers {
				for _, wanted := range request.Params.NodeIDs {
					if id == wanted {
						list = append(list, map[string]string{"nodeID": id})
					}
				}
			}
			reply(map[string]any{"numPeers": len(list), "peers": list})
		case "platform.getBlockByHeight":
			if follower {
				w.WriteHeader(http.StatusServiceUnavailable)
				w.Write([]byte("API call rejected because chain is not done bootstrapping"))
				return
			}
			reply(map[string]string{"block": genesis, "encoding": "hex"})
		default:
			t.Errorf("unexpected call %s", request.Method)
		}
	}))
}

func TestFollowOnlyNodeTakesTheIdentityOfItsPrimaryPeer(t *testing.T) {
	t.Setenv("LAB_INSTANCE", "devnet")
	primary := fakeNode(t, false, true, nil)
	defer primary.Close()
	t.Setenv("LAB_PRIMARY_URI", primary.URL)
	want, err := deploymentIdentity(context.Background(), primary.URL)
	if err != nil {
		t.Fatal(err)
	}

	connected := fakeNode(t, true, false, []string{"NodeID-primary"})
	defer connected.Close()
	got, err := deploymentIdentity(context.Background(), connected.URL)
	if err != nil || got != want {
		t.Fatalf("connected follower: identity %q, error %v; want %q", got, err, want)
	}

	isolated := fakeNode(t, true, false, nil)
	defer isolated.Close()
	if _, err := deploymentIdentity(context.Background(), isolated.URL); err == nil || !strings.Contains(err.Error(), "not connected") {
		t.Fatalf("follower without the primary peer: error %v", err)
	}

	// A node that claims a bootstrapped P-Chain but refuses platform calls is
	// not a follower: the original error stands.
	broken := fakeNode(t, true, true, []string{"NodeID-primary"})
	defer broken.Close()
	if _, err := deploymentIdentity(context.Background(), broken.URL); err == nil || strings.Contains(err.Error(), "not connected") {
		t.Fatalf("bootstrapped node with a failing P-Chain API: error %v", err)
	}

	// The primary itself never falls back to itself, with or without a slash.
	refusing := fakeNode(t, true, false, []string{"NodeID-primary"})
	defer refusing.Close()
	t.Setenv("LAB_PRIMARY_URI", refusing.URL+"/")
	if _, err := deploymentIdentity(context.Background(), refusing.URL); err == nil {
		t.Fatal("a node cannot vouch for itself")
	}

	t.Setenv("LAB_PRIMARY_URI", "")
	if _, err := deploymentIdentity(context.Background(), connected.URL); err == nil {
		t.Fatal("without LAB_PRIMARY_URI a follower has no identity")
	}
}
