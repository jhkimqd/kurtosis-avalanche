package main

// Nightly ICM tests use a temporary relayer that connects the L1s directly.
// The normal bridge relayers connect each L1 to the C-Chain instead.
import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/ids"
	ethereum "github.com/ava-labs/libevm"
	"github.com/ava-labs/libevm/accounts/abi"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/core/types"
	"github.com/ava-labs/libevm/crypto"
	"github.com/ava-labs/libevm/ethclient"
)

type icmNetwork struct {
	Name         string   `json:"name"`
	SubnetID     string   `json:"subnet_id"`
	BlockchainID string   `json:"blockchain_id"`
	ChainID      uint64   `json:"evm_chain_id"`
	RPCURLs      []string `json:"rpc_urls"`
	Bridge       struct {
		Messenger common.Address `json:"messenger"`
	} `json:"bridge"`
}

type icmManifest struct {
	Primary struct {
		NetworkID uint32 `json:"network_id"`
	} `json:"primary_network"`
	L1s []icmNetwork `json:"l1s"`
}

// parseICMManifest rejects incomplete or duplicate routes before funding accounts.
func parseICMManifest(input string) (icmManifest, error) {
	var manifest icmManifest
	if err := json.Unmarshal([]byte(input), &manifest); err != nil {
		return manifest, err
	}
	if manifest.Primary.NetworkID != networkID || len(manifest.L1s) < 2 {
		return manifest, fmt.Errorf("ICM tests require network %d and at least two L1s", networkID)
	}
	chains := map[string]bool{}
	evmIDs := map[uint64]bool{}
	for _, network := range manifest.L1s {
		if chains[network.BlockchainID] || evmIDs[network.ChainID] || network.ChainID == 0 || len(network.RPCURLs) == 0 || network.Bridge.Messenger == (common.Address{}) {
			return manifest, fmt.Errorf("incomplete or duplicate ICM route for %s", network.Name)
		}
		if _, err := ids.FromString(network.BlockchainID); err != nil {
			return manifest, fmt.Errorf("blockchain ID of %s: %w", network.Name, err)
		}
		if _, err := ids.FromString(network.SubnetID); err != nil {
			return manifest, fmt.Errorf("subnet ID of %s: %w", network.Name, err)
		}
		for _, url := range network.RPCURLs {
			_, chain, ok := strings.Cut(url, "/ext/bc/")
			if !ok || chain != network.BlockchainID+"/rpc" {
				return manifest, fmt.Errorf("RPC URL does not identify %s", network.Name)
			}
		}
		chains[network.BlockchainID] = true
		evmIDs[network.ChainID] = true
	}
	return manifest, nil
}

func interchain(ctx context.Context, stage, uri, dir, input string) error {
	identity, err := deploymentIdentity(ctx, uri)
	if err != nil {
		return err
	}
	manifest, err := parseICMManifest(input)
	if err != nil {
		return err
	}
	// Every RPC must belong to this deployment and serve its recorded EVM ID.
	for _, network := range manifest.L1s {
		for _, url := range network.RPCURLs {
			base, _, _ := strings.Cut(url, "/ext/bc/")
			got, err := deploymentIdentity(ctx, base)
			if err != nil || got != identity {
				return fmt.Errorf("%s is not part of this deployment: %v", url, err)
			}
			client, err := ethclient.DialContext(ctx, url)
			if err != nil {
				return err
			}
			chainID, err := client.ChainID(ctx)
			client.Close()
			if err != nil || chainID == nil || !chainID.IsUint64() || chainID.Uint64() != network.ChainID {
				return fmt.Errorf("EVM chain ID does not match %s: %v", network.Name, err)
			}
		}
	}
	if stage == "icm-config" {
		return prepareICMRelayer(ctx, uri, dir, manifest)
	}
	return smokeICM(ctx, dir, identity, manifest)
}

func prepareICMRelayer(ctx context.Context, uri, dir string, manifest icmManifest) error {
	key := devKey(11)
	relayer := crypto.PubkeyToAddress(key.PublicKey)
	sources, destinations := []any{}, []any{}
	for index, network := range manifest.L1s {
		url := network.RPCURLs[0]
		if _, err := evmTx(ctx, url, filepath.Join(dir, strconv.Itoa(index)), "fund-relayer", &relayer, nil, units(1), nil); err != nil {
			return err
		}
		sources = append(sources, map[string]any{
			"subnet-id": network.SubnetID, "blockchain-id": network.BlockchainID,
			"rpc-endpoint": map[string]string{"base-url": url},
			"ws-endpoint":  map[string]string{"base-url": strings.Replace(strings.TrimSuffix(url, "/rpc"), "http://", "ws://", 1) + "/ws"},
			"message-contracts": map[string]any{network.Bridge.Messenger.Hex(): map[string]any{
				"message-format": "teleporter", "settings": map[string]string{"reward-address": relayer.Hex()},
			}},
		})
		destinations = append(destinations, map[string]any{
			"subnet-id": network.SubnetID, "blockchain-id": network.BlockchainID,
			"rpc-endpoint": map[string]string{"base-url": url}, "account-private-key": hex.EncodeToString(crypto.FromECDSA(key)),
		})
	}
	return save(filepath.Join(dir, "relayer/config.json"), map[string]any{
		"log-level": "info", "api-port": 9091, "metrics-port": 9092, "allow-private-ips": true,
		"storage-location": "/data", "process-missed-blocks": true,
		"p-chain-api": map[string]string{"base-url": uri}, "info-api": map[string]string{"base-url": uri},
		"source-blockchains": sources, "destination-blockchains": destinations,
	})
}

// envelopeHash matches MessageReceiver's abi.encode(source, sender, message).
func envelopeHash(source [32]byte, sender common.Address, message []byte) (common.Hash, error) {
	idType, _ := abi.NewType("bytes32", "", nil)
	addressType, _ := abi.NewType("address", "", nil)
	bytesType, _ := abi.NewType("bytes", "", nil)
	encoded, err := (abi.Arguments{{Type: idType}, {Type: addressType}, {Type: bytesType}}).Pack(source, sender, message)
	return crypto.Keccak256Hash(encoded), err
}

// sentMessageID accepts exactly one matching messenger event in the source receipt.
func sentMessageID(receipt *types.Receipt, messenger common.Address, event, destination common.Hash) (common.Hash, error) {
	var messageID common.Hash
	found := false
	for _, log := range receipt.Logs {
		if log.Address != messenger || len(log.Topics) != 3 || log.Topics[0] != event {
			continue
		}
		if found || log.Topics[2] != destination {
			return common.Hash{}, fmt.Errorf("ambiguous or incorrectly routed ICM send")
		}
		messageID, found = log.Topics[1], true
	}
	if !found || messageID == (common.Hash{}) {
		return common.Hash{}, fmt.Errorf("no ICM message ID in source receipt")
	}
	return messageID, nil
}

type icmDelivery struct {
	Source, Destination                string
	MessageID, SourceTx, DestinationTx common.Hash
	EnvelopeHash, DestinationBlock     common.Hash
	DestinationHeight                  *big.Int
}

func smokeICM(ctx context.Context, dir, identity string, manifest icmManifest) error {
	receivers := make([]common.Address, len(manifest.L1s))
	for index, network := range manifest.L1s {
		address, err := deploy(ctx, network.RPCURLs[0], filepath.Join(dir, strconv.Itoa(index)), "MessageReceiver", common.Address{}, network.Bridge.Messenger)
		if err != nil {
			return err
		}
		receivers[index] = address
	}
	_, messengerABI, err := artifact("TeleporterMessenger")
	if err != nil {
		return err
	}
	deliveries := []icmDelivery{}
	for sourceIndex, source := range manifest.L1s {
		sourceID, _ := ids.FromString(source.BlockchainID)
		for destinationIndex, destination := range manifest.L1s {
			if sourceIndex == destinationIndex {
				continue
			}
			destinationID, _ := ids.FromString(destination.BlockchainID)
			payload := []byte(identity + ":" + source.BlockchainID + ":" + destination.BlockchainID)
			input := struct {
				DestinationBlockchainID [32]byte
				DestinationAddress      common.Address
				FeeInfo                 struct {
					FeeTokenAddress common.Address
					Amount          *big.Int
				}
				RequiredGasLimit        *big.Int
				AllowedRelayerAddresses []common.Address
				Message                 []byte
			}{DestinationBlockchainID: destinationID, DestinationAddress: receivers[destinationIndex],
				RequiredGasLimit: big.NewInt(200000), AllowedRelayerAddresses: []common.Address{crypto.PubkeyToAddress(devKey(11).PublicKey)}, Message: payload}
			input.FeeInfo.Amount = big.NewInt(0)
			data, err := messengerABI.Pack("sendCrossChainMessage", input)
			if err != nil {
				return err
			}
			pairDir := filepath.Join(dir, strconv.Itoa(sourceIndex), "to-"+strconv.Itoa(destinationIndex))
			receipt, err := evmTx(ctx, source.RPCURLs[0], pairDir, "send-message", &source.Bridge.Messenger, data, big.NewInt(0), nil)
			if err != nil {
				return err
			}
			if err := canonicalICMReceipt(ctx, source.RPCURLs[0], receipt); err != nil {
				return fmt.Errorf("source message transaction: %w", err)
			}
			messageID, err := sentMessageID(receipt, source.Bridge.Messenger, messengerABI.Events["SendCrossChainMessage"].ID, common.Hash(destinationID))
			if err != nil {
				return err
			}
			envelope, err := envelopeHash(sourceID, genesis.EWOQKey.EthAddress(), payload)
			if err != nil {
				return err
			}
			fmt.Printf("ICM submitted %s -> %s: message %s, transaction %s\n", source.Name, destination.Name, messageID, receipt.TxHash)
			var settled *types.Receipt
			for _, url := range destination.RPCURLs {
				got, err := waitICMDelivery(ctx, url, receivers[destinationIndex], destination.Bridge.Messenger, messageID, envelope)
				if err != nil {
					return fmt.Errorf("%s -> %s: %w", source.Name, destination.Name, err)
				}
				if settled == nil {
					settled = got
				} else if err := sameICMSettlement(settled, got); err != nil {
					return err
				}
			}
			deliveries = append(deliveries, icmDelivery{
				Source: source.Name, Destination: destination.Name, MessageID: messageID,
				SourceTx: receipt.TxHash, DestinationTx: settled.TxHash, EnvelopeHash: envelope,
				DestinationBlock: settled.BlockHash, DestinationHeight: settled.BlockNumber,
			})
			fmt.Printf("ICM delivered %s -> %s: %s\n", source.Name, destination.Name, messageID)
		}
	}
	return save(filepath.Join(dir, "results.json"), map[string]any{"l1_count": len(manifest.L1s), "messages_delivered": len(deliveries), "messages": deliveries})
}

func waitICMDelivery(ctx context.Context, url string, receiver, messenger common.Address, messageID, envelope common.Hash) (*types.Receipt, error) {
	client, err := ethclient.DialContext(ctx, url)
	if err != nil {
		return nil, err
	}
	defer client.Close()
	query := ethereum.FilterQuery{FromBlock: big.NewInt(0), Addresses: []common.Address{receiver}, Topics: [][]common.Hash{{crypto.Keccak256Hash([]byte("MessageReceived(bytes32)"))}, {envelope}}}
	for {
		logs, err := client.FilterLogs(ctx, query)
		if err != nil {
			return nil, err
		}
		if len(logs) > 1 {
			return nil, fmt.Errorf("application received the same envelope more than once")
		}
		if len(logs) == 1 {
			receipt, err := client.TransactionReceipt(ctx, logs[0].TxHash)
			if err != nil {
				return nil, err
			}
			if err := canonicalICMReceipt(ctx, url, receipt); err != nil {
				return nil, err
			}
			if logs[0].Removed || logs[0].BlockHash != receipt.BlockHash || logs[0].TxHash != receipt.TxHash || logs[0].BlockNumber != receipt.BlockNumber.Uint64() {
				return nil, fmt.Errorf("destination event is not in the settled transaction")
			}
			for _, check := range []struct {
				Contract string
				Address  common.Address
				Method   string
				Key      common.Hash
			}{
				{"MessageReceiver", receiver, "receivedMessages", envelope},
				{"TeleporterMessenger", messenger, "messageReceived", messageID},
			} {
				values, err := view(ctx, url, check.Contract, check.Address, check.Method, [32]byte(check.Key))
				if err != nil {
					return nil, err
				}
				if len(values) != 1 || values[0] != true {
					return nil, fmt.Errorf("%s did not record delivery", check.Contract)
				}
			}
			return receipt, nil
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("application message not delivered: %w", ctx.Err())
		case <-time.After(time.Second):
		}
	}
}

// Use the node's block hash directly. Avalanche headers include fields that a
// generic Ethereum header decoder does not retain when recomputing Header.Hash.
func canonicalICMReceipt(ctx context.Context, url string, receipt *types.Receipt) error {
	if receipt == nil || receipt.Status != types.ReceiptStatusSuccessful || receipt.BlockNumber == nil || receipt.BlockHash == (common.Hash{}) {
		return fmt.Errorf("message transaction has no successful settled receipt")
	}
	var block struct {
		Hash common.Hash `json:"hash"`
	}
	if err := rpc(ctx, url, "eth_getBlockByNumber", []any{"0x" + receipt.BlockNumber.Text(16), false}, &block); err != nil {
		return err
	}
	if block.Hash != receipt.BlockHash {
		return fmt.Errorf("message transaction block differs from the canonical block")
	}
	return nil
}

func sameICMSettlement(first, other *types.Receipt) error {
	if first == nil || other == nil || first.BlockNumber == nil || other.BlockNumber == nil || first.TxHash != other.TxHash || first.BlockHash != other.BlockHash || first.BlockNumber.Cmp(other.BlockNumber) != 0 {
		return fmt.Errorf("destination RPC nodes disagree on the settled message transaction")
	}
	return nil
}
