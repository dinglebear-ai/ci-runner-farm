package nativebackend

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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
		if err := os.Remove(closure); err != nil {
			t.Fatal(err)
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

func TestRecoveryRefusesForeignClosureBeforeController(t *testing.T) {
	root := t.TempDir()
	closure := filepath.Join(root, "shared-capacity.closed")
	foreign := []byte("closed for ownership handoff\n")
	if err := os.WriteFile(closure, foreign, 0600); err != nil {
		t.Fatal(err)
	}
	runner := recoveryRunner{call: func(string, []string) (string, error) { t.Fatal("foreign closure reached controller"); return "", nil }}
	service := New(runner, t.TempDir(), root)
	defer service.Shutdown()
	owner := hostcapacity.Config{Epoch: strings.Repeat("a", 32), Mode: "closed", Policy: sharedcapacity.Policy{Pools: map[string]sharedcapacity.Pool{"build": {Maximum: 2}}}}
	if _, err := service.finishAdmission(t.Context(), runner, root, owner); err == nil {
		t.Fatal("foreign closure accepted")
	}
	got, _ := os.ReadFile(closure)
	if string(got) != string(foreign) {
		t.Fatal("foreign fence replaced")
	}
}
func TestDaemonCompletedRecoveryRequiresReadOnlyLedgerVerification(t *testing.T) {
	root := t.TempDir()
	owner := hostcapacity.Config{Epoch: strings.Repeat("a", 32), Mode: "closed", Policy: sharedcapacity.Policy{Pools: map[string]sharedcapacity.Pool{"build": {Maximum: 2}}}}
	current := owner
	current.Mode = "active"
	calls := 0
	runner := recoveryRunner{call: func(action string, args []string) (string, error) {
		calls++
		if action != "native-verify-initialize" || len(args) != 2 || args[0] != owner.Epoch {
			t.Fatal("completed retry must only diagnose", action, args)
		}
		return "", errors.New("completed initialization ledger unavailable")
	}}
	service := New(runner, t.TempDir(), root)
	defer service.Shutdown()
	if _, err := service.resumeAdmission(t.Context(), runner, root, owner, &current); err == nil {
		t.Fatal("missing ledger reported successful recovery")
	}
	if calls != 1 {
		t.Fatal("did not verify completed ledger")
	}
	if _, err := os.Stat(filepath.Join(root, "shared-capacity.closed")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("read-only verification created a closure")
	}
}
func TestActualEmbeddedRecoveryForwardsEpochAndIdentity(t *testing.T) {
	root := t.TempDir()
	argsPath := filepath.Join(root, "argv")
	helper := filepath.Join(root, "capacity")
	// TempDir paths are quoted for the shell, including a possible apostrophe.
	quoted := "'" + strings.ReplaceAll(argsPath, "'", "'\"'\"'") + "'"
	if err := os.WriteFile(helper, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > "+quoted+"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	e := &Engine{Root: filepath.Join(root, "engine"), Config: t.TempDir(), Runtime: t.TempDir(), CapacityRoot: t.TempDir(), Executable: helper, BoundCache: "/mnt/cache/github-runner"}
	if err := e.Extract(); err != nil {
		t.Fatal(err)
	}
	epoch, identity := strings.Repeat("a", 32), strings.Repeat("b", 64)
	if out, err := e.Run(t.Context(), "native-recover-initialize", []string{epoch, identity}, ""); err != nil {
		t.Fatal(out, err)
	}
	got, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "recover-initialize\n"+epoch+"\n"+identity+"\n" {
		t.Fatalf("actual shell bridge dropped arguments: %q", got)
	}
}
