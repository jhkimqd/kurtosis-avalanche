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
)

type Journal struct {
	Version     int    `json:"version"`
	Fingerprint string `json:"fingerprint"`
	TxID        string `json:"tx_id"`
	Signed      []byte `json:"signed"`
	State       string `json:"state"`
}

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
func pWallet(ctx context.Context, uri string, subnets ...ids.ID) (pwallet.Wallet, error) {
	if err := localOnly(ctx, uri); err != nil {
		return nil, err
	}
	return primary.MakePWallet(ctx, uri, secp256k1fx.NewKeychain(genesis.EWOQKey), primary.WalletConfig{SubnetIDs: subnets})
}
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
func create(ctx context.Context, uri, dir, genesisPath string) error {
	if e := localOnly(ctx, uri); e != nil {
		return e
	}
	data, e := os.ReadFile(genesisPath)
	if e != nil {
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
		u, e := w.Builder().NewCreateChainTx(subnet, data, constants.SubnetEVMID, nil, "Institutional L1", common.WithContext(ctx))
		return w, u, e
	})
	if e != nil {
		return e
	}
	return save(filepath.Join(dir, "chain.json"), map[string]any{"version": 1, "subnet_id": subnet.String(), "blockchain_id": chain.String(), "genesis_sha256": fmt.Sprintf("%x", sha256.Sum256(data))})
}
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
	for _, s := range args[5:] {
		i, e := strconv.Atoi(s)
		if e != nil || i < 3 || i >= len(network.Nodes)-1 {
			return fmt.Errorf("invalid validator index %q", s)
		}
		n := network.Nodes[i]
		id, e := ids.NodeIDFromString(n.ID)
		if e != nil {
			return e
		}
		validators = append(validators, &txs.ConvertSubnetToL1Validator{NodeID: id[:], Weight: 1000000, Balance: 100 * 1000000000, Signer: n.POP, RemainingBalanceOwner: owner, DeactivationOwner: owner})
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
