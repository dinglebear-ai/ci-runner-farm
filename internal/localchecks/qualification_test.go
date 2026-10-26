package localchecks

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestKernelQualificationRequiresExactActualHardLimits(t *testing.T) {
	root := t.TempDir()
	for name, value := range map[string]string{"cpu.max": "200000 100000\n", "memory.max": "12884901888\n", "memory.swap.max": "0\n", "pids.max": "4096\n", "cgroup.type": "domain\n"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	proof, err := readKernelLimits(root)
	if err != nil || proof.Verify(12288, 2, 4096) != nil {
		t.Fatal(proof, err)
	}
	proof.MemoryBytes++
	if err := proof.Verify(12288, 2, 4096); err == nil {
		t.Fatal("wrong actual memory admitted")
	}
	if err := os.WriteFile(filepath.Join(root, "cpu.max"), []byte("max 100000"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readKernelLimits(root); err == nil {
		t.Fatal("unlimited CPU accepted")
	}
}
func TestQualificationBindingCannotEnableOrdinaryChecks(t *testing.T) {
	b := protectedFixtureBinding(t, false)
	if _, err := loadProtectedBinding(b, uint32(os.Getuid()), true); err != nil {
		t.Fatal(err)
	}
	if _, err := loadProtectedBinding(b, uint32(os.Getuid())); err == nil {
		t.Fatal("qualification enabled ordinary checks")
	}
}

type qualificationFixture struct {
	*creatingFixture
	stopped *bool
}

func (d *qualificationFixture) Stop(context.Context, string) error {
	*d.stopped = true
	d.container.Running = false
	d.container.Stopped = true
	return nil
}
func (d *qualificationFixture) Qualify(context.Context, string, Submission) (QualificationProof, error) {
	return QualificationProof{Scope: "cgroup-isolation-only", Image: d.Binding().Image, ProbeSHA256: strings.Repeat("f", 64), Outer: KernelLimits{Domain: true, CPUQuota: 200000, CPUPeriod: 100000, MemoryBytes: 8192 << 20, PIDs: 4096}, Nested: KernelLimits{Domain: true, CPUQuota: 100000, CPUPeriod: 100000, MemoryBytes: 64 << 20, PIDs: 64}}, nil
}
func TestQualificationUsesExistingGrantAndReleasesOnlyStoppedWorker(t *testing.T) {
	w, d, s := nativeFixture(t)
	s.TimeoutSeconds = 180
	s.ScratchMiB = 1024
	stopped := false
	q := &qualificationFixture{creatingFixture: &creatingFixture{nativeFixtureDriver: d, worker: w}, stopped: &stopped}
	w.driver = q
	r, err := w.Qualify(context.Background(), s)
	if err != nil || r.State != "released" || r.Qualification == nil || !stopped {
		t.Fatal(r, err)
	}
	snapshot, err := w.broker.Status(&w.policy)
	if err != nil || len(snapshot.Grants) != 0 {
		t.Fatal(snapshot, err)
	}
	if r.Qualification.DiskQuotaEnforced {
		t.Fatal("unproved disk quota claimed")
	}
}

func TestQualificationRefusesUnsupportedDriverBeforeCreationOrAdmission(t *testing.T) {
	w, d, s := nativeFixture(t)
	s.TimeoutSeconds = 180
	s.ScratchMiB = 1024
	creator := &creatingFixture{nativeFixtureDriver: d, worker: w}
	w.driver = creator
	if _, err := w.Qualify(context.Background(), s); err == nil {
		t.Fatal("unsupported driver accepted")
	}
	if creator.calls != 0 || d.starts != 0 {
		t.Fatal("effects before qualifier capability check")
	}
	snapshot, err := w.broker.Status(&w.policy)
	if err != nil || len(snapshot.Grants) != 0 {
		t.Fatal("unsupported driver retained a charge", err)
	}
}

func TestQualificationRejectsBroadOrUnboundedRequests(t *testing.T) {
	s := submission()
	s.TimeoutSeconds = 180
	s.ScratchMiB = 1024
	if err := validateQualificationSubmission(s); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*Submission){func(s *Submission) { s.CPUs = 3 }, func(s *Submission) { s.MemoryMiB = 12289 }, func(s *Submission) { s.TimeoutSeconds = 181 }, func(s *Submission) { s.ScratchMiB = 1 }} {
		candidate := s
		change(&candidate)
		if err := validateQualificationSubmission(candidate); err == nil {
			t.Fatal("broad qualification admitted")
		}
	}
	if err := availableScratch(t.TempDir(), 1<<20); err == nil {
		t.Fatal("impossible free-byte budget accepted")
	}
}

func TestFailedQualificationCleanupCanRetryThroughSameOwnerWithoutEnablingChecks(t *testing.T) {
	w, d, s := nativeFixture(t)
	driver := &stoppableFixture{nativeFixtureDriver: d, fail: true}
	w.driver = driver
	if _, err := w.AdmitStart(context.Background(), s, d.container.ID); err != nil {
		t.Fatal(err)
	}
	if err := w.Cancel(context.Background(), s.RequestID); err == nil {
		t.Fatal("uncertain stop treated as clean")
	}
	snapshot, _ := w.broker.Status(&w.policy)
	if len(snapshot.Grants) != 1 {
		t.Fatal("uncertain charge lost")
	}
	driver.fail = false
	if err := w.Cancel(context.Background(), s.RequestID); err != nil {
		t.Fatal(err)
	}
	snapshot, _ = w.broker.Status(&w.policy)
	if len(snapshot.Grants) != 0 {
		t.Fatal("terminal grant retained")
	}
}

func TestU7NoSwapRequiresBothLiveKernelObservations(t *testing.T) {
	root, proc := t.TempDir(), t.TempDir()
	for name, value := range map[string]string{"cpu.max": "200000 100000", "memory.max": "12884901888", "memory.swap.max": "max", "pids.max": "4096", "cgroup.type": "domain"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write := func(name, value string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(proc, name), []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("swaps", "Filename\tType\tSize\tUsed\tPriority\n")
	write("meminfo", "MemTotal: 1000000 kB\nSwapTotal: 0 kB\n")
	p, err := readKernelLimitsWithProc(root, proc)
	if err != nil || p.SwapMode != "host-no-swap" || p.Verify(12288, 2, 4096) != nil {
		t.Fatal(p, err)
	}
	if err := os.Remove(filepath.Join(root, "memory.swap.max")); err != nil {
		t.Fatal(err)
	}
	if _, err := readKernelLimitsWithProc(root, proc); err != nil {
		t.Fatal(err)
	}
	for _, sample := range []struct{ swaps, meminfo string }{
		{"Filename Type Size Used Priority\n/dev/sda partition 100 0 -2\n", "SwapTotal: 0 kB\n"},
		{"Filename Type Size Used Priority\n", "SwapTotal: 1024 kB\n"},
		{"", "SwapTotal: 0 kB\n"},
		{"Filename Type Size Used Priority\n", "SwapTotal: 0 kB\nSwapTotal: 0 kB\n"},
	} {
		write("swaps", sample.swaps)
		write("meminfo", sample.meminfo)
		if _, err := readKernelLimitsWithProc(root, proc); err == nil {
			t.Fatal("unproven no-swap accepted")
		}
	}
	write("swaps", "Filename Type Size Used Priority\n")
	write("meminfo", "SwapTotal: 0 kB\n")
	if err := os.WriteFile(filepath.Join(root, "memory.swap.max"), []byte("garbage"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readKernelLimitsWithProc(root, proc); err == nil {
		t.Fatal("malformed limit treated as absent")
	}
}
