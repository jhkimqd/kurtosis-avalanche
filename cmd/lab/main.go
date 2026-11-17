package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
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

func save(path string, value any) error { return atomicJSON(path, value) }
func prepare(dir string) error {
	if _, err := os.Stat(filepath.Join(dir, "genesis.json")); err == nil {
		return fmt.Errorf("refusing to replace existing fixture")
	}
	nodes := tmpnet.NewNodesOrPanic(13)
	for _, n := range nodes {
		if err := n.EnsureKeys(); err != nil {
			return err
		}
	}
	g, err := tmpnet.NewTestGenesis(88888, nodes[:3], []*secp256k1.PrivateKey{genesis.EWOQKey})
	if err != nil {
		return err
	}
	// Stable fixture epoch and long-lived local validator windows. This is never a public-network genesis.
	g.StartTime = 1780000000
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
	upgrades, err := tmpnet.UpgradeFlags(tmpnet.UpgradeConfig(0))
	if err != nil {
		return err
	}
	metadata := []map[string]any{}
	for i, n := range nodes {
		flags := tmpnet.DefaultTmpnetFlags()
		for k, v := range upgrades {
			flags[k] = v
		}
		for k, v := range n.Flags {
			flags[k] = v
		}
		flags[config.NetworkNameKey] = "88888"
		flags[config.DataDirKey] = "/data"
		flags[config.HTTPHostKey] = "0.0.0.0"
		flags[config.HTTPPortKey] = "9650"
		flags[config.StakingPortKey] = "9651"
		flags[config.PluginDirKey] = "/opt/avalanche/plugins"
		flags[config.ChainConfigDirKey] = "/config/chains"
		flags[config.ProposerVMUseCurrentHeightKey] = "true"
		pop, err := n.GetProofOfPossession()
		if err != nil {
			return err
		}
		metadata = append(metadata, map[string]any{"node_id": n.NodeID.String(), "pop": pop})
		if err = save(filepath.Join(dir, fmt.Sprintf("node-%d.json", i)), flags); err != nil {
			return err
		}
	}
	b, _ := json.Marshal(g)
	if err = save(filepath.Join(dir, "network.json"), map[string]any{"genesis": base64.StdEncoding.EncodeToString(b), "nodes": metadata}); err != nil {
		return err
	}
	return nil
}
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
		err = fmt.Errorf("usage: lab prepare DIR | create URI DIR GENESIS | convert URI DIR MANAGER_CHAIN MANAGER NODE_INDEX... | inspect URI | run RPC COUNT | collect URI DIR")
	} else {
		if os.Args[1] != "prepare" && os.Args[1] != "inspect" && os.Args[1] != "collect" && os.Args[1] != "compare" && os.Args[1] != "wait" {
			instance := os.Getenv("LAB_INSTANCE")
			if instance == "" || instance == "manual" {
				fmt.Fprintln(os.Stderr, "stateful commands require the enclave lab helper with LAB_INSTANCE")
				os.Exit(1)
			}
		}
		switch os.Args[1] {
		case "prepare":
			if len(os.Args) != 3 {
				err = fmt.Errorf("prepare requires output directory")
			} else {
				err = prepare(os.Args[2])
			}
		case "create":
			if len(os.Args) != 5 {
				err = fmt.Errorf("create requires URI, state directory and genesis file")
			} else {
				err = create(ctx, os.Args[2], os.Args[3], os.Args[4])
			}
		case "convert":
			if len(os.Args) < 8 {
				err = fmt.Errorf("convert requires URI, state directory, manager chain, address, fixture directory, node indexes")
			} else {
				err = convert(ctx, os.Args[2:])
			}
		case "load":
			if len(os.Args) != 6 {
				err = fmt.Errorf("load requires RPC, rate, seconds, output directory")
			} else {
				rate, e := strconv.Atoi(os.Args[3])
				duration, e2 := strconv.Atoi(os.Args[4])
				if e != nil || e2 != nil {
					err = fmt.Errorf("rate and duration must be integers")
				} else {
					err = benchmark(ctx, os.Args[2], rate, duration, os.Args[5])
				}
			}
		case "compare":
			err = compare(ctx, os.Args[2:])
		case "wait":
			if len(os.Args) != 3 {
				err = fmt.Errorf("wait requires L1 RPC")
			} else {
				err = waitRPC(ctx, os.Args[2])
			}
		case "migrate":
			if len(os.Args) != 8 {
				err = fmt.Errorf("migrate requires primary URI, L1 RPC, state directory, aggregator URI, fixture index")
			} else {
				i, e := strconv.Atoi(os.Args[6])
				if e != nil {
					err = e
				} else {
					err = migrate(ctx, os.Args[2], os.Args[3], os.Args[4], os.Args[5], i, os.Args[7])
				}
			}
		case "manager":
			if len(os.Args) != 6 {
				err = fmt.Errorf("manager requires primary URI, L1 RPC, state directory, aggregator URI")
			} else {
				err = initializeManager(ctx, os.Args[2], os.Args[3], os.Args[4], os.Args[5])
			}
		case "inspect":
			if len(os.Args) != 3 {
				err = fmt.Errorf("inspect requires URI")
			} else {
				err = inspect(ctx, os.Args[2], os.Stdout)
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
		case "collect":
			if len(os.Args) != 4 {
				err = fmt.Errorf("collect requires URI and output directory")
			} else {
				err = collect(ctx, os.Args[2], os.Args[3])
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
