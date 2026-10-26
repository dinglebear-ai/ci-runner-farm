package localchecks

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type nativeFixtureDriver struct {
	container       NativeContainer
	starts, removes int
	startError      error
	inspectCalls    int
	inspectHook     func(*nativeFixtureDriver)
	missing         bool
}

func (d *nativeFixtureDriver) Binding() WorkerBinding {
	return WorkerBinding{Image: "sha256:" + strings.Repeat("e", 64), SourceRoot: "/fixture/source", DockerRoot: "/fixture/docker"}
}

func (d *nativeFixtureDriver) Inspect(context.Context, string) (NativeContainer, error) {
	d.inspectCalls++
	if d.inspectHook != nil {
		d.inspectHook(d)
	}
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
	d.container.Stopped = false
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

func residentFixture(t *testing.T) (*nativeWorker, *nativeFixtureDriver, Submission) {
	w, d, s := nativeFixture(t)
	w.policy.SharedMemoryHeadroom = true
	pool := w.policy.Pools["build"]
	pool.Maximum = 2
	w.policy.Pools["build"] = pool
	w.policy.CPUAdmission = sharedcapacity.CPUAdmissionSoft
	w.policy.BuildMemoryOvercommit = &sharedcapacity.BuildMemoryOvercommit{AdditionalMiB: 16384, MinimumAvailableMiB: 1024}
	w.broker = sharedcapacity.Broker{Path: filepath.Join(t.TempDir(), "resident.bolt"), ObserveMemory: func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: 65536, ObservedAt: time.Now()}, nil
	}}
	if err := w.broker.Initialize(&w.policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	return w, d, s
}
func TestNativeResidentStartConfirmsOnlyExactDurableRunningOwner(t *testing.T) {
	w, d, s := residentFixture(t)
	r, err := w.AdmitStart(context.Background(), s, d.container.ID)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := w.broker.Status(&w.policy)
	start := snapshot.Starts[w.request(s).ID]
	if err != nil || !start.Started || start.MemoryMiB != 0 {
		t.Fatal("running worker retains shadow RAM", start, err)
	}
	w.broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: 1024 + s.MemoryMiB, ObservedAt: time.Now()}, nil
	}
	follower := s
	follower.RequestID = "fitting-follower"
	decision, err := w.broker.Admit(&w.policy, w.request(follower))
	if err != nil || !decision.Admitted {
		t.Fatal("confirmed worker double-charged RAM", decision, err)
	}
	saved, err := w.load(s.RequestID)
	if err != nil || saved.State != "running" || saved.Fence != r.Fence {
		t.Fatal(saved, err)
	}
}
func TestNativeResidentStartRechecksMemoryBeforeDockerDispatch(t *testing.T) {
	w, d, s := residentFixture(t)
	samples := 0
	w.broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		samples++
		available := uint64(65536)
		if samples > 1 {
			available = 0
		}
		return sharedcapacity.MemoryObservation{AvailableMiB: available, ObservedAt: time.Now()}, nil
	}
	_, err := w.AdmitStart(context.Background(), s, d.container.ID)
	if !errors.Is(err, ErrNativeQueued) || d.starts != 0 {
		t.Fatal("dispatched without fresh RAM", err, d.starts, samples)
	}
	snapshot, _ := w.broker.Status(&w.policy)
	if len(snapshot.Grants) != 1 || snapshot.Starts[w.request(s).ID].MemoryMiB != s.MemoryMiB {
		t.Fatal("lost retained charge", snapshot)
	}
}
func TestNativeResidentUncertainStartKeepsShadowCharge(t *testing.T) {
	w, d, s := residentFixture(t)
	d.startError = errors.New("unknown start")
	_, err := w.AdmitStart(context.Background(), s, d.container.ID)
	snapshot, _ := w.broker.Status(&w.policy)
	start := snapshot.Starts[w.request(s).ID]
	if err == nil || start.Started || start.MemoryMiB != s.MemoryMiB {
		t.Fatal(start, err)
	}
}

func TestNativeResidentConfirmationFailureRetainsExactShadowCharge(t *testing.T) {
	w, d, s := residentFixture(t)
	d.inspectHook = func(d *nativeFixtureDriver) {
		if d.inspectCalls == 3 {
			d.container.SourceDigest = "wrong"
		}
	}
	r, err := w.AdmitStart(context.Background(), s, d.container.ID)
	snapshot, _ := w.broker.Status(&w.policy)
	start := snapshot.Starts[w.request(s).ID]
	if err == nil || r.State != "uncertain" || start.Started || start.MemoryMiB != s.MemoryMiB || r.Start == nil || r.Start.Nonce != start.Nonce {
		t.Fatal("uncertain proof released shadow charge", r, start, err)
	}
	if _, err := w.AdmitStart(context.Background(), s, d.container.ID); err == nil || d.starts != 1 {
		t.Fatal("replayed uncertain start", err)
	}
}
