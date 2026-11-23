package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ava-labs/libevm/crypto"
)

// describeNode answers the three API calls of describe like a devnet node
// with one L1.
func describeNode(t *testing.T) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string
			Params map[string]any
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatal(err)
		}
		results := map[string]string{
			"info.getNetworkID":       `{"networkID":"88888"}`,
			"platform.getBlockchains": `{"blockchains":[{"id":"L1Chain","name":"Avalanche Devnet","subnetID":"L1Subnet","vmID":"SubnetEVM"},{"id":"CChain","name":"C-Chain","subnetID":"11111111111111111111111111111111LpoYY","vmID":"EVM"},{"id":"XChain","name":"X-Chain","subnetID":"11111111111111111111111111111111LpoYY","vmID":"AVM"}]}`,
			"platform.getSubnet":      `{"isPermissioned":false,"managerChainID":"L1Chain"}`,
		}
		if req.Method == "platform.getSubnet" && req.Params["subnetID"] != "L1Subnet" {
			t.Errorf("getSubnet for %v", req.Params["subnetID"])
		}
		w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":` + results[req.Method] + `}`))
	}))
}

const describeTestManifest = `{
  "primary_network": {"network_id": 88888, "p_chain_rpc_url": "http://primary-0:9650/ext/bc/P",
    "x_chain_rpc_url": "http://primary-0:9650/ext/bc/X", "c_chain_rpc_url": "http://primary-0:9650/ext/bc/C/rpc",
    "c_chain_ws_url": "ws://primary-0:9650/ext/bc/C/ws", "c_chain_id": 88888,
    "host": {"c_chain_rpc_url": "http://127.0.0.1:29650/ext/bc/C/rpc", "p_chain_rpc_url": "http://127.0.0.1:29650/ext/bc/P"}},
  "l1s": [{"name": "l1-0", "subnet_id": "L1Subnet", "blockchain_id": "L1Chain", "evm_chain_id": 77777,
    "rpc_urls": ["http://l1-0-rpc-0:9650/ext/bc/L1Chain/rpc"], "ws_urls": ["ws://l1-0-rpc-0:9650/ext/bc/L1Chain/ws"],
    "host": {"rpc_url": "http://127.0.0.1:29651/ext/bc/L1Chain/rpc"}, "bridge": {"home": "0x1"},
    "validator_management": "native-pos"}]
}`

func TestDescribeWritesChainsAccountsAndRawAnswers(t *testing.T) {
	server := describeNode(t)
	defer server.Close()
	dir := filepath.Join(t.TempDir(), "networks")
	if err := describe(context.Background(), server.URL, dir, describeTestManifest); err != nil {
		t.Fatal(err)
	}
	read := func(name string, v any) {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if err = json.Unmarshal(b, v); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}

	var chains []describedChain
	read("chains.json", &chains)
	names := []string{}
	for _, c := range chains {
		names = append(names, c.Name)
	}
	if strings.Join(names, ",") != "P-Chain,C-Chain,X-Chain,l1-0" {
		t.Fatalf("chains: %v", names)
	}
	if p := chains[0]; p.BlockchainID != "11111111111111111111111111111111LpoYY" || p.HostRPCURL != "http://127.0.0.1:29650/ext/bc/P" {
		t.Fatalf("P-Chain: %+v", p)
	}
	if c := chains[1]; c.EVMChainID != 88888 || c.VMID != "EVM" || c.HostRPCURL != "http://127.0.0.1:29650/ext/bc/C/rpc" || c.WSURL == "" {
		t.Fatalf("C-Chain: %+v", c)
	}
	if l1 := chains[3]; l1.BlockchainID != "L1Chain" || l1.VMID != "SubnetEVM" || l1.ChainName != "Avalanche Devnet" ||
		l1.EVMChainID != 77777 || l1.HostRPCURL != "http://127.0.0.1:29651/ext/bc/L1Chain/rpc" {
		t.Fatalf("L1: %+v", l1)
	}

	var accounts []devAccount
	read("accounts.json", &accounts)
	ewoq := accounts[0]
	if ewoq.EVMAddress != "0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC" ||
		ewoq.PrivateKey != "0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027" ||
		ewoq.PChainAddr != "P-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p" ||
		ewoq.XChainAddr != "X-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p" ||
		!strings.HasPrefix(ewoq.PChainKey, "PrivateKey-") {
		t.Fatalf("EWOQ: %+v", ewoq)
	}
	// The role names only what this deployment has: a PoS L1 with a bridge.
	if !strings.Contains(ewoq.Role, "PoS validator") || !strings.Contains(ewoq.Role, "TeleporterManager") ||
		strings.Contains(ewoq.Role, "PoA") {
		t.Fatalf("EWOQ role: %s", ewoq.Role)
	}
	relayer, _ := bridgeRelayerKey("L1Chain")
	found := false
	for _, a := range accounts {
		if a.Name == "relayer-l1-0" {
			found = a.EVMAddress == crypto.PubkeyToAddress(relayer.PublicKey).Hex()
		}
		if a.Name == "nightly-relayer" {
			t.Fatal("nightly relayer listed for one L1")
		}
	}
	if !found {
		t.Fatalf("bridge relayer missing or wrong: %+v", accounts)
	}

	var blockchains struct{ Blockchains []any }
	read("blockchains.json", &blockchains)
	if len(blockchains.Blockchains) != 3 {
		t.Fatal("blockchains.json is not the platform.getBlockchains result")
	}
	var subnets map[string]map[string]any
	read("subnets.json", &subnets)
	if subnets["L1Subnet"]["managerChainID"] != "L1Chain" {
		t.Fatalf("subnets: %v", subnets)
	}
	var deployment map[string]any
	read("deployment.json", &deployment)
	if _, ok := deployment["l1s"]; !ok {
		t.Fatal("deployment.json is not the manifest")
	}
	readme, err := os.ReadFile(filepath.Join(dir, "README.md"))
	if err != nil || !strings.Contains(string(readme), "`http://127.0.0.1:29651/ext/bc/L1Chain/rpc`") ||
		!strings.Contains(string(readme), "P-custom18jma8ppw3nhx5r4ap8clazz0dps7rv5u9xde7p") {
		t.Fatalf("README.md: %s", readme)
	}
	info, _ := os.Stat(filepath.Join(dir, "chains.json"))
	if info.Mode().Perm() != 0644 {
		t.Fatal("the description is not readable")
	}
}

func TestDescribeWithoutHostPortsOrBridge(t *testing.T) {
	server := describeNode(t)
	defer server.Close()
	var m map[string]any
	json.Unmarshal([]byte(describeTestManifest), &m)
	delete(m["primary_network"].(map[string]any), "host")
	l1 := m["l1s"].([]any)[0].(map[string]any)
	delete(l1, "host")
	delete(l1, "bridge")
	b, _ := json.Marshal(m)
	dir := t.TempDir()
	if err := describe(context.Background(), server.URL, dir, string(b)); err != nil {
		t.Fatal(err)
	}
	var chains []describedChain
	data, _ := os.ReadFile(filepath.Join(dir, "chains.json"))
	json.Unmarshal(data, &chains)
	for _, c := range chains {
		if c.HostRPCURL != "" || c.RPCURL == "" {
			t.Fatalf("%s: %+v", c.Name, c)
		}
	}
	var accounts []devAccount
	data, _ = os.ReadFile(filepath.Join(dir, "accounts.json"))
	json.Unmarshal(data, &accounts)
	if len(accounts) != 1 || accounts[0].Name != "ewoq" || strings.Contains(accounts[0].Role, "Teleporter") {
		t.Fatalf("accounts without a bridge: %+v", accounts)
	}
}

func TestDescribeRejectsAnUnknownL1(t *testing.T) {
	server := describeNode(t)
	defer server.Close()
	manifest := strings.ReplaceAll(describeTestManifest, `"blockchain_id": "L1Chain"`, `"blockchain_id": "Missing"`)
	if err := describe(context.Background(), server.URL, t.TempDir(), manifest); err == nil {
		t.Fatal("an L1 that the P-Chain does not list was accepted")
	}
}
