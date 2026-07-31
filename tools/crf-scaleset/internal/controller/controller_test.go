package controller

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	crfgithub "github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

type fakeAPI struct {
	mu          sync.Mutex
	nextID      int64
	sets        map[int64]crfgithub.ScaleSet
	capacities  []int
	acknowledge int
	jitCalls    int
	deleted     []int64
}

func (f *fakeAPI) CreateRunnerScaleSet(_ context.Context, spec crfgithub.CreateSpec) (crfgithub.ScaleSet, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextID++
	spec.ID = f.nextID
	f.sets[spec.ID] = spec
	return spec, nil
}
func (f *fakeAPI) GetRunnerScaleSet(_ context.Context, id int64) (crfgithub.ScaleSet, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.sets[id], nil
}
func (f *fakeAPI) GetRunnerScaleSetByName(_ context.Context, group int64, name string) (crfgithub.ScaleSet, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, set := range f.sets {
		if set.RunnerGroupID == group && set.Name == name {
			return set, nil
		}
	}
	return crfgithub.ScaleSet{}, nil
}
func (f *fakeAPI) UpdateRunnerScaleSet(_ context.Context, id int64, spec crfgithub.UpdateSpec) (crfgithub.ScaleSet, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	spec.ID = id
	f.sets[id] = spec
	return spec, nil
}
func (f *fakeAPI) DeleteRunnerScaleSet(_ context.Context, id int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, id)
	delete(f.sets, id)
	return nil
}
func (*fakeAPI) GetRunnerGroupByName(context.Context, string) (crfgithub.RunnerGroup, error) {
	return crfgithub.RunnerGroup{}, nil
}
func (_ *fakeAPI) CreateMessageSession(_ context.Context, id int64) (crfgithub.Session, error) {
	return crfgithub.Session{ScaleSetID: id, ID: "session"}, nil
}
func (f *fakeAPI) GetMessage(_ context.Context, _ crfgithub.Session, _ int64, capacity int) (crfgithub.MessageBatch, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.capacities = append(f.capacities, capacity)
	if capacity == 0 {
		return crfgithub.MessageBatch{}, nil
	}
	return crfgithub.MessageBatch{MessageID: 11,
		Statistics: &crfgithub.Statistics{TotalAssignedJobs: 1}, AssignedHandles: []int64{501}}, nil
}
func (*fakeAPI) AcquireJobs(_ context.Context, _ crfgithub.Session, req crfgithub.AcquireRequest) (crfgithub.AcquireResult, error) {
	return crfgithub.AcquireResult{AcquiredIDs: slices.Clone(req.RequestIDs)}, nil
}
func (f *fakeAPI) AcknowledgeMessage(context.Context, crfgithub.Session, int64) error {
	f.mu.Lock()
	f.acknowledge++
	f.mu.Unlock()
	return nil
}
func (f *fakeAPI) GenerateJitRunnerConfig(context.Context, int64, crfgithub.JITRequest) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.jitCalls++
	return []byte("single-use-jit"), nil
}

func request(cfg RuntimeConfig, operation string, sequence uint64, payload string) protocol.Request {
	return protocol.Request{SchemaVersion: 1, RequestID: "request-1", Operation: operation,
		ConfigRevision: cfg.ConfigRevision, OwnershipRevision: cfg.OwnershipRevision,
		ControllerInstanceID: cfg.ControllerInstanceID, Sequence: sequence, Payload: []byte(payload)}
}

func TestControlPlaneRunsSessionsIssuesSingleUseJITAndDeletesOwned(t *testing.T) {
	root := t.TempDir()
	cfg := RuntimeConfig{SchemaVersion: 1, ControllerInstanceID: "controller-1",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		PluginDigest: strings.Repeat("1", 64), ImageDigest: strings.Repeat("2", 64),
		DockerfileDigest: strings.Repeat("3", 64), EntrypointDigest: strings.Repeat("4", 64),
		InstallationID: "01234567-89ab-cdef-0123-456789abcdef", Owner: "dinglebear-ai",
		HostID:        "host-1",
		RunnerGroupID: 7, QuarantineRunnerGroupID: 8, StateDir: filepath.Join(root, "state"),
		OwnershipPath: filepath.Join(root, "ownership.json"), HeartbeatSeconds: 1,
		Pools: []PoolConfig{{ID: "python", RoutingLabel: "ci-pool-python",
			Labels: []string{"self-hosted", "linux", "x64", "ci-pool-python"}}}}
	api := &fakeAPI{nextID: 40, sets: map[int64]crfgithub.ScaleSet{}}
	control, err := New(cfg, api)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()

	if response := control.Handle(context.Background(), request(cfg, "apply_sessions", 1, `{}`)); !response.OK {
		t.Fatalf("apply sessions failed: %#v", response)
	}
	for _, set := range api.sets {
		if set.RunnerGroupID != cfg.QuarantineRunnerGroupID ||
			!slices.Equal(set.Labels, cfg.Pools[0].Labels) {
			t.Fatalf("apply did not preserve labels behind quarantine: %#v", set)
		}
	}
	if response := control.Handle(context.Background(), request(cfg, "publish_capacity_leases", 2,
		`{"leases":{"python":1}}`)); !response.OK {
		t.Fatalf("publish leases failed: %#v", response)
	}

	deadline := time.Now().Add(3 * time.Second)
	var snapshot protocol.Snapshot
	sequence := uint64(3)
	for time.Now().Before(deadline) {
		response := control.Handle(context.Background(), request(cfg, "read_snapshot", sequence, `{}`))
		sequence++
		var ok bool
		snapshot, ok = response.Result.(protocol.Snapshot)
		if response.OK && ok && len(snapshot.Pools) == 1 &&
			slices.Contains(snapshot.Pools[0].AcquiredHandles, int64(501)) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(snapshot.Pools) != 1 || !slices.Contains(snapshot.Pools[0].AcquiredHandles, int64(501)) {
		t.Fatalf("acquired handle never reached snapshot: %#v", snapshot)
	}

	jitPayload := `{"pool_id":"python","work_handle":501,"runner_name":"runner-501","work_folder":"_work"}`
	first := control.Handle(context.Background(), request(cfg, "issue_jit", sequence, jitPayload))
	sequence++
	if !first.OK {
		t.Fatalf("JIT issue failed: %#v", first)
	}
	second := control.Handle(context.Background(), request(cfg, "issue_jit", sequence, jitPayload))
	sequence++
	if second.OK || second.Code != "work_handle_not_available" || api.jitCalls != 1 {
		t.Fatalf("JIT descriptor was reusable: response=%#v calls=%d", second, api.jitCalls)
	}

	if response := control.Handle(context.Background(), request(cfg, "reconcile_owned", sequence,
		`{"eligible":true}`)); !response.OK {
		t.Fatalf("activation failed: %#v", response)
	}
	sequence++
	for _, set := range api.sets {
		if !slices.Contains(set.Labels, "ci-pool-python") {
			t.Fatalf("activation labels missing: %#v", set.Labels)
		}
	}
	if response := control.Handle(context.Background(), request(cfg, "delete_owned", sequence, `{}`)); !response.OK {
		t.Fatalf("delete failed: %#v", response)
	}
	if len(api.deleted) != 1 || len(api.sets) != 0 {
		t.Fatalf("exact owned set not deleted: ids=%#v sets=%#v", api.deleted, api.sets)
	}
}

func TestControlPlaneRejectsIdentityAndUnknownPools(t *testing.T) {
	root := t.TempDir()
	cfg := RuntimeConfig{SchemaVersion: 1, ControllerInstanceID: "controller-1",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		PluginDigest: strings.Repeat("1", 64), ImageDigest: strings.Repeat("2", 64),
		DockerfileDigest: strings.Repeat("3", 64), EntrypointDigest: strings.Repeat("4", 64),
		InstallationID: "installation", HostID: "host-1", Owner: "dinglebear-ai", RunnerGroupID: 7, QuarantineRunnerGroupID: 8,
		StateDir: filepath.Join(root, "state"), OwnershipPath: filepath.Join(root, "ownership.json"),
		HeartbeatSeconds: 1, Pools: []PoolConfig{{ID: "rust", RoutingLabel: "ci-pool-rust",
			Labels: []string{"self-hosted", "ci-pool-rust"}}}}
	control, err := New(cfg, &fakeAPI{nextID: 1, sets: map[int64]crfgithub.ScaleSet{}})
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	bad := request(cfg, "read_snapshot", 1, `{}`)
	bad.ConfigRevision = strings.Repeat("c", 64)
	if response := control.Handle(context.Background(), bad); response.OK || response.Code != "identity_mismatch" {
		t.Fatalf("identity mismatch accepted: %#v", response)
	}
	response := control.Handle(context.Background(), request(cfg, "publish_capacity_leases", 2,
		`{"leases":{"foreign":1}}`))
	if response.OK || response.Code != "invalid_leases" {
		t.Fatalf("foreign pool accepted: %#v", response)
	}
	response = control.Handle(context.Background(), request(cfg, "read_snapshot", 2, `{}`))
	if response.OK || response.Code != "sequence_regression" {
		t.Fatalf("replayed sequence accepted: %#v", response)
	}
}

func TestApplySessionsRestoresEffectiveEligibilityAfterRestart(t *testing.T) {
	root := t.TempDir()
	cfg := RuntimeConfig{SchemaVersion: 1, ControllerInstanceID: "controller-1",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		PluginDigest: strings.Repeat("1", 64), ImageDigest: strings.Repeat("2", 64),
		DockerfileDigest: strings.Repeat("3", 64), EntrypointDigest: strings.Repeat("4", 64),
		InstallationID: "installation", HostID: "host-1", Owner: "dinglebear-ai", RunnerGroupID: 7, QuarantineRunnerGroupID: 8,
		StateDir: filepath.Join(root, "state"), OwnershipPath: filepath.Join(root, "ownership.json"),
		HeartbeatSeconds: 1, Pools: []PoolConfig{{ID: "python", RoutingLabel: "python",
			Labels: []string{"self-hosted", "python"}}}}
	api := &fakeAPI{nextID: 3, sets: map[int64]crfgithub.ScaleSet{}}
	control, err := New(cfg, api)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	response := control.Handle(context.Background(), request(cfg, "apply_sessions", 1, `{"eligible":true}`))
	if !response.OK {
		t.Fatalf("active session restore failed: %#v", response)
	}
	for _, set := range api.sets {
		if !slices.Contains(set.Labels, "python") {
			t.Fatalf("restart silently made the effective backend ineligible: %#v", set.Labels)
		}
	}
}

func TestLoadRuntimeConfigRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "runtime.real.json")
	link := filepath.Join(root, "runtime.json")
	cfg := RuntimeConfig{SchemaVersion: 1, ControllerInstanceID: "controller-1",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		PluginDigest: strings.Repeat("1", 64), ImageDigest: strings.Repeat("2", 64),
		DockerfileDigest: strings.Repeat("3", 64), EntrypointDigest: strings.Repeat("4", 64),
		InstallationID: "installation", HostID: "host-1", Owner: "dinglebear-ai", RunnerGroupID: 7, QuarantineRunnerGroupID: 8,
		StateDir: filepath.Join(root, "state"), OwnershipPath: filepath.Join(root, "ownership.json"),
		HeartbeatSeconds: 1, Pools: []PoolConfig{{ID: "python", RoutingLabel: "python",
			Labels: []string{"self-hosted", "python"}}}}
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadRuntimeConfig(link); err == nil {
		t.Fatal("symlinked runtime config was accepted")
	}
}
