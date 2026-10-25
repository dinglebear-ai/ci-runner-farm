package hostcapacity

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestRegistrationPolicyCASNeverChangesSharedDocument(t *testing.T) {
	root := testRoot(t)
	path := filepath.Join(root, "host-capacity.json")
	config := testConfig(root)
	writeConfig(t, path, config)
	raw, _ := os.ReadFile(path)
	sum := sha256.Sum256(raw)
	lease, err := acquire(t.Context(), path, true, config.Host, uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	calls := 0
	if err = lease.WithRegistrationPolicyCAS(hex.EncodeToString(sum[:]), func() error { calls++; return nil }, func() error { calls++; return nil }); err != nil || calls != 2 {
		t.Fatal(calls, err)
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(raw) {
		t.Fatal("Farm routing update modified shared JSON")
	}
	if err = lease.WithRegistrationPolicyCAS("stale", func() error { return nil }, func() error { t.Fatal("stale CAS published"); return nil }); err == nil {
		t.Fatal("stale policy review accepted")
	}
}
func TestRegistrationPolicyCASRejectsUnprovedIdleAndSharedLease(t *testing.T) {
	for _, exclusive := range []bool{true, false} {
		root := testRoot(t)
		path := filepath.Join(root, "host-capacity.json")
		config := testConfig(root)
		writeConfig(t, path, config)
		raw, _ := os.ReadFile(path)
		sum := sha256.Sum256(raw)
		lease, err := acquire(t.Context(), path, exclusive, config.Host, uint32(os.Geteuid()))
		if err != nil {
			t.Fatal(err)
		}
		if err = lease.WithRegistrationPolicyCAS(hex.EncodeToString(sum[:]), func() error { return errors.New("active owner") }, func() error { t.Fatal("unproved ownership published"); return nil }); err == nil {
			t.Fatal("unproved ownership accepted")
		}
		lease.Close()
	}
}
