package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	ethereum "github.com/ava-labs/libevm"
	"github.com/ava-labs/libevm/accounts/abi"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/core/types"
	"github.com/ava-labs/libevm/crypto"
	"github.com/ava-labs/libevm/ethclient"
)

// ContractArtifact is the ABI and bytecode of one contract, as stored in
// static_files/contracts.
type ContractArtifact struct {
	ABI      json.RawMessage `json:"abi"`
	Bytecode struct {
		Object         string `json:"object"`
		LinkReferences map[string]map[string][]struct {
			Start  int
			Length int
		} `json:"linkReferences"`
	} `json:"bytecode"`
}

// artifact loads a contract artifact and its parsed ABI.
func artifact(name string) (ContractArtifact, abi.ABI, error) {
	var a ContractArtifact
	b, e := os.ReadFile(filepath.Join("/fixtures/contracts", name+".json"))
	if e != nil {
		return a, abi.ABI{}, e
	}
	if e = json.Unmarshal(b, &a); e != nil {
		return a, abi.ABI{}, e
	}
	parsed, e := abi.JSON(strings.NewReader(string(a.ABI)))
	return a, parsed, e
}

// evmTx sends an EVM transaction from the EWOQ account. See evmTxAs.
func evmTx(ctx context.Context, url, dir, name string, to *common.Address, data []byte, value *big.Int, access types.AccessList) (*types.Receipt, error) {
	return evmTxAs(ctx, url, dir, name, to, data, value, access, genesis.EWOQKey.ToECDSA())
}

// evmTxAs sends one EVM transaction exactly once and waits for its receipt.
//
// It signs the transaction and writes it to the journal dir/name.evm.json
// before it sends it. A rerun finds the journal and sends the same bytes again,
// which is harmless. access carries a Warp message for the Warp precompile; gas
// cannot be estimated for such a call, so it gets a fixed limit.
func evmTxAs(ctx context.Context, url, dir, name string, to *common.Address, data []byte, value *big.Int, access types.AccessList, key *ecdsa.PrivateKey) (*types.Receipt, error) {
	from := crypto.PubkeyToAddress(key.PublicKey)
	base, _, ok := strings.Cut(url, "/ext/bc/")
	if !ok {
		return nil, fmt.Errorf("expected Avalanche URL")
	}
	if e := localOnly(ctx, base); e != nil {
		return nil, e
	}
	client, e := ethclient.DialContext(ctx, url)
	if e != nil {
		return nil, e
	}
	defer client.Close()
	chain, e := client.ChainID(ctx)
	if e != nil {
		return nil, e
	}
	identity, e := deploymentIdentity(ctx, base)
	if e != nil {
		return nil, e
	}
	_, blockchain, _ := strings.Cut(url, "/ext/bc/")
	fingerprint, _ := json.Marshal([]any{identity, blockchain, chain.String(), from, to, data, value, access})
	digest := fmt.Sprintf("%x", sha256.Sum256(fingerprint))
	path := filepath.Join(dir, name+".evm.json")
	var j Journal
	b, e := os.ReadFile(path)
	tx := new(types.Transaction)
	if e == nil {
		if e = json.Unmarshal(b, &j); e != nil {
			return nil, e
		}
		if j.Fingerprint != digest {
			return nil, fmt.Errorf("EVM operation input mismatch: %s", name)
		}
		if e = tx.UnmarshalBinary(j.Signed); e != nil {
			return nil, e
		}
		if j.Version != 1 || tx.Hash().Hex() != j.TxID || tx.ChainId().Cmp(chain) != 0 {
			return nil, fmt.Errorf("invalid EVM journal")
		}
	} else if !os.IsNotExist(e) {
		return nil, e
	} else {
		nonce, e := client.PendingNonceAt(ctx, from)
		if e != nil {
			return nil, e
		}
		fee, e := client.SuggestGasPrice(ctx)
		if e != nil {
			return nil, e
		}
		header, e := client.HeaderByNumber(ctx, nil)
		if e != nil {
			return nil, e
		}
		// Warp predicate calls cannot be estimated without predicate verification.
		gas := min(uint64(10000000), header.GasLimit)
		if len(access) == 0 {
			gas, e = client.EstimateGas(ctx, ethereum.CallMsg{From: from, To: to, Value: value, Data: data})
			if e != nil {
				return nil, e
			}
			if gas > header.GasLimit {
				return nil, fmt.Errorf("estimated gas %d exceeds block gas limit %d", gas, header.GasLimit)
			}
			gas += min(gas/5, header.GasLimit-gas)
			if to == nil && gas < 8000000 {
				gas = 8000000
			}
			gas = min(gas, header.GasLimit)
		}
		unsigned := types.NewTx(&types.AccessListTx{ChainID: chain, Nonce: nonce, GasPrice: fee, Gas: gas, To: to, Value: value, Data: data, AccessList: access})
		tx, e = types.SignTx(unsigned, types.LatestSignerForChainID(chain), key)
		if e != nil {
			return nil, e
		}
		raw, e := tx.MarshalBinary()
		if e != nil {
			return nil, e
		}
		j = Journal{1, digest, tx.Hash().Hex(), raw, "prepared"}
		if e = atomicJSON(path, j); e != nil {
			return nil, e
		}
	}
	receipt, e := client.TransactionReceipt(ctx, tx.Hash())
	if e != nil || receipt == nil {
		// A duplicate broadcast is safe; the signed transaction hash remains unchanged.
		sendErr := client.SendTransaction(ctx, tx)
		if sendErr == nil {
			j.State = "submitted"
			if e = atomicJSON(path, j); e != nil {
				return nil, e
			}
		}
		for {
			receipt, e = client.TransactionReceipt(ctx, tx.Hash())
			if e == nil && receipt != nil {
				break
			}
			select {
			case <-ctx.Done():
				return nil, fmt.Errorf("unresolved EVM transaction %s (send: %v): %w", tx.Hash(), sendErr, ctx.Err())
			case <-time.After(time.Second):
			}
		}
	}
	if receipt.Status != 1 {
		j.State = "reverted"
		if e = atomicJSON(path, j); e != nil {
			return nil, e
		}
		return nil, fmt.Errorf("EVM transaction reverted: %s", tx.Hash())
	}
	j.State = "accepted"
	if e = atomicJSON(path, j); e != nil {
		return nil, e
	}
	if e = atomicJSON(filepath.Join(dir, name+".receipt.json"), receipt); e != nil {
		return nil, e
	}
	return receipt, nil
}

// deploy deploys a contract from the EWOQ account. It links library into the
// bytecode where the artifact references one.
func deploy(ctx context.Context, url, dir, name string, library common.Address, constructor ...any) (common.Address, error) {
	a, parsed, e := artifact(name)
	if e != nil {
		return common.Address{}, e
	}
	code := strings.TrimPrefix(a.Bytecode.Object, "0x")
	for _, libs := range a.Bytecode.LinkReferences {
		for _, refs := range libs {
			for _, ref := range refs {
				if ref.Length != 20 || library == (common.Address{}) {
					return common.Address{}, fmt.Errorf("unresolved library for %s", name)
				}
				start := 2 * ref.Start
				code = code[:start] + hex.EncodeToString(library[:]) + code[start+40:]
			}
		}
	}
	data, e := hex.DecodeString(code)
	if e != nil {
		return common.Address{}, e
	}
	args, e := parsed.Pack("", constructor...)
	if e != nil {
		return common.Address{}, e
	}
	receipt, e := evmTx(ctx, url, dir, "deploy-"+name, nil, append(data, args...), big.NewInt(0), nil)
	if e != nil {
		return common.Address{}, e
	}
	return receipt.ContractAddress, nil
}

// invoke calls a state-changing contract method from the EWOQ account. The
// method name is also the journal name. access carries a Warp message if the
// method verifies one.
func invoke(ctx context.Context, url, dir, name, contract string, address common.Address, access types.AccessList, args ...any) error {
	_, parsed, e := artifact(contract)
	if e != nil {
		return e
	}
	data, e := parsed.Pack(name, args...)
	if e != nil {
		return e
	}
	_, e = evmTx(ctx, url, dir, name, &address, data, big.NewInt(0), access)
	return e
}
