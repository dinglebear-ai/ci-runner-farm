package capacitycmd

import (
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"os"
	"path/filepath"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestStandaloneInitializationIsExplicitAndCannotReplaceSharedOwnership(t *testing.T) {
	if !validArguments([]string{"initialize"}) || validArguments([]string{"initialize", "extra"}) {
		t.Fatal("standalone initialization argument contract differs")
	}
	for _, config := range []*hostcapacity.Config{
		{Mode: "active"},
		{Mode: "closed", Consumers: map[string]hostcapacity.Consumer{"qa": {Pools: []string{"qa"}}}},
		{Mode: "closed", Policy: sharedcapacity.Policy{Pools: map[string]sharedcapacity.Pool{"build": {}, "qa": {}}}},
	} {
		// No controller: a shared or open host must fail before inventory or
		// ledger access, independently of any optional consumer installation.
		if err := initializeStandalone(t.Context(), config, nil); err == nil {
			t.Fatal("shared or active ownership reached standalone initialization")
		}
	}
}

func TestStandaloneRecoveryRequiresOriginalEpochAndNoSharedConsumers(t *testing.T) {
	for _, config := range []*hostcapacity.Config{
		{Mode: "closed", Epoch: "original"},
		{Mode: "active", Epoch: "other"},
		{Mode: "active", Epoch: "original", Consumers: map[string]hostcapacity.Consumer{"qa": {Pools: []string{"qa"}}}},
	} {
		if err := recoverStandalone(t.Context(), config, nil, "original", "different"); err == nil {
			t.Fatal("unproved owner reached recovery")
		}
	}
	if !validArguments([]string{"recover-initialize", "0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}) || validArguments([]string{"recover-initialize"}) || validArguments([]string{"recover-initialize", "short"}) {
		t.Fatal("recovery arguments differ")
	}
}

func TestActivatedRecoveryNeverCreatesMissingLedger(t *testing.T) {
	root := t.TempDir()
	config := &hostcapacity.Config{Mode: "active", Epoch: "0123456789abcdef0123456789abcdef", LedgerPath: filepath.Join(root, "missing-ledger"), ReceiptRoot: filepath.Join(root, "receipts"), Policy: sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 32768, VCPUs: 8}, AgingSeconds: 60, Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 8192, VCPUs: 2}, Minimum: 1, Maximum: 4}}}}
	identity, err := hostcapacity.StandaloneInitializationIdentity(config)
	if err != nil {
		t.Fatal(err)
	}
	controller := &farmcapacity.Controller{Broker: sharedcapacity.Broker{Path: config.LedgerPath}, Policy: config.Policy, ReceiptRoot: config.ReceiptRoot}
	if err := recoverStandalone(t.Context(), config, controller, config.Epoch, identity); err == nil {
		t.Fatal("activated owner recreated missing ledger")
	}
	if _, err := os.Stat(config.LedgerPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("recovery created replacement ledger")
	}
	config.Mode = "closed"
	if err := os.Mkdir(config.ReceiptRoot, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config.ReceiptRoot, "existing-owner"), []byte("retained original fence"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := recoverStandalone(t.Context(), config, controller, config.Epoch, identity); err == nil {
		t.Fatal("retained fences were reset without ledger")
	}
	if _, err := os.Stat(config.LedgerPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("retained fence recovery created replacement ledger")
	}
}
