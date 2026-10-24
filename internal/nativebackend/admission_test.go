package nativebackend

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestInitializationPublicationCannotReplaceExistingOwner(t *testing.T) {
	path := filepath.Join(t.TempDir(), "owner.json")
	original := []byte(`{"epoch":"original"}`)
	if err := publishExclusive(path, original); err != nil {
		t.Fatal(err)
	}
	if err := publishExclusive(path, []byte(`{"epoch":"replacement"}`)); err == nil {
		t.Fatal("replaced existing durable owner")
	}
	data, err := os.ReadFile(path)
	if err != nil || !reflect.DeepEqual(data, original) {
		t.Fatal("owner bytes changed", err)
	}
}
func TestInitializationJournalIsPrivateCompleteAndRejectsAliases(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "journal.json")
	journal := admissionJournal{Schema: 1, Owner: hostcapacity.Config{Epoch: "original", Mode: "closed"}}
	data, _ := json.Marshal(journal)
	if err := publishExclusive(path, data); err != nil {
		t.Fatal(err)
	}
	got, err := readAdmissionJournal(path, uint32(os.Geteuid()))
	if err != nil || !reflect.DeepEqual(got, journal) {
		t.Fatal(err)
	}
	alias := filepath.Join(root, "alias")
	if err = os.Symlink(path, alias); err != nil {
		t.Fatal(err)
	}
	if _, err = readAdmissionJournal(alias, uint32(os.Geteuid())); err == nil {
		t.Fatal("symlink accepted")
	}
	if err = os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err = readAdmissionJournal(path, uint32(os.Geteuid())); err == nil {
		t.Fatal("public journal accepted")
	}
	if err = os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, append(data, []byte(` {"extra":true}`)...), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = readAdmissionJournal(path, uint32(os.Geteuid())); err == nil {
		t.Fatal("ambiguous journal accepted")
	}
}
func TestRecoveryPinsAllOriginalOwnershipIncludingActivatedCrashWindow(t *testing.T) {
	planned := hostcapacity.Config{Epoch: "original", Mode: "closed", LedgerPath: "/original/ledger", ReceiptRoot: "/original/receipts", Policy: sharedcapacity.Policy{Pools: map[string]sharedcapacity.Pool{"build": {Maximum: 2}}}}
	current := planned
	current.Mode = "active"
	if err := validateRecoveryOwner(&planned, &current); err != nil {
		t.Fatal("activation-before-unclosure crash cannot recover", err)
	}
	for _, mutate := range []func(*hostcapacity.Config){
		func(c *hostcapacity.Config) { c.Epoch = "replacement" },
		func(c *hostcapacity.Config) { c.LedgerPath = "/other/ledger" },
		func(c *hostcapacity.Config) { c.ReceiptRoot = "/other/receipts" },
		func(c *hostcapacity.Config) {
			c.Consumers = map[string]hostcapacity.Consumer{"qa": {Pools: []string{"qa"}}}
		},
	} {
		changed := current
		mutate(&changed)
		if err := validateRecoveryOwner(&planned, &changed); err == nil {
			t.Fatal("recovery replaced original ownership")
		}
	}
}

type recoveryRunner struct {
	call func(string, []string) (string, error)
}

func (r recoveryRunner) Run(_ context.Context, action string, args []string, _ string) (string, error) {
	return r.call(action, args)
}
func TestRecoveryRetainsClosureOnFailureAndOriginalEpochThroughRetry(t *testing.T) {
	root := t.TempDir()
	closure := filepath.Join(root, "shared-capacity.closed")
	owner := hostcapacity.Config{Epoch: "0123456789abcdef0123456789abcdef", Mode: "closed", Policy: sharedcapacity.Policy{Pools: map[string]sharedcapacity.Pool{"build": {Maximum: 2}}}}
	identity, err := hostcapacity.StandaloneInitializationIdentity(&owner)
	if err != nil {
		t.Fatal(err)
	}
	ledger := filepath.Join(root, "ledger")
	original := []byte("existing grants and fences")
	if err := os.WriteFile(ledger, original, 0600); err != nil {
		t.Fatal(err)
	}
	attempts := 0
	runner := recoveryRunner{call: func(action string, args []string) (string, error) {
		attempts++
		if action != "native-recover-initialize" || !reflect.DeepEqual(args, []string{owner.Epoch, identity}) {
			t.Fatal("recovery changed ownership identity", action, args)
		}
		if _, err := os.Stat(closure); err != nil {
			t.Fatal("effects ran without durable start closure")
		}
		if attempts == 1 {
			return "partial initialization", errors.New("injected interrupted initialization")
		}
		return "replayed", nil
	}}
	service := New(runner, t.TempDir(), root)
	defer service.Shutdown()
	if _, err := service.finishAdmission(t.Context(), runner, root, owner); err == nil {
		t.Fatal("interrupted recovery passed")
	}
	if _, err := os.Stat(closure); err != nil {
		t.Fatal("interrupted recovery reopened starts")
	}
	if _, err := service.finishAdmission(t.Context(), runner, root, owner); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(closure); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("completed recovery stayed closed")
	}
	current, err := os.ReadFile(ledger)
	if err != nil || !reflect.DeepEqual(current, original) {
		t.Fatal("retry replaced existing grants/fences")
	}
}
