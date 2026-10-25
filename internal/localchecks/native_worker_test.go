package localchecks

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type nativeFixtureDriver struct {
	container       NativeContainer
	starts, removes int
	startError      error
	missing         bool
}

func (d *nativeFixtureDriver) Binding() WorkerBinding {
	return WorkerBinding{Image: "sha256:" + strings.Repeat("e", 64), SourceRoot: "/fixture/source", DockerRoot: "/fixture/docker"}
}

func (d *nativeFixtureDriver) Inspect(context.Context, string) (NativeContainer, error) {
	if d.missing {
		return NativeContainer{}, ErrNativeContainerMissing
	}
	return d.container, nil
}
func (d *nativeFixtureDriver) Start(context.Context, string) error {
	d.starts++
	if d.startError != nil {
		return d.startError
	}
	d.container.Running = true
	return nil
}
func (d *nativeFixtureDriver) Remove(context.Context, string) error {
	if d.container.Running {
		return errors.New("still running")
	}
	d.removes++
	d.missing = true
	return nil
}
func nativeFixture(t *testing.T) (*nativeWorker, *nativeFixtureDriver, Submission) {
	t.Helper()
	s := submission()
	policy := sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 32768, VCPUs: 8}, AgingSeconds: 60, Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: s.MemoryMiB, VCPUs: s.CPUs}, Maximum: 1}}}
	broker := sharedcapacity.Broker{Path: filepath.Join(t.TempDir(), "ledger.bolt")}
	if err := broker.Initialize(&policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	driver := &nativeFixtureDriver{container: NativeContainer{Managed: true, ID: strings.Repeat("d", 64), Role: "local-checks", RequestID: s.RequestID, SourceDigest: s.BundleSHA256, MemoryMiB: s.MemoryMiB, CPUs: s.CPUs, PrivateCgroup: true, InnerDocker: true, Stopped: true}}
	return &nativeWorker{epoch: "0123456789abcdef0123456789abcdef", broker: broker, policy: policy, root: filepath.Join(t.TempDir(), "receipts"), driver: driver}, driver, s
}
func TestNativeLocalChecksRoleChargesExistingBuildLedgerBeforeStart(t *testing.T) {
	worker, driver, s := nativeFixture(t)
	receipt, err := worker.AdmitStart(context.Background(), s, driver.container.ID)
	if err != nil || receipt.State != "running" || driver.starts != 1 {
		t.Fatal(receipt, err)
	}
	snapshot, err := worker.broker.Status(&worker.policy)
	if err != nil || len(snapshot.Grants) != 1 {
		t.Fatal(err)
	}
	if _, ok := snapshot.Grants["local-checks:"+s.RequestID]; !ok {
		t.Fatal("wrong ledger identity")
	}
	if err := worker.Complete(context.Background(), s.RequestID); err == nil {
		t.Fatal("released running worker")
	}
	driver.container.Running = false
	driver.container.Stopped = true
	if err := worker.Complete(context.Background(), s.RequestID); err != nil {
		t.Fatal(err)
	}
	snapshot, err = worker.broker.Status(&worker.policy)
	if err != nil || len(snapshot.Grants) != 0 || driver.removes != 1 {
		t.Fatal("grant not safely released", err)
	}
}
func TestNativeLocalChecksUncertainStartRetainsGrantAndRefusesReplay(t *testing.T) {
	worker, driver, s := nativeFixture(t)
	driver.startError = errors.New("transport lost")
	receipt, err := worker.AdmitStart(context.Background(), s, driver.container.ID)
	if err == nil || receipt.State != "uncertain" {
		t.Fatal(receipt, err)
	}
	if _, err := worker.AdmitStart(context.Background(), s, driver.container.ID); err == nil || driver.starts != 1 {
		t.Fatal("uncertain start replayed")
	}
	snapshot, err := worker.broker.Status(&worker.policy)
	if err != nil || len(snapshot.Grants) != 1 {
		t.Fatal("lost uncertain charge", err)
	}
}

func TestNativeLocalChecksRejectsDisappearedGrantAcrossRepeatedCleanup(t *testing.T) {
	worker, driver, s := nativeFixture(t)
	r, err := worker.AdmitStart(context.Background(), s, driver.container.ID)
	if err != nil {
		t.Fatal(err)
	}
	driver.container.Running = false
	driver.container.Stopped = true
	if err := worker.broker.Release(&worker.policy, "local-checks:"+s.RequestID, r.Fence, func(sharedcapacity.Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		if err := worker.Complete(context.Background(), s.RequestID); err == nil {
			t.Fatal("unknown disappeared grant became accepted cleanup")
		}
	}
}

func TestNativeLocalChecksWaitsInExistingPoolWithoutStartingOverBudget(t *testing.T) {
	w, d, s := nativeFixture(t)
	busy, err := w.broker.Admit(&w.policy, sharedcapacity.Request{ID: "build:existing", Pool: "build"})
	if err != nil || busy.Grant == nil {
		t.Fatal(err)
	}
	r, err := w.AdmitStart(context.Background(), s, d.container.ID)
	if !errors.Is(err, ErrNativeQueued) || r.State != "queued" || d.starts != 0 {
		t.Fatal(r, err)
	}
	if err := w.broker.Release(&w.policy, busy.Grant.ID, busy.Grant.Fence, func(sharedcapacity.Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
	r, err = w.AdmitStart(context.Background(), s, d.container.ID)
	if err != nil || r.State != "running" || d.starts != 1 {
		t.Fatal(r, err)
	}
}
func TestNativeLocalChecksRefusesWrongRoleOrUnchargedLimits(t *testing.T) {
	for name, change := range map[string]func(*NativeContainer){"github role": func(c *NativeContainer) { c.Role = "runner" }, "host socket": func(c *NativeContainer) { c.HostDockerSocket = true }, "no private cgroup": func(c *NativeContainer) { c.PrivateCgroup = false }, "wrong memory": func(c *NativeContainer) { c.MemoryMiB++ }, "wrong source": func(c *NativeContainer) { c.SourceDigest = strings.Repeat("f", 64) }} {
		t.Run(name, func(t *testing.T) {
			w, d, s := nativeFixture(t)
			change(&d.container)
			if _, err := w.AdmitStart(context.Background(), s, d.container.ID); err == nil || d.starts != 0 {
				t.Fatal("unqualified worker started")
			}
			snapshot, err := w.broker.Status(&w.policy)
			if err != nil || len(snapshot.Grants) != 0 {
				t.Fatal("unqualified worker charged", err)
			}
		})
	}
}
