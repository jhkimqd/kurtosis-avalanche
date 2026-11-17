package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ava-labs/libevm/common"
)

func TestLocalOnlyRejectsPublicNetwork(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"networkID":"1"}}`))
	}))
	defer server.Close()
	if err := localOnly(context.Background(), server.URL); err == nil {
		t.Fatal("mainnet accepted")
	}
}
func TestRPCPropagatesErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"denied"}}`))
	}))
	defer server.Close()
	var v any
	if err := rpc(context.Background(), server.URL, "example", nil, &v); err == nil || !strings.Contains(err.Error(), "denied") {
		t.Fatalf("lost RPC error: %v", err)
	}
}
func TestAtomicJournalAndPrivateMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	if err := atomicJSON(path, map[string]int{"sequence": 1}); err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(path, map[string]int{"sequence": 2}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]int
	if err = json.Unmarshal(b, &result); err != nil || result["sequence"] != 2 {
		t.Fatalf("invalid journal: %s", b)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("journal permissions")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatal("temporary journals leaked")
	}
}
func TestWriterLockRejectsConcurrentWriter(t *testing.T) {
	unlock, err := writerLock()
	if err != nil {
		t.Fatal(err)
	}
	if release, err := writerLock(); err == nil {
		release()
		unlock()
		t.Fatal("concurrent writer accepted")
	}
	unlock()
	release, err := writerLock()
	if err != nil {
		t.Fatal(err)
	}
	release()
}
func TestPredicateRoundTripAndDelimiter(t *testing.T) {
	for _, length := range []int{0, 1, 31, 32, 33, 64, 1000} {
		input := make([]byte, length)
		for i := range input {
			input[i] = byte(i)
		}
		result := predicate(input)
		if len(result) != 1 || result[0].Address != common.HexToAddress("0x0200000000000000000000000000000000000005") {
			t.Fatal("wrong predicate address")
		}
		flat := []byte{}
		for _, key := range result[0].StorageKeys {
			flat = append(flat, key[:]...)
		}
		if len(flat)%32 != 0 || flat[length] != 255 || string(flat[:length]) != string(input) {
			t.Fatalf("predicate corruption at length %d", length)
		}
	}
}
func TestLoadValidationDoesNotContactNetwork(t *testing.T) {
	if err := benchmark(context.Background(), "http://invalid", 0, 10, t.TempDir()); err == nil {
		t.Fatal("zero rate accepted")
	}
	if err := benchmark(context.Background(), "http://invalid", 5000, 120, t.TempDir()); err == nil {
		t.Fatal("unbounded workload accepted")
	}
}
