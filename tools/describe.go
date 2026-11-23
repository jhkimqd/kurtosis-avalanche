package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/utils/formatting/address"
	"github.com/ava-labs/libevm/crypto"
)

// describe writes what a user needs to reach and use the devnet to dir, the
// directory /opt/networks of the tools service. The files answer the usual
// first questions without an API call:
//
//	README.md         the chains, their URLs, and the accounts, for a reader
//	chains.json       one entry per chain: IDs, VM, and RPC URLs
//	blockchains.json  the result of platform.getBlockchains
//	subnets.json      the result of platform.getSubnet for each L1
//	accounts.json     the public development keys and what each one does
//	deployment.json   the deployment manifest
//
// The package runs describe once, at the end of the deployment. The files are
// a snapshot: a later change on the network does not update them.
func describe(ctx context.Context, uri, dir, manifestJSON string) error {
	if e := localOnly(ctx, uri); e != nil {
		return e
	}
	var m describeManifest
	if e := json.Unmarshal([]byte(manifestJSON), &m); e != nil {
		return fmt.Errorf("deployment manifest: %w", e)
	}
	pURL := strings.TrimRight(uri, "/") + "/ext/bc/P"

	var blockchains struct {
		Blockchains []struct {
			ID       string `json:"id"`
			Name     string `json:"name"`
			SubnetID string `json:"subnetID"`
			VMID     string `json:"vmID"`
		} `json:"blockchains"`
	}
	var rawBlockchains json.RawMessage
	if e := rpc(ctx, pURL, "platform.getBlockchains", map[string]any{}, &rawBlockchains); e != nil {
		return e
	}
	if e := json.Unmarshal(rawBlockchains, &blockchains); e != nil {
		return e
	}
	subnets := map[string]json.RawMessage{}
	for _, l1 := range m.L1s {
		var subnet json.RawMessage
		if e := rpc(ctx, pURL, "platform.getSubnet", map[string]any{"subnetID": l1.SubnetID}, &subnet); e != nil {
			return e
		}
		subnets[l1.SubnetID] = subnet
	}

	// The P-Chain is not in platform.getBlockchains; its IDs are fixed.
	pn := m.PrimaryNetwork
	chains := []describedChain{{
		Name: "P-Chain", BlockchainID: constants.PlatformChainID.String(),
		SubnetID: constants.PrimaryNetworkID.String(), VMID: constants.PlatformVMID.String(),
		RPCURL: pn.PChainRPCURL, HostRPCURL: pn.Host["p_chain_rpc_url"],
	}}
	for _, b := range blockchains.Blockchains {
		if b.SubnetID != constants.PrimaryNetworkID.String() {
			continue
		}
		c := describedChain{Name: b.Name, BlockchainID: b.ID, SubnetID: b.SubnetID, VMID: b.VMID}
		switch b.Name {
		case "X-Chain":
			c.RPCURL, c.HostRPCURL = pn.XChainRPCURL, pn.Host["x_chain_rpc_url"]
		case "C-Chain":
			c.EVMChainID = pn.CChainID
			c.RPCURL, c.WSURL = pn.CChainRPCURL, pn.CChainWSURL
			c.HostRPCURL, c.HostWSURL = pn.Host["c_chain_rpc_url"], pn.Host["c_chain_ws_url"]
		}
		chains = append(chains, c)
	}
	for _, l1 := range m.L1s {
		c := describedChain{
			Name: l1.Name, BlockchainID: l1.BlockchainID, SubnetID: l1.SubnetID, EVMChainID: l1.EVMChainID,
			HostRPCURL: l1.Host["rpc_url"], HostWSURL: l1.Host["ws_url"],
		}
		if len(l1.RPCURLs) > 0 {
			c.RPCURL = l1.RPCURLs[0]
		}
		if len(l1.WSURLs) > 0 {
			c.WSURL = l1.WSURLs[0]
		}
		for _, b := range blockchains.Blockchains {
			if b.ID == l1.BlockchainID {
				c.VMID = b.VMID
				c.ChainName = b.Name
			}
		}
		if c.VMID == "" {
			return fmt.Errorf("the P-Chain does not list blockchain %s of %s", l1.BlockchainID, l1.Name)
		}
		chains = append(chains, c)
	}
	accounts, e := devAccounts(m)
	if e != nil {
		return e
	}

	var deployment bytes.Buffer
	if e = json.Indent(&deployment, []byte(manifestJSON), "", "  "); e != nil {
		return e
	}
	files := map[string]any{
		"chains.json":      chains,
		"blockchains.json": rawBlockchains,
		"subnets.json":     subnets,
		"accounts.json":    accounts,
		"deployment.json":  json.RawMessage(deployment.Bytes()),
	}
	for name, value := range files {
		if e = writeReadable(filepath.Join(dir, name), value); e != nil {
			return e
		}
	}
	return writeFile(filepath.Join(dir, "README.md"), []byte(describeREADME(chains, accounts)))
}

// describeManifest holds the fields of the deployment manifest (main.star)
// that describe reads. `host` is missing when `rpc_port` is 0.
type describeManifest struct {
	PrimaryNetwork struct {
		PChainRPCURL string            `json:"p_chain_rpc_url"`
		XChainRPCURL string            `json:"x_chain_rpc_url"`
		CChainRPCURL string            `json:"c_chain_rpc_url"`
		CChainWSURL  string            `json:"c_chain_ws_url"`
		CChainID     uint64            `json:"c_chain_id"`
		Host         map[string]string `json:"host"`
	} `json:"primary_network"`
	L1s []struct {
		Name         string            `json:"name"`
		SubnetID     string            `json:"subnet_id"`
		BlockchainID string            `json:"blockchain_id"`
		EVMChainID   uint64            `json:"evm_chain_id"`
		RPCURLs      []string          `json:"rpc_urls"`
		WSURLs       []string          `json:"ws_urls"`
		Host         map[string]string `json:"host"`
		Bridge       json.RawMessage   `json:"bridge"`
		// One of `constants.VALIDATOR_MANAGEMENT` in src/config/constants.star.
		ValidatorManagement string `json:"validator_management"`
	} `json:"l1s"`
}

// describedChain is one entry of chains.json. The URLs are those of the first
// node of the chain: in the enclave, and on the host with a fixed `rpc_port`.
type describedChain struct {
	Name         string `json:"name"`
	ChainName    string `json:"chain_name,omitempty"`
	BlockchainID string `json:"blockchain_id"`
	SubnetID     string `json:"subnet_id"`
	VMID         string `json:"vm_id"`
	EVMChainID   uint64 `json:"evm_chain_id,omitempty"`
	RPCURL       string `json:"rpc_url"`
	WSURL        string `json:"ws_url,omitempty"`
	HostRPCURL   string `json:"host_rpc_url,omitempty"`
	HostWSURL    string `json:"host_ws_url,omitempty"`
}

// devAccount is one entry of accounts.json.
type devAccount struct {
	Name       string `json:"name"`
	Role       string `json:"role"`
	PrivateKey string `json:"private_key"`
	EVMAddress string `json:"evm_address"`
	PChainKey  string `json:"p_chain_private_key,omitempty"`
	PChainAddr string `json:"p_chain_address,omitempty"`
	XChainAddr string `json:"x_chain_address,omitempty"`
	Chains     string `json:"chains,omitempty"`
}

// devAccounts lists every key that the package signs with. All of them are
// public development keys: anyone can derive them, so they must never hold
// value on a public network.
func devAccounts(m describeManifest) ([]devAccount, error) {
	hrp := constants.GetHRP(networkID)
	short := genesis.EWOQKey.Address().Bytes()
	pAddr, e := address.Format("P", hrp, short)
	if e != nil {
		return nil, e
	}
	xAddr, e := address.Format("X", hrp, short)
	if e != nil {
		return nil, e
	}
	bridged := []string{}
	poa, pos := false, false
	for _, l1 := range m.L1s {
		if len(l1.Bridge) > 0 && string(l1.Bridge) != "null" {
			bridged = append(bridged, l1.Name)
		}
		if l1.ValidatorManagement == "poa" {
			poa = true
		} else {
			pos = true
		}
	}
	role := "Funded at genesis on the P-, X-, and C-Chain and on every L1. Signs every setup transaction."
	if poa {
		role += " Owns the ValidatorManager of each PoA L1."
	}
	if pos {
		role += " Owns every PoS validator and receives its rewards."
	}
	if len(bridged) > 0 {
		role += " Is the TeleporterManager of the bridge contracts and holds the CASH test token on the C-Chain."
	}
	accounts := []devAccount{{
		Name:       "ewoq",
		Role:       role,
		PrivateKey: "0x" + hex.EncodeToString(genesis.EWOQKey.Bytes()),
		EVMAddress: genesis.EWOQKey.EthAddress().Hex(),
		PChainKey:  genesis.EWOQKey.String(),
		PChainAddr: pAddr,
		XChainAddr: xAddr,
	}}
	evm := func(name, role, chains string, index int) devAccount {
		key := devKey(index)
		return devAccount{
			Name: name, Role: role, Chains: chains,
			PrivateKey: "0x" + hex.EncodeToString(crypto.FromECDSA(key)),
			EVMAddress: crypto.PubkeyToAddress(key.PublicKey).Hex(),
		}
	}
	if len(bridged) > 0 {
		chains := "c-chain, " + strings.Join(bridged, ", ")
		accounts = append(accounts,
			evm("bridge-recipient", "Receives the bridged tokens of the bridge smoke test, and spends one wei of them on the L1.", strings.Join(bridged, ", "), 8),
			evm("messenger-deployer", "Deploys TeleporterMessenger, so that it has the same address on every chain.", chains, 9),
			evm("token-remote-deployer", "Deploys NativeTokenRemote on each L1, at the address that the L1 genesis allows to mint.", strings.Join(bridged, ", "), 10),
		)
		for _, l1 := range m.L1s {
			if len(l1.Bridge) == 0 || string(l1.Bridge) == "null" {
				continue
			}
			key, e := bridgeRelayerKey(l1.BlockchainID)
			if e != nil {
				return nil, e
			}
			accounts = append(accounts, devAccount{
				Name:       "relayer-" + l1.Name,
				Role:       "Pays the gas of the ICM relayer service " + l1.Name + "-relayer, which delivers bridge messages.",
				PrivateKey: "0x" + hex.EncodeToString(crypto.FromECDSA(key)),
				EVMAddress: crypto.PubkeyToAddress(key.PublicKey).Hex(),
				Chains:     "c-chain, " + l1.Name,
			})
		}
	}
	// nightly.star needs the bridge and at least two L1s.
	if len(bridged) > 1 {
		accounts = append(accounts, evm("nightly-relayer", "Pays the gas of the relayer of the nightly messaging test (nightly.star). Funded only by that test.", strings.Join(bridged, ", "), 11))
	}
	return accounts, nil
}

// describeREADME renders README.md of the description directory.
func describeREADME(chains []describedChain, accounts []devAccount) string {
	var b strings.Builder
	b.WriteString("# Devnet description\n\n")
	b.WriteString("`lab describe` wrote this directory at the end of the deployment. It is a snapshot: it does not change when the network changes.\n\n")
	fmt.Fprintf(&b, "Avalanche network ID: `%d`.\n\n", networkID)
	b.WriteString("## Chains\n\n")
	b.WriteString("The URLs reach the first node of each chain. \"In the enclave\" works from any service of the enclave, such as this one. \"On the host\" works from the machine that runs Kurtosis; it is empty when `rpc_port` is 0.\n\n")
	b.WriteString("| Chain | Blockchain ID | EVM chain ID | In the enclave | On the host |\n| --- | --- | --- | --- | --- |\n")
	for _, c := range chains {
		evmID := ""
		if c.EVMChainID != 0 {
			evmID = fmt.Sprint(c.EVMChainID)
		}
		fmt.Fprintf(&b, "| %s | `%s` | %s | %s | %s |\n", c.Name, c.BlockchainID, evmID, code(c.RPCURL), code(c.HostRPCURL))
	}
	b.WriteString("\nA WebSocket URL of an EVM chain replaces `http` with `ws` and `/rpc` with `/ws`.\n\n")
	b.WriteString("## Accounts\n\n")
	b.WriteString("Public development keys: anyone can derive them. Never send them value on a public network. `accounts.json` holds the private keys.\n\n")
	b.WriteString("| Name | EVM address | Role |\n| --- | --- | --- |\n")
	for _, a := range accounts {
		fmt.Fprintf(&b, "| %s | `%s` | %s |\n", a.Name, a.EVMAddress, a.Role)
	}
	ewoq := accounts[0]
	fmt.Fprintf(&b, "\nThe EWOQ account on the P-Chain is `%s` and on the X-Chain `%s`. Its private key is `%s` (EVM) or `%s` (P-Chain and X-Chain tools).\n\n", ewoq.PChainAddr, ewoq.XChainAddr, ewoq.PrivateKey, ewoq.PChainKey)
	b.WriteString("## Files\n\n")
	b.WriteString("| File | Content |\n| --- | --- |\n")
	b.WriteString("| `chains.json` | One entry per chain: blockchain, subnet, and VM IDs, EVM chain ID, RPC and WebSocket URLs. |\n")
	b.WriteString("| `blockchains.json` | The result of `platform.getBlockchains`. |\n")
	b.WriteString("| `subnets.json` | The result of `platform.getSubnet` for the subnet of each L1, by subnet ID. |\n")
	b.WriteString("| `accounts.json` | The development accounts, with private keys and addresses. |\n")
	b.WriteString("| `deployment.json` | The deployment manifest: every URL, ID, contract address, and the arguments. |\n")
	return b.String()
}

func code(s string) string {
	if s == "" {
		return ""
	}
	return "`" + s + "`"
}

// writeReadable writes value as indented JSON. Unlike the journals, the files
// are meant to be read, so other users of the container may read them too.
func writeReadable(path string, value any) error {
	b, e := json.MarshalIndent(value, "", "  ")
	if e != nil {
		return e
	}
	return writeFile(path, append(b, '\n'))
}

func writeFile(path string, b []byte) error {
	if e := os.MkdirAll(filepath.Dir(path), 0755); e != nil {
		return e
	}
	tmp := path + ".tmp"
	if e := os.WriteFile(tmp, b, 0644); e != nil {
		return e
	}
	return os.Rename(tmp, path)
}
