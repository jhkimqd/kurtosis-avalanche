package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/vms/platformvm"
	"github.com/ava-labs/avalanchego/vms/platformvm/signer"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/message"
	"github.com/ava-labs/avalanchego/vms/secp256k1fx"
	psigner "github.com/ava-labs/avalanchego/wallet/chain/p/signer"
	pwallet "github.com/ava-labs/avalanchego/wallet/chain/p/wallet"
	"github.com/ava-labs/avalanchego/wallet/subnet/primary"
	"github.com/ava-labs/avalanchego/wallet/subnet/primary/common"
	"github.com/ava-labs/libevm/crypto"
)

// Journal is the on-disk record of one transaction. It is written before the
// transaction is sent, so a rerun sends the same signed bytes again instead of
// building a second transaction.
type Journal struct {
	Version     int    `json:"version"`
	Fingerprint string `json:"fingerprint"`
	TxID        string `json:"tx_id"`
	Signed      []byte `json:"signed"`
	State       string `json:"state"`
}

// atomicJSON writes v to path so that a crash leaves either the old or the new
// file, never a partial one: write a temporary file, sync it, rename it, and
// sync the directory.
func atomicJSON(path string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".journal-*")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if _, e = f.Write(b); e != nil {
		f.Close()
		return e
	}
	if e = f.Sync(); e != nil {
		f.Close()
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	if e = os.Rename(f.Name(), path); e != nil {
		return e
	}
	d, e := os.Open(filepath.Dir(path))
	if e != nil {
		return e
	}
	defer d.Close()
	return d.Sync()
}

// pWallet returns a P-Chain wallet for the EWOQ key. The wallet also loads the
// given subnets, which the EWOQ key owns.
func pWallet(ctx context.Context, uri string, subnets ...ids.ID) (pwallet.Wallet, error) {
	if err := localOnly(ctx, uri); err != nil {
		return nil, err
	}
	return primary.MakePWallet(ctx, uri, secp256k1fx.NewKeychain(genesis.EWOQKey), primary.WalletConfig{SubnetIDs: subnets})
}

// issue sends one P-Chain transaction exactly once and waits until the chain
// commits it.
//
// path is the journal file. input describes the operation: its hash is stored
// in the journal, so a journal is never reused for a different operation.
// build creates the unsigned transaction; it runs on the first attempt only.
func issue(ctx context.Context, uri, path string, input any, build func() (pwallet.Wallet, txs.UnsignedTx, error)) (ids.ID, error) {
	identity, e := deploymentIdentity(ctx, uri)
	if e != nil {
		return ids.Empty, e
	}
	encoded, _ := json.Marshal([]any{identity, input})
	digest := fmt.Sprintf("%x", sha256.Sum256(encoded))
	j := Journal{}
	b, e := os.ReadFile(path)
	if e == nil {
		if e = json.Unmarshal(b, &j); e != nil {
			return ids.Empty, e
		}
		if j.Fingerprint != digest {
			return ids.Empty, fmt.Errorf("journal input mismatch: %s", path)
		}
	} else if !os.IsNotExist(e) {
		return ids.Empty, e
	} else {
		w, u, e := build()
		if e != nil {
			return ids.Empty, e
		}
		tx, e := psigner.SignUnsigned(ctx, w.Signer(), u)
		if e != nil {
			return ids.Empty, e
		}
		j = Journal{1, digest, tx.ID().String(), tx.Bytes(), "prepared"}
		if e = atomicJSON(path, j); e != nil {
			return ids.Empty, e
		}
	}
	id, e := ids.FromString(j.TxID)
	if e != nil {
		return ids.Empty, e
	}
	parsed, e := txs.Parse(txs.Codec, j.Signed)
	if e != nil {
		return ids.Empty, e
	}
	if j.Version != 1 || parsed.ID() != id {
		return ids.Empty, fmt.Errorf("invalid journal version or transaction hash")
	}
	client := platformvm.NewClient(uri)
	var status struct {
		Status string `json:"status"`
	}
	if e = rpc(ctx, uri+"/ext/bc/P", "platform.getTxStatus", map[string]any{"txID": j.TxID}, &status); e != nil {
		return ids.Empty, e
	}
	if status.Status == "Committed" {
		j.State = "accepted"
		return id, atomicJSON(path, j)
	}
	if status.Status == "Aborted" {
		return ids.Empty, fmt.Errorf("transaction %s aborted", id)
	}
	if status.Status == "Unknown" {
		// Reissue exactly the same signed bytes. Never rebuild an ambiguous operation.
		if _, e = client.IssueTx(ctx, j.Signed); e != nil {
			return ids.Empty, fmt.Errorf("submission uncertain; preserve journal and retry: %w", e)
		}
		j.State = "submitted"
		if e = atomicJSON(path, j); e != nil {
			return ids.Empty, e
		}
	}
	for {
		if e = rpc(ctx, uri+"/ext/bc/P", "platform.getTxStatus", map[string]any{"txID": j.TxID}, &status); e != nil {
			return ids.Empty, e
		}
		if status.Status == "Committed" {
			j.State = "accepted"
			return id, atomicJSON(path, j)
		}
		if status.Status == "Aborted" {
			return ids.Empty, fmt.Errorf("transaction aborted: %s", id)
		}
		select {
		case <-ctx.Done():
			return ids.Empty, ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// create registers a new subnet and its Subnet-EVM blockchain on the P-Chain.
//
// The genesis is the base file merged with the user overrides, with the chain
// ID of the package. With the bridge, the genesis also lets the future
// NativeTokenRemote contract mint the native token. create writes genesis.json,
// the config files of the L1, and chain.json with the new IDs.
func create(ctx context.Context, uri, dir, genesisPath, chainID, overrides string, bridge bool, chainConfig, subnetConfig string) error {
	if e := localOnly(ctx, uri); e != nil {
		return e
	}
	data, e := os.ReadFile(genesisPath)
	if e != nil {
		return e
	}
	evmID, e := strconv.ParseUint(chainID, 10, 64)
	if e != nil {
		return e
	}
	var g map[string]any
	if e = json.Unmarshal(data, &g); e != nil {
		return e
	}
	var extra map[string]any
	if e = json.Unmarshal([]byte(overrides), &extra); e != nil {
		return e
	}
	if e = normalizeAlloc(g); e != nil {
		return e
	}
	if e = normalizeAlloc(extra); e != nil {
		return e
	}
	mergeJSON(g, extra)
	config, ok := g["config"].(map[string]any)
	if !ok {
		return fmt.Errorf("genesis config must be an object")
	}
	config["chainId"] = evmID
	if e = setHeaderGasLimit(g, config); e != nil {
		return e
	}
	if bridge {
		remote := crypto.CreateAddress(crypto.PubkeyToAddress(devKey(10).PublicKey), 0)
		config["contractNativeMinterConfig"] = map[string]any{"blockTimestamp": 0, "enabledAddresses": []string{remote.Hex()}}
	}
	data, e = json.Marshal(g)
	if e != nil {
		return e
	}
	if e = save(filepath.Join(dir, "genesis.json"), g); e != nil {
		return e
	}
	owner := &secp256k1fx.OutputOwners{Threshold: 1, Addrs: []ids.ShortID{genesis.EWOQKey.Address()}}
	subnet, e := issue(ctx, uri, filepath.Join(dir, "subnet.journal.json"), owner, func() (pwallet.Wallet, txs.UnsignedTx, error) {
		w, e := pWallet(ctx, uri)
		if e != nil {
			return nil, nil, e
		}
		u, e := w.Builder().NewCreateSubnetTx(owner, common.WithContext(ctx))
		return w, u, e
	})
	if e != nil {
		return e
	}
	chain, e := issue(ctx, uri, filepath.Join(dir, "chain.journal.json"), map[string]any{"subnet": subnet.String(), "genesis": string(data)}, func() (pwallet.Wallet, txs.UnsignedTx, error) {
		w, e := pWallet(ctx, uri, subnet)
		if e != nil {
			return nil, nil, e
		}
		u, e := w.Builder().NewCreateChainTx(subnet, data, constants.SubnetEVMID, nil, "Avalanche Devnet", common.WithContext(ctx))
		return w, u, e
	})
	if e != nil {
		return e
	}
	if e = writeL1Config(filepath.Join(dir, "config"), subnet.String(), chain.String(), chainConfig, subnetConfig); e != nil {
		return e
	}
	return save(filepath.Join(dir, "chain.json"), map[string]any{"version": 1, "subnet_id": subnet.String(), "blockchain_id": chain.String(), "genesis_sha256": fmt.Sprintf("%x", sha256.Sum256(data))})
}

// writeL1Config writes the config files that every node of an L1 mounts:
//
//	chains/<blockchain-id>/config.json   Subnet-EVM chain config
//	subnets/<subnet-id>.json             subnet config
//
// AvalancheGo finds both files by ID, and the IDs exist only after the create
// transactions. Kurtosis cannot put such a late value into a file name, so the
// files are written here.
func writeL1Config(dir, subnetID, blockchainID, chainConfig, subnetConfig string) error {
	for path, content := range map[string]string{
		filepath.Join(dir, "chains", blockchainID, "config.json"): chainConfig,
		filepath.Join(dir, "subnets", subnetID+".json"):           subnetConfig,
	} {
		var object map[string]any
		if e := json.Unmarshal([]byte(content), &object); e != nil {
			return fmt.Errorf("%s must be a JSON object: %w", filepath.Base(path), e)
		}
		if e := save(path, object); e != nil {
			return e
		}
	}
	return nil
}

// convert turns the subnet into an L1 with a ConvertSubnetToL1Tx.
//
// args: primary URI, state directory, blockchain that hosts the
// ValidatorManager ("self" is the L1), ValidatorManager address, directory of
// network.json, validator weight, and the node indexes of the first validators.
// Each first validator gets that weight and 100 AVAX on the P-Chain, from
// which the P-Chain takes its continuous validator fee.
func convert(ctx context.Context, args []string) error {
	uri, dir, managerChain, manager, fixture := args[0], args[1], args[2], args[3], args[4]
	if e := localOnly(ctx, uri); e != nil {
		return e
	}
	var chain struct {
		Subnet string `json:"subnet_id"`
		Chain  string `json:"blockchain_id"`
	}
	b, e := os.ReadFile(filepath.Join(dir, "chain.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &chain); e != nil {
		return e
	}
	sid, e := ids.FromString(chain.Subnet)
	if e != nil {
		return e
	}
	if managerChain == "self" {
		managerChain = chain.Chain
	}
	cid, e := ids.FromString(managerChain)
	if e != nil {
		return e
	}
	addr, e := hex.DecodeString(strings.TrimPrefix(manager, "0x"))
	if e != nil || len(addr) != 20 {
		return fmt.Errorf("manager must be a 20-byte hex address")
	}
	var network struct {
		Nodes []struct {
			ID  string                   `json:"node_id"`
			POP signer.ProofOfPossession `json:"pop"`
		} `json:"nodes"`
	}
	b, e = os.ReadFile(filepath.Join(fixture, "network.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &network); e != nil {
		return e
	}
	validators := []*txs.ConvertSubnetToL1Validator{}
	owner := message.PChainOwner{Threshold: 1, Addresses: []ids.ShortID{genesis.EWOQKey.Address()}}
	weight, e := strconv.ParseUint(args[5], 10, 64)
	if e != nil || weight == 0 {
		return fmt.Errorf("invalid conversion weight")
	}
	for _, s := range args[6:] {
		i, e := strconv.Atoi(s)
		if e != nil || i < 0 || i >= len(network.Nodes) {
			return fmt.Errorf("invalid validator index %q", s)
		}
		n := network.Nodes[i]
		id, e := ids.NodeIDFromString(n.ID)
		if e != nil {
			return e
		}
		validators = append(validators, &txs.ConvertSubnetToL1Validator{NodeID: id[:], Weight: weight, Balance: 100 * 1000000000, Signer: n.POP, RemainingBalanceOwner: owner, DeactivationOwner: owner})
	}
	sort.Slice(validators, func(i, j int) bool { return bytes.Compare(validators[i].NodeID, validators[j].NodeID) < 0 })
	id, e := issue(ctx, uri, filepath.Join(dir, "conversion.journal.json"), map[string]any{"subnet": sid.String(), "manager_chain": cid.String(), "manager": manager, "validators": validators}, func() (pwallet.Wallet, txs.UnsignedTx, error) {
		w, e := pWallet(ctx, uri, sid)
		if e != nil {
			return nil, nil, e
		}
		u, e := w.Builder().NewConvertSubnetToL1Tx(sid, cid, addr, validators, common.WithContext(ctx))
		return w, u, e
	})
	if e != nil {
		return e
	}
	return save(filepath.Join(dir, "conversion.json"), map[string]any{"tx_id": id.String(), "manager_chain": cid.String(), "manager": manager, "validators": validators})
}

// setHeaderGasLimit copies config.feeConfig.gasLimit into the gasLimit of the
// genesis header. Subnet-EVM refuses a genesis in which the two differ, and by
// then the chain exists on the P-Chain and cannot be changed.
func setHeaderGasLimit(g, config map[string]any) error {
	fee, _ := config["feeConfig"].(map[string]any)
	limit, ok := fee["gasLimit"].(float64)
	if !ok || limit < 1 || limit != float64(uint64(limit)) {
		return fmt.Errorf("genesis config.feeConfig.gasLimit must be a positive whole number")
	}
	g["gasLimit"] = fmt.Sprintf("0x%x", uint64(limit))
	return nil
}

// normalizeAlloc rewrites the account keys of a genesis to lowercase hex
// without the 0x prefix. An override then merges into the base entry of the
// same address instead of adding a second entry in another spelling.
func normalizeAlloc(g map[string]any) error {
	alloc, ok := g["alloc"].(map[string]any)
	if !ok {
		return nil
	}
	normalized := make(map[string]any, len(alloc))
	for address, account := range alloc {
		key := strings.TrimPrefix(strings.ToLower(address), "0x")
		if _, duplicate := normalized[key]; duplicate {
			return fmt.Errorf("genesis alloc lists account %s twice", address)
		}
		normalized[key] = account
	}
	g["alloc"] = normalized
	return nil
}

// mergeJSON copies src into dst. Nested objects merge key by key; any other
// value, including a list, replaces the value in dst. A null value changes
// nothing: YAML reads a key that holds only comments as null.
func mergeJSON(dst, src map[string]any) {
	for key, value := range src {
		if value == nil {
			continue
		}
		child, ok := value.(map[string]any)
		existing, exists := dst[key].(map[string]any)
		if ok && exists {
			mergeJSON(existing, child)
		} else {
			dst[key] = value
		}
	}
}
