package probe

import (
	"context"
	"slices"
	"strings"
	"testing"

	crfgithub "github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/github"
)

type liveFake struct {
	group         crfgithub.RunnerGroup
	quarantine    crfgithub.RunnerGroup
	set           crfgithub.ScaleSet
	capacities    []int
	closed        bool
	deleted       bool
	partialUpdate bool
}

func (f *liveFake) CreateRunnerScaleSet(_ context.Context, spec crfgithub.CreateSpec) (crfgithub.ScaleSet, error) {
	spec.ID = 41
	f.set = spec
	return spec, nil
}
func (f *liveFake) GetRunnerScaleSet(context.Context, int64) (crfgithub.ScaleSet, error) {
	return f.set, nil
}
func (f *liveFake) GetRunnerScaleSetByName(context.Context, int64, string) (crfgithub.ScaleSet, error) {
	return f.set, nil
}
func (f *liveFake) UpdateRunnerScaleSet(_ context.Context, id int64, spec crfgithub.UpdateSpec) (crfgithub.ScaleSet, error) {
	spec.ID = id
	f.set = spec
	if f.partialUpdate {
		return crfgithub.ScaleSet{}, nil
	}
	return spec, nil
}
func (f *liveFake) DeleteRunnerScaleSet(context.Context, int64) error {
	f.deleted = true
	return nil
}
func (f *liveFake) GetRunnerGroupByName(_ context.Context, name string) (crfgithub.RunnerGroup, error) {
	if name == "CRF Quarantine" {
		return f.quarantine, nil
	}
	return f.group, nil
}
func (*liveFake) CreateMessageSession(context.Context, int64) (crfgithub.Session, error) {
	return crfgithub.Session{ScaleSetID: 41, ID: "session"}, nil
}
func (f *liveFake) GetMessage(_ context.Context, _ crfgithub.Session, _ int64, capacity int) (crfgithub.MessageBatch, error) {
	f.capacities = append(f.capacities, capacity)
	return crfgithub.MessageBatch{MessageID: int64(capacity + 1),
		Statistics: &crfgithub.Statistics{TotalAssignedJobs: 0}}, nil
}
func (*liveFake) AcquireJobs(context.Context, crfgithub.Session, crfgithub.AcquireRequest) (crfgithub.AcquireResult, error) {
	return crfgithub.AcquireResult{}, nil
}
func (*liveFake) AcknowledgeMessage(context.Context, crfgithub.Session, int64) error { return nil }
func (*liveFake) GenerateJitRunnerConfig(context.Context, int64, crfgithub.JITRequest) ([]byte, error) {
	return []byte("jit"), nil
}
func (f *liveFake) CloseMessageSession(context.Context, crfgithub.Session) error {
	f.closed = true
	return nil
}

func liveConfig() LiveConfig {
	return LiveConfig{Owner: "dinglebear-ai", RunnerGroupName: "CI Runner Farm Trusted",
		QuarantineRunnerGroupName: "CRF Quarantine",
		RunnerGroupPolicy:         "selected_repositories", InstallationID: "installation", HostID: "host",
		PluginDigest: strings.Repeat("a", 64), HelperDigest: strings.Repeat("b", 64),
		ModuleRevision: "6ce025902cd964747a078c2aabe7340ebc667eca", GoVersion: "go1.25.3",
		ImageDigest: strings.Repeat("c", 64), DockerfileDigest: strings.Repeat("d", 64),
		EntrypointDigest: strings.Repeat("e", 64),
		Workload: WorkloadEvidence{TotalAssignedJobs: true, ZeroToOne: true, CancelReassign: true,
			AckReplay: true, NestedCgroupCharging: true, ClassicQuarantineBarrier: true}}
}

func TestRunLiveProvesRemoteLifecycleAndSealsOnlyAfterCleanup(t *testing.T) {
	api := &liveFake{group: crfgithub.RunnerGroup{ID: 7, Name: "CI Runner Farm Trusted"},
		quarantine: crfgithub.RunnerGroup{ID: 8, Name: "CRF Quarantine"}}
	record, err := RunLive(context.Background(), liveConfig(), api)
	if err != nil {
		t.Fatal(err)
	}
	if record.RunnerGroupID != 7 || record.CompatibilityRecordID == "" ||
		!record.Cleanup.Complete || len(record.Cleanup.IDs) != 0 {
		t.Fatalf("record is not clean and sealed: %#v", record)
	}
	if !api.closed || !api.deleted || !slices.Equal(api.capacities, []int{0, 1}) {
		t.Fatalf("remote lifecycle incomplete: %#v", api)
	}
	for _, capability := range required {
		if !record.Capabilities[capability] {
			t.Fatalf("capability %s was not proven", capability)
		}
	}
}

func TestRunLiveVerifiesUpdateWithAuthoritativeGet(t *testing.T) {
	api := &liveFake{
		group:         crfgithub.RunnerGroup{ID: 7, Name: "CI Runner Farm Trusted"},
		quarantine:    crfgithub.RunnerGroup{ID: 8, Name: "CRF Quarantine"},
		partialUpdate: true,
	}
	if _, err := RunLive(context.Background(), liveConfig(), api); err != nil {
		t.Fatalf("partial update response was treated as authoritative: %v", err)
	}
}

func TestRunLiveRejectsDefaultGroupAndStillCleansUp(t *testing.T) {
	api := &liveFake{group: crfgithub.RunnerGroup{ID: 1, Name: "Default", IsDefault: true}}
	if _, err := RunLive(context.Background(), liveConfig(), api); err == nil {
		t.Fatal("default runner group was accepted")
	}
	if api.set.ID != 0 {
		t.Fatal("probe mutated remote state before validating the runner group")
	}
}

func TestRunLiveRefusesUnprovenWorkloadEvidence(t *testing.T) {
	api := &liveFake{group: crfgithub.RunnerGroup{ID: 7, Name: "CI Runner Farm Trusted"},
		quarantine: crfgithub.RunnerGroup{ID: 8, Name: "CRF Quarantine"}}
	cfg := liveConfig()
	cfg.Workload.ZeroToOne = false
	if _, err := RunLive(context.Background(), cfg, api); err == nil {
		t.Fatal("missing zero-to-one proof was accepted")
	}
	if !api.deleted {
		t.Fatal("failed probe did not delete its exact scale-set ID")
	}
}
