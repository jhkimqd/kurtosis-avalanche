package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRuntimeIdentityGeneration(t *testing.T) {
	dir := t.TempDir()
	if err := prepare(dir, 27, 2); err != nil {
		t.Fatal(err)
	}
	var network struct {
		Nodes []struct {
			ID string `json:"node_id"`
		}
	}
	b, err := os.ReadFile(filepath.Join(dir, "network.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(b, &network); err != nil {
		t.Fatal(err)
	}
	if len(network.Nodes) != 27 {
		t.Fatal("wrong node count")
	}
	seen := map[string]bool{}
	for _, n := range network.Nodes {
		if seen[n.ID] {
			t.Fatal("duplicate identity")
		}
		seen[n.ID] = true
	}
	var g struct {
		StartTime      uint64
		InitialStakers []json.RawMessage
	}
	b, err = os.ReadFile(filepath.Join(dir, "genesis.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(b, &g); err != nil {
		t.Fatal(err)
	}
	if len(g.InitialStakers) != 2 || time.Since(time.Unix(int64(g.StartTime), 0)) > 2*time.Minute {
		t.Fatal("wrong primary genesis")
	}
	for _, file := range []string{"upgrade.json", "nodes/0/staker.key", "nodes/0/staker.crt", "nodes/26/signer.key"} {
		if info, err := os.Stat(filepath.Join(dir, file)); err != nil || info.Size() == 0 {
			t.Fatalf("missing network file %s: %v", file, err)
		}
	}
	if _, err = os.Stat(filepath.Join(dir, "nodes/27")); !os.IsNotExist(err) {
		t.Fatal("generated keys for an unexpected node")
	}
	if err = prepare(dir, 27, 2); err == nil {
		t.Fatal("overwrote existing identities")
	}
}
