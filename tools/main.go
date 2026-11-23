// Command lab is the transaction and identity adapter of kurtosis-avalanche.
//
// The Kurtosis package (main.star, src/) starts the services; lab does the work
// Starlark cannot do: it generates node identities and the Primary Network
// genesis, signs P-Chain and EVM transactions, and verifies the result. Every
// setup transaction is journaled under /state before it is sent, so a repeated
// command resumes the same transaction and never issues a second one. Only the
// test transfers of `run` have no journal.
//
// Commands, in the order the package runs them:
//
//	prepare          generate genesis, upgrade schedule, and node keys   (main.go)
//	create           create the subnet and its Subnet-EVM blockchain     (lifecycle.go)
//	convert          convert the subnet to an L1                         (lifecycle.go)
//	wait             wait until an EVM RPC serves the expected chain ID  (rpc.go)
//	manager          deploy and initialize the ValidatorManager (PoA)    (manager.go)
//	bridge-deploy    deploy ICM and token-bridge contracts               (bridge.go)
//	bridge-activate  register the L1 bridge side and add collateral      (bridge.go)
//	migrate          PoS: deploy the staking manager, stake a validator  (staking.go)
//	finalize-pos     PoS: remove the bootstrap validators and verify     (finalize.go)
//	bridge-smoke     send tokens across the bridge and spend them        (bridge.go)
//	run              send smoke-test transfers on the L1                 (load.go)
//	verify-rpcs      check that all RPC nodes agree on one block         (load.go)
//	icm-config       prepare a temporary relayer for nightly L1 tests   (interchain.go)
//	icm-smoke        verify application messages between every L1 pair (interchain.go)
package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/ava-labs/avalanchego/config"
	"github.com/ava-labs/avalanchego/genesis"
	"github.com/ava-labs/avalanchego/tests/fixture/tmpnet"
	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
)

// Network ID of the local Primary Network. Every command that signs checks
// that the node reports this ID (see localOnly), so lab never signs for Fuji
// or Mainnet.
const networkID = 88888

func save(path string, value any) error { return atomicJSON(path, value) }

// prepare generates everything the network needs before the first node starts:
//
//	genesis.json   Primary Network genesis (P-, X-, and C-Chain). It funds the
//	               public EWOQ key and stakes the first primaryCount nodes.
//	upgrade.json   Network upgrade schedule: every upgrade is active at genesis.
//	nodes/<i>/     Staking TLS key pair and BLS signer key of node i.
//	network.json   Node IDs and BLS proofs of possession, in node order.
//
// Node configuration itself is rendered by the Kurtosis package (src/node).
func prepare(dir string, count, primaryCount int) error {
	if primaryCount < 1 || count < primaryCount {
		return fmt.Errorf("invalid node counts")
	}
	if _, err := os.Stat(filepath.Join(dir, "genesis.json")); err == nil {
		return fmt.Errorf("refusing to replace existing network files")
	}
	nodes := tmpnet.NewNodesOrPanic(count)
	for _, n := range nodes {
		if err := n.EnsureKeys(); err != nil {
			return err
		}
	}
	g, err := tmpnet.NewTestGenesis(networkID, nodes[:primaryCount], []*secp256k1.PrivateKey{genesis.EWOQKey})
	if err != nil {
		return err
	}
	// Start the network one minute in the past and keep the genesis validators
	// staked for ten years, so a long-lived devnet never loses its validators.
	g.StartTime = uint64(time.Now().Add(-time.Minute).Unix())
	g.InitialStakeDuration = 10 * 365 * 24 * 60 * 60
	for i := range g.Allocations {
		for j := range g.Allocations[i].UnlockSchedule {
			if g.Allocations[i].UnlockSchedule[j].Locktime > 0 {
				g.Allocations[i].UnlockSchedule[j].Locktime = g.StartTime + 7*24*60*60
			}
		}
	}
	if err = save(filepath.Join(dir, "genesis.json"), g); err != nil {
		return err
	}
	if err = save(filepath.Join(dir, "upgrade.json"), tmpnet.UpgradeConfig(0)); err != nil {
		return err
	}
	metadata := []map[string]any{}
	for i, n := range nodes {
		// tmpnet keeps each key base64 encoded under its "-content" flag.
		for file, flag := range map[string]string{
			"staker.key": config.StakingTLSKeyContentKey,
			"staker.crt": config.StakingCertContentKey,
			"signer.key": config.StakingSignerKeyContentKey,
		} {
			content, err := base64.StdEncoding.DecodeString(n.Flags[flag])
			if err != nil {
				return fmt.Errorf("node %d %s: %w", i, file, err)
			}
			path := filepath.Join(dir, "nodes", strconv.Itoa(i), file)
			if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				return err
			}
			if err = os.WriteFile(path, content, 0600); err != nil {
				return err
			}
		}
		pop, err := n.GetProofOfPossession()
		if err != nil {
			return err
		}
		metadata = append(metadata, map[string]any{"node_id": n.NodeID.String(), "pop": pop})
	}
	return save(filepath.Join(dir, "network.json"), map[string]any{"nodes": metadata})
}

// main runs one command. All commands share a ten-minute deadline and one
// lock (see lock.go), because they sign with the same account.
func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	var err error
	unlock, lockErr := writerLock()
	if lockErr != nil {
		fmt.Fprintln(os.Stderr, lockErr)
		os.Exit(1)
	}
	defer unlock()
	if len(os.Args) < 2 {
		err = fmt.Errorf("usage: lab prepare | create | convert | manager | migrate | finalize-pos | bridge-deploy | bridge-activate | bridge-smoke | icm-config | icm-smoke | verify-rpcs | wait | run")
	} else {
		if os.Args[1] != "prepare" && os.Args[1] != "wait" && os.Args[1] != "verify-rpcs" {
			instance := os.Getenv("LAB_INSTANCE")
			if instance == "" || instance == "manual" {
				fmt.Fprintln(os.Stderr, "stateful commands run only in the tools service, where LAB_INSTANCE is set")
				os.Exit(1)
			}
		}
		switch os.Args[1] {
		case "prepare":
			if len(os.Args) != 5 {
				err = fmt.Errorf("prepare requires output directory, node count and primary validator count")
			} else {
				count, e := strconv.Atoi(os.Args[3])
				primaries, e2 := strconv.Atoi(os.Args[4])
				if e != nil || e2 != nil {
					err = fmt.Errorf("invalid node counts")
				} else {
					err = prepare(os.Args[2], count, primaries)
				}
			}
		case "create":
			if len(os.Args) != 10 {
				err = fmt.Errorf("create requires URI, state directory, genesis file, chain ID, genesis overrides, bridge boolean, chain config and subnet config")
			} else {
				var bridge bool
				bridge, err = strconv.ParseBool(os.Args[7])
				if err == nil {
					err = create(ctx, os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6], bridge, os.Args[8], os.Args[9])
				}
			}
		case "convert":
			if len(os.Args) < 9 {
				err = fmt.Errorf("convert requires URI, state directory, manager chain, address, fixture directory, validator weight, node indexes")
			} else {
				err = convert(ctx, os.Args[2:])
			}
		case "verify-rpcs":
			err = verifyRPCs(ctx, os.Args[2:])
		case "wait":
			if len(os.Args) != 4 {
				err = fmt.Errorf("wait requires L1 RPC and expected EVM chain ID")
			} else {
				expected, e := strconv.ParseUint(os.Args[3], 10, 64)
				if e != nil {
					err = e
				} else {
					err = waitRPC(ctx, os.Args[2], expected)
				}
			}
		case "migrate":
			if len(os.Args) != 8 {
				err = fmt.Errorf("migrate requires primary URI, L1 RPC, state directory, aggregator URI, node index and staking mode")
			} else {
				i, e := strconv.Atoi(os.Args[6])
				if e != nil {
					err = e
				} else {
					err = migrate(ctx, os.Args[2], os.Args[3], os.Args[4], os.Args[5], i, os.Args[7])
				}
			}
		case "bridge-deploy", "bridge-activate", "bridge-smoke":
			if len(os.Args) != 5 {
				err = fmt.Errorf("bridge commands require primary URI, L1 RPC and state directory")
			} else {
				err = bridge(ctx, os.Args[1], os.Args[2], os.Args[3], os.Args[4])
			}
		case "icm-config", "icm-smoke":
			if len(os.Args) != 5 {
				err = fmt.Errorf("ICM tests require primary URI, state directory, and deployment manifest JSON")
			} else {
				err = interchain(ctx, os.Args[1], os.Args[2], os.Args[3], os.Args[4])
			}
		case "finalize-pos":
			if len(os.Args) < 8 {
				err = fmt.Errorf("finalize-pos requires URI RPC state aggregator mode indexes...")
			} else {
				err = finalizePoS(ctx, os.Args[2:])
			}
		case "manager":
			if len(os.Args) != 6 {
				err = fmt.Errorf("manager requires primary URI, L1 RPC, state directory, aggregator URI")
			} else {
				err = initializeManager(ctx, os.Args[2], os.Args[3], os.Args[4], os.Args[5])
			}
		case "run":
			if len(os.Args) != 4 {
				err = fmt.Errorf("run requires RPC and count")
			} else {
				n, e := strconv.Atoi(os.Args[3])
				if e != nil {
					err = e
				} else {
					err = runTransfers(ctx, os.Args[2], n)
				}
			}
		default:
			err = fmt.Errorf("unknown command %q", os.Args[1])
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
