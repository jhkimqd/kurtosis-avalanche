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
	if err = prepare(dir, 27, 2); err == nil {
		t.Fatal("overwrote existing identities")
	}
}

func TestChurnTransitionSmallestFleet(t *testing.T) {
	total := uint64(20 * 50000)
	final := uint64(200000)
	if final*100 > total*20 {
		t.Fatal("admission exceeds churn cap")
	}
	total += final
	for i := 0; i < 20; i++ {
		if 50000*100 > total*20 {
			t.Fatal("removal exceeds churn cap")
		}
		total -= 50000
	}
	if total != final {
		t.Fatal("bootstrap weight remains")
	}
}
