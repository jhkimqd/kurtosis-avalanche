package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/message"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/payload"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/core/types"
)

type Chain struct {
	Subnet string `json:"subnet_id"`
	Chain  string `json:"blockchain_id"`
}
type InitialValidator struct {
	NodeID       []byte
	BlsPublicKey []byte
	Weight       uint64
}
type ConversionData struct {
	SubnetID                     [32]byte
	ValidatorManagerBlockchainID [32]byte
	ValidatorManagerAddress      common.Address
	InitialValidators            []InitialValidator
}

func predicate(signed []byte) types.AccessList {
	data := append(append([]byte{}, signed...), 255)
	for len(data)%32 != 0 {
		data = append(data, 0)
	}
	keys := []common.Hash{}
	for i := 0; i < len(data); i += 32 {
		keys = append(keys, common.BytesToHash(data[i:i+32]))
	}
	return types.AccessList{{Address: common.HexToAddress("0x0200000000000000000000000000000000000005"), StorageKeys: keys}}
}
func aggregate(ctx context.Context, url string, request any) ([]byte, error) {
	body, e := json.Marshal(request)
	if e != nil {
		return nil, e
	}
	var last error
	for i := 0; i < 30; i++ {
		req, e := http.NewRequestWithContext(ctx, "POST", url+"/aggregate-signatures", bytes.NewReader(body))
		if e != nil {
			return nil, e
		}
		req.Header.Set("Content-Type", "application/json")
		resp, e := httpClient.Do(req)
		if e == nil {
			b, re := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
			resp.Body.Close()
			if re == nil && resp.StatusCode == 200 {
				var result struct {
					Signed string `json:"signed-message"`
				}
				if e = json.Unmarshal(b, &result); e == nil && result.Signed != "" {
					return hex.DecodeString(strings.TrimPrefix(result.Signed, "0x"))
				}
			}
			last = fmt.Errorf("aggregate status %d: %s", resp.StatusCode, string(b))
		} else {
			last = e
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	return nil, last
}
func initializeManager(ctx context.Context, uri, url, dir, aggregator string) error {
	var c Chain
	b, e := os.ReadFile(filepath.Join(dir, "chain.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &c); e != nil {
		return e
	}
	sid, e := ids.FromString(c.Subnet)
	if e != nil {
		return e
	}
	cid, e := ids.FromString(c.Chain)
	if e != nil {
		return e
	}
	var conversion struct {
		Manager      string                            `json:"manager"`
		ManagerChain string                            `json:"manager_chain"`
		Validators   []*txs.ConvertSubnetToL1Validator `json:"validators"`
	}
	b, e = os.ReadFile(filepath.Join(dir, "conversion.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &conversion); e != nil {
		return e
	}
	if conversion.ManagerChain != c.Chain {
		return fmt.Errorf("this manager profile requires own-L1 placement")
	}
	if !strings.HasSuffix(url, "/ext/bc/"+c.Chain+"/rpc") {
		return fmt.Errorf("manager RPC does not match deployment blockchain")
	}
	library, e := deploy(ctx, url, dir, "ValidatorMessages", common.Address{})
	if e != nil {
		return e
	}
	manager, e := deploy(ctx, url, dir, "ValidatorManager", library, uint8(0))
	if e != nil {
		return e
	}
	if manager != common.HexToAddress(conversion.Manager) {
		return fmt.Errorf("manager address differs from conversion: %s", manager)
	}
	settings := struct {
		Admin                  common.Address
		SubnetID               [32]byte
		ChurnPeriodSeconds     uint64
		MaximumChurnPercentage uint8
	}{genesis.EWOQKey.EthAddress(), sid, 1, 20}
	if e = invoke(ctx, url, dir, "initialize", "ValidatorManager", manager, nil, settings); e != nil {
		return e
	}
	proofPath := filepath.Join(dir, "conversion-proof.json")
	var stored types.AccessList
	if b, e = os.ReadFile(proofPath); e == nil {
		if e = json.Unmarshal(b, &stored); e != nil {
			return e
		}
	} else if !os.IsNotExist(e) {
		return e
	}
	if len(stored) == 0 {
		var sub struct {
			ConversionID string `json:"conversionID"`
		}
		if e = rpc(ctx, uri+"/ext/bc/P", "platform.getSubnet", map[string]any{"subnetID": c.Subnet}, &sub); e != nil {
			return e
		}
		conversionID, e := ids.FromString(sub.ConversionID)
		if e != nil {
			return e
		}
		msg, e := message.NewSubnetToL1Conversion(conversionID)
		if e != nil {
			return e
		}
		addressed, e := payload.NewAddressedCall(nil, msg.Bytes())
		if e != nil {
			return e
		}
		unsigned, e := warp.NewUnsignedMessage(88888, ids.Empty, addressed.Bytes())
		if e != nil {
			return e
		}
		var epoch struct {
			Height uint64 `json:"pChainHeight"`
		}
		base, _, _ := strings.Cut(url, "/ext/bc/")
		// JSON-RPC emits uint64 as strings on some node builds; decode generically below.
		var raw map[string]json.RawMessage
		if e = rpc(ctx, base+"/ext/bc/"+c.Chain+"/proposervm", "proposervm.getCurrentEpoch", map[string]any{}, &raw); e != nil {
			return e
		}
		h := strings.Trim(string(raw["pChainHeight"]), "\"")
		if _, e = fmt.Sscan(h, &epoch.Height); e != nil {
			return e
		}
		signed, e := aggregate(ctx, aggregator, map[string]any{"message": "0x" + hex.EncodeToString(unsigned.Bytes()), "justification": "0x" + hex.EncodeToString(sid[:]), "signing-subnet-id": c.Subnet, "quorum-percentage": 67, "pchain-height": epoch.Height})
		if e != nil {
			return e
		}
		stored = predicate(signed)
		if e = atomicJSON(proofPath, stored); e != nil {
			return e
		}
	}
	data := ConversionData{SubnetID: sid, ValidatorManagerBlockchainID: cid, ValidatorManagerAddress: manager}
	for _, v := range conversion.Validators {
		data.InitialValidators = append(data.InitialValidators, InitialValidator{v.NodeID, v.Signer.PublicKey[:], v.Weight})
	}
	if e = invoke(ctx, url, dir, "initializeValidatorSet", "ValidatorManager", manager, stored, data, uint32(0)); e != nil {
		return e
	}
	return save(filepath.Join(dir, "manager.json"), map[string]any{"address": manager.Hex(), "library": library.Hex(), "mode": "poa", "initialized": true, "location": "self", "bootstrap_validators": len(conversion.Validators)})
}
