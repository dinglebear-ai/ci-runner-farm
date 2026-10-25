package localchecks

import (
	"context"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"os"
	"path/filepath"
	"testing"
)

func TestRegisteredBuildRolePreservesBusyJobsAndRetiresOnlyStoppedOwner(t *testing.T) {
	w, d, s := nativeFixture(t)
	r, err := w.AdmitStart(context.Background(), s, d.container.ID)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := w.broker.Status(&w.policy)
	if err != nil {
		t.Fatal(err)
	}
	grant := snapshot.Grants[w.request(s).ID]
	owner := NewBuildRoleOwner(&hostcapacity.Config{Epoch: w.epoch, LedgerPath: w.broker.Path, Policy: w.policy, ReceiptRoot: filepath.Dir(w.root)})
	// Fixture receipts use the same dedicated leaf as production.
	owner.configuration.ReceiptRoot = filepath.Dir(w.root)
	owner.driver = func(WorkerBinding) NativeDriver { return d }
	// The fixture's leaf is named receipts rather than local-checks.
	target := filepath.Join(owner.configuration.ReceiptRoot, "local-checks")
	if err := os.Rename(w.root, target); err != nil {
		t.Fatal(err)
	}
	w.root = target
	if err := owner.ValidateGrant(context.Background(), grant); err != nil {
		t.Fatal(err)
	}
	if err := owner.RetireGrant(context.Background(), grant); !errors.Is(err, farmcapacity.ErrQueued) || d.removes != 0 {
		t.Fatal("busy owner retired", err)
	}
	wrong := grant
	wrong.Fence = "wrong-fence"
	if err := owner.ValidateGrant(context.Background(), wrong); err == nil {
		t.Fatal("unattested grant accepted")
	}
	d.container.Running = false
	d.container.Stopped = true
	if err := owner.RetireGrant(context.Background(), grant); err != nil {
		t.Fatal(err)
	}
	final, err := w.load(s.RequestID)
	if err != nil || final.State != "released" || r.ContainerID != final.ContainerID {
		t.Fatal(final, err)
	}
}
