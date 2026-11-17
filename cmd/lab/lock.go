package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// All writers use the same local fixture account. Serialize across state directories.
// Host callers and the helper container are separate domains: use one helper per enclave.
func writerLock() (func(), error) {
	f, e := os.OpenFile(filepath.Join(os.TempDir(), "avalanche-lab-writer.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	if e = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		f.Close()
		return nil, fmt.Errorf("another lab writer is active: %w", e)
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}
