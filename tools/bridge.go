package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/crypto"
	"github.com/ava-labs/libevm/ethclient"
)

// Public development-only accounts reserve stable deployment addresses.
func devKey(index int) *ecdsa.PrivateKey {
	key, err := crypto.HexToECDSA(fmt.Sprintf("%064x", index))
	if err != nil {
		panic(err)
	}
	return key
}
func units(n int64) *big.Int { return new(big.Int).Mul(big.NewInt(n), big.NewInt(1e18)) }

type BridgeState struct {
	Messenger, CRegistry, LRegistry, Token, Home, Remote common.Address
	CChain, LChain                                       string
	InitialSupply                                        *big.Int
}

func deployAs(ctx context.Context, url, dir, name string, key *ecdsa.PrivateKey, args ...any) (common.Address, error) {
	a, parsed, e := artifact(name)
	if e != nil {
		return common.Address{}, e
	}
	if len(a.Bytecode.LinkReferences) != 0 {
		return common.Address{}, fmt.Errorf("bridge artifact %s needs library linking", name)
	}
	code, e := hex.DecodeString(strings.TrimPrefix(a.Bytecode.Object, "0x"))
	if e != nil {
		return common.Address{}, e
	}
	constructor, e := parsed.Pack("", args...)
	if e != nil {
		return common.Address{}, e
	}
	receipt, e := evmTxAs(ctx, url, dir, "deploy-"+name, nil, append(code, constructor...), big.NewInt(0), nil, key)
	if e != nil {
		return common.Address{}, e
	}
	return receipt.ContractAddress, nil
}

func bridge(ctx context.Context, stage, uri, url, dir string) error {
	if e := localOnly(ctx, uri); e != nil {
		return e
	}
	path := filepath.Join(dir, "bridge")
	var state BridgeState
	if stage == "bridge-deploy" {
		return deployBridge(ctx, uri, url, dir, path)
	}
	b, e := os.ReadFile(filepath.Join(path, "contracts.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &state); e != nil {
		return e
	}
	cRPC := uri + "/ext/bc/C/rpc"
	cid, e := ids.FromString(state.LChain)
	if e != nil {
		return e
	}
	if stage == "bridge-activate" {
		fee := struct {
			FeeTokenAddress common.Address
			Amount          *big.Int
		}{common.Address{}, big.NewInt(0)}
		if e = invoke(ctx, url, path, "registerWithHome", "NativeTokenRemote", state.Remote, nil, fee); e != nil {
			return e
		}
		for {
			values, e := view(ctx, cRPC, "ERC20TokenHome", state.Home, "getRemoteTokenTransferrerSettings", [32]byte(cid), state.Remote)
			if e != nil {
				return e
			}
			b, e := json.Marshal(values[0])
			if e != nil {
				return e
			}
			var info struct{ Registered bool }
			if e = json.Unmarshal(b, &info); e != nil {
				return e
			}
			if info.Registered {
				break
			}
			select {
			case <-ctx.Done():
				return fmt.Errorf("remote registration delivery: %w", ctx.Err())
			case <-time.After(time.Second):
			}
		}
		if e = invoke(ctx, cRPC, filepath.Join(path, "collateral"), "approve", "CashToken", state.Token, nil, state.Home, state.InitialSupply); e != nil {
			return e
		}
		if e = invoke(ctx, cRPC, path, "addCollateral", "ERC20TokenHome", state.Home, nil, [32]byte(cid), state.Remote, state.InitialSupply); e != nil {
			return e
		}
		balance, e := tokenBalance(ctx, cRPC, state.Token, state.Home)
		if e != nil {
			return e
		}
		if balance.Cmp(state.InitialSupply) < 0 {
			return fmt.Errorf("genesis collateral missing")
		}
		return save(filepath.Join(path, "collateral.json"), map[string]any{"registered": true, "genesis_backing": state.InitialSupply.String()})
	}
	if stage != "bridge-smoke" {
		return fmt.Errorf("unknown bridge stage")
	}
	return bridgeSmoke(ctx, cRPC, url, path, state, cid)
}

func deployBridge(ctx context.Context, uri, url, dir, path string) error {
	var chain Chain
	b, e := os.ReadFile(filepath.Join(dir, "chain.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &chain); e != nil {
		return e
	}
	var cInfo struct {
		BlockchainID string `json:"blockchainID"`
	}
	if e = rpc(ctx, uri+"/ext/info", "info.getBlockchainID", map[string]any{"alias": "C"}, &cInfo); e != nil {
		return e
	}
	cID, e := ids.FromString(cInfo.BlockchainID)
	if e != nil {
		return e
	}
	state := BridgeState{CChain: cInfo.BlockchainID, LChain: chain.Chain}
	var g struct {
		Alloc map[string]struct{ Balance string }
	}
	b, e = os.ReadFile(filepath.Join(dir, "genesis.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &g); e != nil {
		return e
	}
	state.InitialSupply = new(big.Int)
	for _, account := range g.Alloc {
		n, ok := new(big.Int).SetString(account.Balance, 0)
		if !ok {
			return fmt.Errorf("invalid genesis balance")
		}
		state.InitialSupply.Add(state.InitialSupply, n)
	}
	admin := genesis.EWOQKey.EthAddress()
	cRPC := uri + "/ext/bc/C/rpc"
	cDir := "/state/c-chain"
	td := crypto.PubkeyToAddress(devKey(9).PublicKey)
	rd := crypto.PubkeyToAddress(devKey(10).PublicKey)
	relayKey, e := crypto.ToECDSA(crypto.Keccak256([]byte("kurtosis-devnet-relayer:" + chain.Chain)))
	if e != nil {
		return e
	}
	relay := crypto.PubkeyToAddress(relayKey.PublicKey)
	for _, network := range []struct{ URL, Dir string }{{cRPC, cDir}, {url, path}} {
		for _, fund := range []struct {
			Name    string
			Address common.Address
			Amount  *big.Int
		}{{"messenger", td, units(5)}, {"relayer-" + chain.Chain, relay, units(10)}} {
			if _, e = evmTx(ctx, network.URL, network.Dir, "fund-"+fund.Name, &fund.Address, nil, fund.Amount, nil); e != nil {
				return e
			}
		}
		messenger, e := deployAs(ctx, network.URL, network.Dir, "TeleporterMessenger", devKey(9))
		if e != nil {
			return e
		}
		expected := crypto.CreateAddress(td, 0)
		if messenger != expected {
			return fmt.Errorf("messenger deployment address mismatch")
		}
		state.Messenger = messenger
	}
	cc, e := ethclient.DialContext(ctx, cRPC)
	if e != nil {
		return e
	}
	defer cc.Close()
	lc, e := ethclient.DialContext(ctx, url)
	if e != nil {
		return e
	}
	defer lc.Close()
	cCode, e := cc.CodeAt(ctx, state.Messenger, nil)
	if e != nil {
		return e
	}
	lCode, e := lc.CodeAt(ctx, state.Messenger, nil)
	if e != nil {
		return e
	}
	if len(cCode) == 0 || !bytes.Equal(cCode, lCode) {
		return fmt.Errorf("messenger runtime code differs")
	}
	entries := []struct {
		Version         *big.Int
		ProtocolAddress common.Address
	}{{big.NewInt(1), state.Messenger}}
	state.CRegistry, e = deploy(ctx, cRPC, cDir, "TeleporterRegistry", common.Address{}, entries)
	if e != nil {
		return e
	}
	state.LRegistry, e = deploy(ctx, url, path, "TeleporterRegistry", common.Address{}, entries)
	if e != nil {
		return e
	}
	state.Token, e = deploy(ctx, cRPC, cDir, "CashToken", common.Address{})
	if e != nil {
		return e
	}
	state.Home, e = deploy(ctx, cRPC, cDir, "ERC20TokenHome", common.Address{}, state.CRegistry, admin, big.NewInt(1), state.Token, uint8(18))
	if e != nil {
		return e
	}
	if _, e = evmTx(ctx, url, path, "fund-remote", &rd, nil, units(1), nil); e != nil {
		return e
	}
	settings := struct {
		TeleporterRegistryAddress common.Address
		TeleporterManager         common.Address
		MinTeleporterVersion      *big.Int
		TokenHomeBlockchainID     [32]byte
		TokenHomeAddress          common.Address
		TokenHomeDecimals         uint8
	}{state.LRegistry, admin, big.NewInt(1), cID, state.Home, 18}
	state.Remote, e = deployAs(ctx, url, path, "NativeTokenRemote", devKey(10), settings, "CASH", state.InitialSupply, big.NewInt(0))
	if e != nil {
		return e
	}
	if state.Remote != crypto.CreateAddress(rd, 0) {
		return fmt.Errorf("remote address differs from genesis minter")
	}
	// Verify the genesis precompile grants the remote enabled (not admin) mint authority.
	for address, want := range map[common.Address]uint64{state.Remote: 1, admin: 0} {
		data := append(crypto.Keccak256([]byte("readAllowList(address)"))[:4], common.LeftPadBytes(address.Bytes(), 32)...)
		var result string
		if e = rpc(ctx, url, "eth_call", []any{map[string]any{"to": "0x0200000000000000000000000000000000000001", "data": "0x" + hex.EncodeToString(data)}, "latest"}, &result); e != nil {
			return e
		}
		got, ok := new(big.Int).SetString(strings.TrimPrefix(result, "0x"), 16)
		if !ok || got.Uint64() != want {
			return fmt.Errorf("unexpected native minter authority")
		}
	}
	if e = save(filepath.Join(path, "contracts.json"), state); e != nil {
		return e
	}
	// Both chains are sources and destinations. The relayer persists missed-block progress.
	sources := []any{}
	destinations := []any{}
	for _, network := range []struct{ RPC, Chain, Subnet string }{{cRPC, state.CChain, ids.Empty.String()}, {url, state.LChain, chain.Subnet}} {
		sources = append(sources, map[string]any{"subnet-id": network.Subnet, "blockchain-id": network.Chain, "rpc-endpoint": map[string]string{"base-url": network.RPC}, "ws-endpoint": map[string]string{"base-url": strings.Replace(strings.TrimSuffix(network.RPC, "/rpc"), "http://", "ws://", 1) + "/ws"}, "message-contracts": map[string]any{state.Messenger.Hex(): map[string]any{"message-format": "teleporter", "settings": map[string]string{"reward-address": relay.Hex()}}}})
		destinations = append(destinations, map[string]any{"subnet-id": network.Subnet, "blockchain-id": network.Chain, "rpc-endpoint": map[string]string{"base-url": network.RPC}, "account-private-key": hex.EncodeToString(crypto.FromECDSA(relayKey))})
	}
	return save(filepath.Join(path, "relayer/config.json"), map[string]any{"log-level": "info", "api-port": 9091, "metrics-port": 9092, "allow-private-ips": true, "storage-location": "/data", "process-missed-blocks": true, "p-chain-api": map[string]string{"base-url": uri}, "info-api": map[string]string{"base-url": uri}, "source-blockchains": sources, "destination-blockchains": destinations})
}
func tokenBalance(ctx context.Context, url string, token, owner common.Address) (*big.Int, error) {
	values, e := view(ctx, url, "CashToken", token, "balanceOf", owner)
	if e != nil {
		return nil, e
	}
	return values[0].(*big.Int), nil
}
func bridgeSmoke(ctx context.Context, cRPC, url, path string, state BridgeState, cid ids.ID) error {
	client, e := ethclient.DialContext(ctx, url)
	if e != nil {
		return e
	}
	defer client.Close()
	recipient := crypto.PubkeyToAddress(devKey(8).PublicKey)
	admin := genesis.EWOQKey.EthAddress()
	beforePath := filepath.Join(path, "smoke-before.json")
	var before struct{ Sender, Escrow, Recipient *big.Int }
	b, e := os.ReadFile(beforePath)
	if e == nil {
		if e = json.Unmarshal(b, &before); e != nil {
			return e
		}
	} else if os.IsNotExist(e) {
		before.Sender, e = tokenBalance(ctx, cRPC, state.Token, admin)
		if e != nil {
			return e
		}
		before.Escrow, e = tokenBalance(ctx, cRPC, state.Token, state.Home)
		if e != nil {
			return e
		}
		before.Recipient, e = client.BalanceAt(ctx, recipient, nil)
		if e != nil {
			return e
		}
		if before.Recipient.Sign() != 0 {
			return fmt.Errorf("bridge smoke recipient must begin unfunded")
		}
		if e = save(beforePath, before); e != nil {
			return e
		}
	} else {
		return e
	}
	amount := units(7)
	if e = invoke(ctx, cRPC, filepath.Join(path, "smoke"), "approve", "CashToken", state.Token, nil, state.Home, amount); e != nil {
		return e
	}
	input := struct {
		DestinationBlockchainID            [32]byte
		DestinationTokenTransferrerAddress common.Address
		Recipient                          common.Address
		PrimaryFeeTokenAddress             common.Address
		PrimaryFee                         *big.Int
		SecondaryFee                       *big.Int
		RequiredGasLimit                   *big.Int
		MultiHopFallback                   common.Address
	}{cid, state.Remote, recipient, state.Token, big.NewInt(0), big.NewInt(0), big.NewInt(300000), common.Address{}}
	if e = invoke(ctx, cRPC, filepath.Join(path, "smoke"), "send", "ERC20TokenHome", state.Home, nil, input, amount); e != nil {
		return e
	}
	// Once a spend is prepared it may already have been accepted, even if a
	// crash prevented saving its receipt. evmTxAs reconciles that signed journal.
	_, e = os.Stat(filepath.Join(path, "spend.evm.json"))
	if e != nil && !os.IsNotExist(e) {
		return e
	}
	if os.IsNotExist(e) {
		for {
			balance, e := client.BalanceAt(ctx, recipient, nil)
			if e != nil {
				return e
			}
			if balance.Cmp(amount) == 0 {
				break
			}
			select {
			case <-ctx.Done():
				return fmt.Errorf("bridge delivery: %w", ctx.Err())
			case <-time.After(time.Second):
			}
		}
	}
	sender, e := tokenBalance(ctx, cRPC, state.Token, admin)
	if e != nil {
		return e
	}
	escrow, e := tokenBalance(ctx, cRPC, state.Token, state.Home)
	if e != nil {
		return e
	}
	if new(big.Int).Sub(before.Sender, sender).Cmp(amount) != 0 || new(big.Int).Sub(escrow, before.Escrow).Cmp(amount) != 0 {
		return fmt.Errorf("bridge escrow reconciliation failed")
	}
	collateral, e := view(ctx, url, "NativeTokenRemote", state.Remote, "getIsCollateralized")
	if e != nil {
		return e
	}
	if !collateral[0].(bool) {
		return fmt.Errorf("remote remains uncollateralized")
	}
	receipt, e := evmTxAs(ctx, url, path, "spend", &admin, nil, big.NewInt(1), nil, devKey(8))
	if e != nil {
		return e
	}
	balance, e := client.BalanceAt(ctx, recipient, nil)
	if e != nil {
		return e
	}
	fee := new(big.Int).Mul(new(big.Int).SetUint64(receipt.GasUsed), receipt.EffectiveGasPrice)
	expected := new(big.Int).Sub(new(big.Int).Sub(amount, big.NewInt(1)), fee)
	if fee.Sign() <= 0 || balance.Cmp(expected) != 0 {
		return fmt.Errorf("bridged native gas proof failed")
	}
	return save(filepath.Join(path, "verified.json"), map[string]any{"bridge_operational": true, "amount": amount.String(), "genesis_backing": state.InitialSupply.String(), "native_gas_paid": fee.String(), "recipient": recipient.Hex()})
}
