package localchecks

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type chargedFixture struct {
	fixtureOwner
	grant sharedcapacity.Grant
}

func (w *chargedFixture) GrantIdentity(context.Context, Reservation) (string, string, error) {
	if !w.active {
		return "", "", errors.New("sandbox not held")
	}
	return w.grant.ID, w.grant.Fence, nil
}
func TestFarmOwnerChecksRealExistingGrantAndFenceBeforeExecution(t *testing.T) {
	root, bundle, s, r := executionFixture(t, `printf 'charged-fixture-passed\n'`)
	policy := sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 32768, VCPUs: 8}, AgingSeconds: 60, Pools: map[string]sharedcapacity.Pool{"local-checks": {Cost: sharedcapacity.Resources{MemoryMiB: s.MemoryMiB, VCPUs: s.CPUs}, Maximum: 1}}}
	broker := sharedcapacity.Broker{Path: filepath.Join(t.TempDir(), "ledger.bolt")}
	if err := broker.Initialize(&policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	decision, err := broker.Admit(&policy, sharedcapacity.Request{ID: s.RequestID, Pool: "local-checks"})
	if err != nil || decision.Grant == nil {
		t.Fatal(err)
	}
	worker := &chargedFixture{grant: *decision.Grant}
	owner := FarmExecutionOwner{Binding: hostcapacity.Binding{ConfigPath: "/configured/host-capacity.json", Epoch: "0123456789abcdef0123456789abcdef", Consumer: "core-local-checks"}, Pool: "local-checks", Worker: worker}
	owner.withConsumer = func(ctx context.Context, _ hostcapacity.Binding, fn func(context.Context, hostcapacity.View) error) error {
		return fn(ctx, hostcapacity.View{Policy: policy, LedgerPath: broker.Path, Pools: []string{"local-checks"}, Epoch: owner.Binding.Epoch})
	}
	result, err := Execute(context.Background(), root, bundle, filepath.Join(t.TempDir(), "evidence"), s, r, owner)
	if err != nil || result.Status != "passed" {
		t.Fatal(result, err)
	}
	worker.grant.Fence = "stale-fence"
	result, err = Execute(context.Background(), root, bundle, filepath.Join(t.TempDir(), "evidence"), s, r, owner)
	if err == nil || result.Status == "passed" {
		t.Fatal("stale grant executed", result, err)
	}
	// The adapter verifies existing charge and never releases/adopts/reinitializes it.
	snapshot, err := broker.Status(&policy)
	if err != nil || len(snapshot.Grants) != 1 {
		t.Fatal("adapter changed grants", err)
	}
}
