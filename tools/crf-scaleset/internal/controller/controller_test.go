package controller

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/protocol"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/supervisor"
)

type fakeAPI struct {
	mu          sync.Mutex
	nextID      int64
	sets        map[int64]crfgithub.ScaleSet
	capacities  []int
	acknowledge int
	jitCalls    int
	jitErr      error
	deleted     []int64
	runnerID    int64
	removed     []int64
	removeErr   error
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
func (*fakeAPI) CreateMessageSession(_ context.Context, id int64) (crfgithub.Session, error) {
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
func (*fakeAPI) GetAcquirableJobs(context.Context, int64) ([]crfgithub.AvailableJob, error) {
	return nil, nil
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
func (f *fakeAPI) GenerateJitRunnerConfig(context.Context, int64, crfgithub.JITRequest) (crfgithub.JITIssue, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.jitCalls++
	if f.jitErr != nil {
		return crfgithub.JITIssue{}, f.jitErr
	}
	f.runnerID++
	return crfgithub.JITIssue{Descriptor: []byte("single-use-jit"), RunnerID: f.runnerID}, nil
}
func (f *fakeAPI) RemoveRunner(_ context.Context, runnerID int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.removeErr != nil {
		return f.removeErr
	}
	f.removed = append(f.removed, runnerID)
	return nil
}

func request(cfg RuntimeConfig, operation string, sequence uint64, payload string) protocol.Request {
	return protocol.Request{SchemaVersion: 1, RequestID: "request-1", Operation: operation,
		ConfigRevision: cfg.ConfigRevision, OwnershipRevision: cfg.OwnershipRevision,
		ControllerInstanceID: cfg.ControllerInstanceID, Sequence: sequence, Payload: []byte(payload)}
}

func validRuntimeConfig(root string) RuntimeConfig {
	return RuntimeConfig{SchemaVersion: 1, ControllerInstanceID: "controller-1",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		PluginDigest: strings.Repeat("1", 64), ImageDigest: strings.Repeat("2", 64),
		DockerfileDigest: strings.Repeat("3", 64), EntrypointDigest: strings.Repeat("4", 64),
		InstallationID: "installation", HostID: "host-1", Owner: "dinglebear-ai",
		RunnerGroupID: 7, QuarantineRunnerGroupID: 8,
		StateDir: filepath.Join(root, "state"), OwnershipPath: filepath.Join(root, "ownership.json"),
		HeartbeatSeconds: 1, Pools: []PoolConfig{{ID: "python", RoutingLabel: "ci-pool-python",
			Labels: []string{"self-hosted", "linux", "x64", "ci-pool-python"}}}}
}

type closeTrackingPoller struct {
	consumeFailPoller
	closed int
	err    error
}

func (p *closeTrackingPoller) Close(context.Context) error {
	p.closed++
	return p.err
}

type consumeFailPoller struct{}

func (*consumeFailPoller) Poll(context.Context, supervisor.Pool, int) (supervisor.PollResult, error) {
	return supervisor.PollResult{}, nil
}
func (*consumeFailPoller) HasHandle(int64, int64) bool     { return true }
func (*consumeFailPoller) ConsumeHandle(int64, int64) bool { return false }
func (*consumeFailPoller) RetireHandle(int64, int64) error { return nil }
func (*consumeFailPoller) Close(context.Context) error     { return nil }

type fencePoller struct {
	consumeFailPoller
	hasCalls     int
	consumeCalls int
}

func (p *fencePoller) HasHandle(int64, int64) bool {
	p.hasCalls++
	return true
}

func (p *fencePoller) ConsumeHandle(int64, int64) bool {
	p.consumeCalls++
	return true
}

type retireFailPoller struct {
	fencePoller
	retireCalls int
}

func (p *retireFailPoller) RetireHandle(int64, int64) error {
	p.retireCalls++
	return errors.New("retirement unavailable")
}

func TestStatusReadsDoNotWaitForSlowControlPlaneMutation(t *testing.T) {
	root := t.TempDir()
	cfg := validRuntimeConfig(root)
	control, err := New(cfg, &fakeAPI{sets: map[int64]crfgithub.ScaleSet{}})
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()

	// A GitHub operation holds this lock while it is in flight.  Fleet status
	// must remain available during that wait, even before sessions are applied.
	control.mu.Lock()
	defer control.mu.Unlock()
	result := make(chan protocol.Response, 1)
	go func() {
		result <- control.Handle(context.Background(), request(cfg, "read_snapshot", 1, `{}`))
	}()
	select {
	case response := <-result:
		if response.Code != "sessions_not_applied" {
			t.Fatalf("unexpected status response while mutation lock held: %#v", response)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("read_snapshot waited for a control-plane mutation")
	}
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

	jitPayload := issueJITPayload(t, cfg, "python", snapshot.Pools[0].ScaleSetID, 501)
	first := control.Handle(context.Background(), request(cfg, "issue_jit", sequence, jitPayload))
	sequence++
	if !first.OK {
		t.Fatalf("JIT issue failed: %#v", first)
	}
	descriptorPath := control.descriptorPath(snapshot.Pools[0].ScaleSetID, 501)
	info, err := os.Stat(descriptorPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("JIT descriptor cache was not private: info=%#v err=%v", info, err)
	}
	restarted, err := New(cfg, api)
	if err != nil {
		t.Fatal(err)
	}
	restarted.poller = &consumeFailPoller{}
	second := restarted.Handle(context.Background(), request(cfg, "issue_jit", 1, jitPayload))
	if !second.OK || api.jitCalls != 1 {
		t.Fatalf("durable JIT descriptor did not replay after restart: response=%#v calls=%d", second, api.jitCalls)
	}
	if fmt.Sprint(first.Result) != fmt.Sprint(second.Result) {
		t.Fatalf("replayed JIT descriptor changed: first=%#v second=%#v", first.Result, second.Result)
	}
	wrongIssueFence := fmt.Sprintf(`{"pool_id":"python","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":501,"runner_name":"runner-501","work_folder":"_work"}`,
		snapshot.Pools[0].ScaleSetID, strings.Repeat("f", 64))
	if response := restarted.Handle(context.Background(), request(cfg, "issue_jit", 2,
		wrongIssueFence)); response.OK || response.Code != "ownership_identity_mismatch" {
		t.Fatalf("JIT replay ignored persisted ownership fence: %#v", response)
	}
	retirePayload := fmt.Sprintf(`{"pool_id":"python","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":501}`,
		snapshot.Pools[0].ScaleSetID, cfg.OwnershipRevision)
	currentCfg := cfg
	currentCfg.OwnershipRevision = strings.Repeat("c", 64)
	control.cfg.OwnershipRevision = currentCfg.OwnershipRevision
	wrongScale := fmt.Sprintf(`{"pool_id":"python","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":501}`,
		snapshot.Pools[0].ScaleSetID+1, cfg.OwnershipRevision)
	if response := control.Handle(context.Background(), request(currentCfg, "retire_jit", sequence,
		wrongScale)); response.OK || response.Code != "scale_set_mismatch" {
		t.Fatalf("JIT retirement ignored scale-set fence: %#v", response)
	}
	sequence++
	wrongOwnership := fmt.Sprintf(`{"pool_id":"python","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":501}`,
		snapshot.Pools[0].ScaleSetID, strings.Repeat("f", 64))
	if response := control.Handle(context.Background(), request(currentCfg, "retire_jit", sequence,
		wrongOwnership)); response.OK || response.Code != "ownership_identity_mismatch" {
		t.Fatalf("JIT retirement ignored ownership fence: %#v", response)
	}
	sequence++
	if _, err := os.Stat(descriptorPath); err != nil {
		t.Fatalf("fenced retirement mutated descriptor: %v", err)
	}
	if response := control.Handle(context.Background(), request(currentCfg, "retire_jit", sequence,
		retirePayload)); !response.OK {
		t.Fatalf("JIT retirement failed: %#v", response)
	}
	sequence++
	if response := control.Handle(context.Background(), request(currentCfg, "read_jit_state", sequence,
		`{}`)); !response.OK || !strings.Contains(fmt.Sprint(response.Result), "retired") {
		t.Fatalf("pending retirement was not discoverable for recovery: %#v", response)
	}
	sequence++
	if response := control.Handle(context.Background(), request(currentCfg, "retire_jit", sequence,
		retirePayload)); !response.OK || fmt.Sprint(response.Result) != "map[retired:true]" {
		t.Fatalf("JIT retirement replay was not idempotent: %#v", response)
	}
	sequence++
	issued, err := os.ReadFile(filepath.Join(cfg.StateDir, "issued-handles.json"))
	if err != nil || !strings.Contains(string(issued), `"records":{}`) {
		t.Fatalf("terminal issued handle was not compacted: %q err=%v", issued, err)
	}
	if _, err := os.Stat(descriptorPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("retired JIT descriptor cache remained: err=%v", err)
	}
	api.mu.Lock()
	removedRunners := slices.Clone(api.removed)
	api.mu.Unlock()
	if len(removedRunners) != 1 || removedRunners[0] <= 0 {
		t.Fatalf("retirement did not delete the GitHub runner registration: %#v", removedRunners)
	}
	restartedRetire, err := New(currentCfg, api)
	if err != nil {
		t.Fatalf("historical retirement restart failed: %v", err)
	}
	if response := restartedRetire.Handle(context.Background(), request(currentCfg, "retire_jit", 1,
		retirePayload)); !response.OK {
		t.Fatalf("historical retirement proof did not survive restart: %#v", response)
	}
	wrongConfirmation := fmt.Sprintf(`{"pool_id":"wrong","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":501}`,
		snapshot.Pools[0].ScaleSetID, cfg.OwnershipRevision)
	if response := restartedRetire.Handle(context.Background(), request(currentCfg, "confirm_jit_retirement", 2,
		wrongConfirmation)); response.OK || response.Code != "retirement_fence_mismatch" {
		t.Fatalf("wrong retirement confirmation was not fenced: %#v", response)
	}
	if len(restartedRetire.retired) != 1 {
		t.Fatalf("wrong retirement confirmation mutated proof: retired=%#v", restartedRetire.retired)
	}
	if response := restartedRetire.Handle(context.Background(), request(currentCfg, "confirm_jit_retirement", 3,
		retirePayload)); !response.OK || fmt.Sprint(response.Result) != "map[confirmed:true]" {
		t.Fatalf("retirement confirmation failed: %#v", response)
	}
	if len(restartedRetire.retired) != 0 {
		t.Fatalf("retirement confirmation did not compact proof: retired=%#v", restartedRetire.retired)
	}
	// A lost success response is harmless: absent proof means confirmation was
	// already durably applied, without retaining a second unbounded ledger.
	for confirmSequence := uint64(4); confirmSequence < 104; confirmSequence++ {
		if response := restartedRetire.Handle(context.Background(), request(currentCfg,
			"confirm_jit_retirement", confirmSequence, retirePayload)); !response.OK {
			t.Fatalf("lost-response confirmation replay failed: %#v", response)
		}
	}
	retiredState, err := os.ReadFile(restartedRetire.retiredPath())
	if err != nil || !strings.Contains(string(retiredState), `"records":{}`) {
		t.Fatalf("confirmation cycles retained retired proofs: %q err=%v", retiredState, err)
	}
	if _, err := os.Stat(filepath.Join(cfg.StateDir, "confirmed-retirements.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("confirmation created a secondary ledger: %v", err)
	}
	confirmedRestart, err := New(currentCfg, api)
	if err != nil {
		t.Fatalf("confirmed retirement restart failed: %v", err)
	}
	if response := confirmedRestart.Handle(context.Background(), request(currentCfg, "confirm_jit_retirement", 1,
		retirePayload)); !response.OK || len(confirmedRestart.retired) != 0 || len(confirmedRestart.issued) != 0 {
		t.Fatalf("confirmed retirement replay retained state: %#v retired=%#v",
			response, confirmedRestart.retired)
	}
	confirmedRestart.Close()
	restartedRetire.Close()
	control.cfg.OwnershipRevision = cfg.OwnershipRevision

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
	legacyKey := fmt.Sprintf("%d:%d", snapshot.Pools[0].ScaleSetID, 999)
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg.StateDir, "issued-handles.json"),
		[]byte(fmt.Sprintf("{%q:%q}\n", legacyKey, "issued")), 0o600); err != nil {
		t.Fatal(err)
	}
	migrated, err := New(cfg, api)
	if err != nil {
		t.Fatalf("legacy issued migration failed: %v", err)
	}
	if record := migrated.issued[legacyKey]; record.PoolID != "python" ||
		record.OwnershipRevision != "" || !record.LegacyUnbound || record.WorkHandle != 999 {
		t.Fatalf("legacy issued binding changed: %#v", record)
	}
	migrated.poller = &consumeFailPoller{}
	if response := migrated.Handle(context.Background(), request(cfg, "read_jit_state", 1,
		`{}`)); !response.OK || !strings.Contains(fmt.Sprint(response.Result), cfg.OwnershipRevision) {
		t.Fatalf("legacy issued state did not project a recoverable ownership fence: %#v", response)
	}
	historicalRevision := cfg.OwnershipRevision
	wrongOuter := cfg
	wrongOuter.ControllerInstanceID = "wrong-controller"
	legacyExact := fmt.Sprintf(`{"pool_id":"python","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":999}`,
		snapshot.Pools[0].ScaleSetID, historicalRevision)
	if response := migrated.Handle(context.Background(), request(wrongOuter, "retire_jit", 2,
		legacyExact)); response.OK || response.Code != "identity_mismatch" {
		t.Fatalf("wrong outer identity was not fenced: %#v", response)
	}
	if record := migrated.issued[legacyKey]; !record.LegacyUnbound || record.OwnershipRevision != "" {
		t.Fatalf("wrong outer identity mutated legacy binding: %#v", record)
	}
	legacyWrong := fmt.Sprintf(`{"pool_id":"wrong","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":999}`,
		snapshot.Pools[0].ScaleSetID, historicalRevision)
	if response := migrated.Handle(context.Background(), request(cfg, "retire_jit", 2,
		legacyWrong)); response.OK {
		t.Fatalf("wrong legacy retirement tuple was not fenced: %#v", response)
	}
	if record := migrated.issued[legacyKey]; !record.LegacyUnbound || record.OwnershipRevision != "" {
		t.Fatalf("wrong legacy tuple mutated binding: %#v", record)
	}
	if response := migrated.Handle(context.Background(), request(cfg, "retire_jit", 3,
		legacyExact)); !response.OK {
		t.Fatalf("exact legacy retirement did not bind and retire: %#v", response)
	}
	if proof := migrated.retired[legacyKey]; proof.LegacyUnbound ||
		proof.OwnershipRevision != historicalRevision {
		t.Fatalf("legacy retirement proof was not durably bound: %#v", proof)
	}
	if response := migrated.Handle(context.Background(), request(cfg, "confirm_jit_retirement", 4,
		legacyExact)); !response.OK || len(migrated.retired) != 0 {
		t.Fatalf("legacy retirement confirmation did not compact proof: %#v", response)
	}
	migrated.Close()
	if err := os.Remove(filepath.Join(cfg.StateDir, "issued-handles.json")); err != nil {
		t.Fatal(err)
	}
	if response := control.Handle(context.Background(), request(cfg, "delete_owned", sequence, `{}`)); !response.OK {
		t.Fatalf("delete failed: %#v", response)
	}
	if len(api.deleted) != 1 || len(api.sets) != 0 {
		t.Fatalf("exact owned set not deleted: ids=%#v sets=%#v", api.deleted, api.sets)
	}
}

func TestAmbiguousJITRemainsSingleAttemptAndCanBeRetired(t *testing.T) {
	root := t.TempDir()
	cfg := validRuntimeConfig(root)
	api := &fakeAPI{nextID: 40, sets: map[int64]crfgithub.ScaleSet{}, jitErr: errors.New("ambiguous JIT response")}
	control, err := New(cfg, api)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()

	if response := control.Handle(context.Background(), request(cfg, "apply_sessions", 1, "{}")); !response.OK {
		t.Fatalf("apply sessions failed: %#v", response)
	}
	if response := control.Handle(context.Background(), request(cfg, "publish_capacity_leases", 2,
		"{\"leases\":{\"python\":1}}")); !response.OK {
		t.Fatalf("publish leases failed: %#v", response)
	}

	deadline := time.Now().Add(3 * time.Second)
	sequence := uint64(3)
	var snapshot protocol.Snapshot
	for time.Now().Before(deadline) {
		response := control.Handle(context.Background(), request(cfg, "read_snapshot", sequence, "{}"))
		sequence++
		var ok bool
		snapshot, ok = response.Result.(protocol.Snapshot)
		if response.OK && ok && len(snapshot.Pools) == 1 && slices.Contains(snapshot.Pools[0].AcquiredHandles, int64(501)) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(snapshot.Pools) != 1 || !slices.Contains(snapshot.Pools[0].AcquiredHandles, int64(501)) {
		t.Fatalf("acquired handle never reached snapshot: %#v", snapshot)
	}

	payload := issueJITPayload(t, cfg, "python", snapshot.Pools[0].ScaleSetID, 501)
	first := control.Handle(context.Background(), request(cfg, "issue_jit", sequence, payload))
	sequence++
	if first.OK || first.Code != "jit_issue_ambiguous" || api.jitCalls != 1 {
		t.Fatalf("ambiguous JIT was not tombstoned: response=%#v calls=%d", first, api.jitCalls)
	}
	second := control.Handle(context.Background(), request(cfg, "issue_jit", sequence, payload))
	sequence++
	if second.OK || second.Code != "jit_issue_ambiguous" || api.jitCalls != 1 {
		t.Fatalf("ambiguous JIT was reissued: response=%#v calls=%d", second, api.jitCalls)
	}

	key := fmt.Sprintf("%d:%d", snapshot.Pools[0].ScaleSetID, 501)
	if control.issued[key].State != "issue_started" {
		t.Fatalf("ambiguous JIT tombstone missing: %#v", control.issued)
	}
	retirePayload := fmt.Sprintf(`{"pool_id":"python","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":501}`,
		snapshot.Pools[0].ScaleSetID, cfg.OwnershipRevision)
	if response := control.Handle(context.Background(), request(cfg, "retire_jit", sequence,
		retirePayload)); !response.OK {
		t.Fatalf("ambiguous JIT retirement failed: %#v", response)
	}
	if len(control.issued) != 0 {
		t.Fatalf("ambiguous JIT tombstone survived retirement: %#v", control.issued)
	}
}

func TestRetirementFailurePersistsConservativeProofForRestartRetry(t *testing.T) {
	root := t.TempDir()
	cfg := validRuntimeConfig(root)
	api := &fakeAPI{nextID: 40, sets: map[int64]crfgithub.ScaleSet{}}
	control, err := New(cfg, api)
	if err != nil {
		t.Fatal(err)
	}

	if response := control.Handle(context.Background(), request(cfg, "apply_sessions", 1, `{}`)); !response.OK {
		t.Fatalf("apply sessions failed: %#v", response)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	if err := control.stopSessions(ctx); err != nil {
		cancel()
		t.Fatal(err)
	}
	cancel()
	owned, err := control.ownership.Load()
	if err != nil || len(owned.Records) != 1 {
		t.Fatalf("ownership unavailable: state=%#v err=%v", owned, err)
	}
	scaleSetID := owned.Records[0].ScaleSetID
	failing := &retireFailPoller{}
	control.poller = failing
	issuePayload := issueJITPayload(t, cfg, "python", scaleSetID, 501)
	if response := control.Handle(context.Background(), request(cfg, "issue_jit", 2, issuePayload)); !response.OK {
		t.Fatalf("JIT issue failed: %#v", response)
	}
	descriptorPath := control.descriptorPath(scaleSetID, 501)
	retirePayload := fmt.Sprintf(`{"pool_id":"python","expected_scale_set_id":%d,"expected_ownership_revision":%q,"work_handle":501}`,
		scaleSetID, cfg.OwnershipRevision)
	response := control.Handle(context.Background(), request(cfg, "retire_jit", 3, retirePayload))
	if response.OK || response.Code != "jit_retirement_failed" || failing.retireCalls != 1 {
		t.Fatalf("retirement failure was not reported after durable proof: response=%#v calls=%d",
			response, failing.retireCalls)
	}
	key := fmt.Sprintf("%d:%d", scaleSetID, 501)
	if _, ok := control.retired[key]; !ok {
		t.Fatalf("retirement failure lost conservative proof: %#v", control.retired)
	}
	if _, ok := control.issued[key]; !ok {
		t.Fatalf("retirement failure prematurely removed issued record: %#v", control.issued)
	}
	if _, err := os.Stat(descriptorPath); err != nil {
		t.Fatalf("retirement failure prematurely removed descriptor: %v", err)
	}
	control.Close()

	restarted, err := New(cfg, api)
	if err != nil {
		t.Fatalf("restart with pending retirement failed: %v", err)
	}
	defer restarted.Close()
	restarted.poller = &consumeFailPoller{}
	if _, ok := restarted.retired[key]; !ok {
		t.Fatalf("restart lost durable retirement proof: %#v", restarted.retired)
	}
	if _, ok := restarted.issued[key]; !ok {
		t.Fatalf("restart lost conservative issued record: %#v", restarted.issued)
	}
	api.removeErr = errors.New("github unavailable")
	if response := restarted.Handle(context.Background(), request(cfg, "retire_jit", 1,
		retirePayload)); response.OK || response.Code != "jit_runner_delete_failed" {
		t.Fatalf("runner deletion failure was not retained for retry: %#v", response)
	}
	if _, ok := restarted.retired[key]; !ok {
		t.Fatalf("runner deletion failure removed retirement proof: %#v", restarted.retired)
	}
	pending := restarted.Handle(context.Background(), request(cfg, "read_jit_state", 2, `{}`))
	if !pending.OK || !strings.Contains(fmt.Sprint(pending.Result), "retirement_started") {
		t.Fatalf("runner deletion failure was exposed as completed retirement: %#v", pending)
	}
	if _, ok := restarted.issued[key]; !ok {
		t.Fatalf("runner deletion failure removed issued record: %#v", restarted.issued)
	}
	if _, err := os.Stat(restarted.runnerIDPath(scaleSetID, 501)); err != nil {
		t.Fatalf("runner deletion failure removed retry identity: %v", err)
	}
	api.removeErr = nil
	if response := restarted.Handle(context.Background(), request(cfg, "retire_jit", 3, retirePayload)); !response.OK {
		t.Fatalf("retirement retry after restart failed: %#v", response)
	}
	if _, ok := restarted.retired[key]; !ok {
		t.Fatalf("successful retry removed proof before confirmation: %#v", restarted.retired)
	}
	if _, ok := restarted.issued[key]; ok {
		t.Fatalf("successful retry retained issued record: %#v", restarted.issued)
	}
	if _, err := os.Stat(descriptorPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("successful retry retained descriptor: %v", err)
	}
	if response := restarted.Handle(context.Background(), request(cfg, "confirm_jit_retirement", 4,
		retirePayload)); !response.OK || len(restarted.retired) != 0 {
		t.Fatalf("confirmation did not compact recovered proof: response=%#v retired=%#v",
			response, restarted.retired)
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

func TestRepeatedEligibilityReassertionPreservesMatchingSessions(t *testing.T) {
	cfg := validRuntimeConfig(t.TempDir())
	api := &fakeAPI{nextID: 3, sets: map[int64]crfgithub.ScaleSet{}}
	control, err := New(cfg, api)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()

	first := control.Handle(context.Background(), request(cfg, "apply_sessions", 1, `{"eligible":true}`))
	if !first.OK {
		t.Fatalf("initial session application failed: %#v", first)
	}
	originalSupervisor, originalPoller := control.super, control.poller

	second := control.Handle(context.Background(), request(cfg, "apply_sessions", 2, `{"eligible":true}`))
	if !second.OK {
		t.Fatalf("eligibility reassertion failed: %#v", second)
	}
	if control.super != originalSupervisor || control.poller != originalPoller {
		t.Fatal("unchanged eligibility reassertion restarted healthy sessions")
	}
}

func TestStopSessionsClosesPollerAfterSupervisorError(t *testing.T) {
	poller := &closeTrackingPoller{}
	done := make(chan error, 1)
	done <- errors.New("supervisor failed")
	control := &Control{poller: poller, superDone: done}
	err := control.stopSessions(context.Background())
	if err == nil || !strings.Contains(err.Error(), "join_previous_supervisor") {
		t.Fatalf("supervisor error was lost: %v", err)
	}
	if poller.closed != 1 || control.poller != nil || control.superDone != nil {
		t.Fatalf("completed supervisor did not release sessions: closed=%d poller=%#v done=%#v",
			poller.closed, control.poller, control.superDone)
	}
}

func TestStopSessionsRetainsPollerWhenCloseFails(t *testing.T) {
	poller := &closeTrackingPoller{err: errors.New("close failed")}
	control := &Control{poller: poller}
	err := control.stopSessions(context.Background())
	if err == nil || !strings.Contains(err.Error(), "close_previous_sessions") {
		t.Fatalf("close error was lost: %v", err)
	}
	if poller.closed != 1 || control.poller != poller {
		t.Fatalf("failed close was not retryable: closed=%d poller=%#v", poller.closed, control.poller)
	}
}

func TestDecodePayloadRejectsEveryTrailingByteExceptWhitespace(t *testing.T) {
	var payload struct {
		Value int `json:"value"`
	}
	if err := decodePayload([]byte("{\"value\":1} \n\t"), &payload); err != nil || payload.Value != 1 {
		t.Fatalf("valid payload rejected: value=%d err=%v", payload.Value, err)
	}
	for _, suffix := range []string{"{}", "garbage", "["} {
		if err := decodePayload([]byte("{\"value\":1}"+suffix), &payload); err == nil {
			t.Fatalf("accepted trailing payload %q", suffix)
		}
	}
}

func TestRuntimeConfigRejectsAmbiguousPoolLabels(t *testing.T) {
	base := validRuntimeConfig(t.TempDir())
	tests := []struct {
		name  string
		pools []PoolConfig
	}{
		{"invalid pool id", []PoolConfig{{ID: "Python", RoutingLabel: "ci-pool-python", Labels: []string{"ci-pool-python"}}}},
		{"duplicate routing", []PoolConfig{
			{ID: "python", RoutingLabel: "ci-pool-python", Labels: []string{"ci-pool-python"}},
			{ID: "rust", RoutingLabel: "ci-pool-python", Labels: []string{"ci-pool-python"}},
		}},
		{"missing routing", []PoolConfig{{ID: "python", RoutingLabel: "ci-pool-python", Labels: []string{"self-hosted"}}}},
		{"duplicate labels", []PoolConfig{{ID: "python", RoutingLabel: "ci-pool-python", Labels: []string{"ci-pool-python", "ci-pool-python"}}}},
		{"foreign routing label", []PoolConfig{
			{ID: "python", RoutingLabel: "ci-pool-python", Labels: []string{"ci-pool-python", "ci-pool-rust"}},
			{ID: "rust", RoutingLabel: "ci-pool-rust", Labels: []string{"ci-pool-rust"}},
		}},
		{"uppercase label", []PoolConfig{{ID: "python", RoutingLabel: "ci-pool-python", Labels: []string{"ci-pool-python", "Linux"}}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := base
			cfg.Pools = tt.pools
			if err := cfg.Validate(); err == nil {
				t.Fatalf("accepted invalid pools: %#v", tt.pools)
			}
		})
	}
}

func TestIssueJITRollsBackDurableReservationWhenConsumeLosesRace(t *testing.T) {
	root := t.TempDir()
	cfg := validRuntimeConfig(root)
	api := &fakeAPI{nextID: 40, sets: map[int64]crfgithub.ScaleSet{}}
	control, err := New(cfg, api)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	if got := control.Handle(context.Background(), request(cfg, "apply_sessions", 1, `{}`)); !got.OK {
		t.Fatalf("apply sessions failed: %#v", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	if err := control.stopSessions(ctx); err != nil {
		cancel()
		t.Fatal(err)
	}
	cancel()
	control.poller = &consumeFailPoller{}
	owned, err := control.ownership.Load()
	if err != nil || len(owned.Records) != 1 {
		t.Fatalf("ownership unavailable: state=%#v err=%v", owned, err)
	}
	response := control.Handle(context.Background(), request(cfg, "issue_jit", 2,
		issueJITPayload(t, cfg, "python", owned.Records[0].ScaleSetID, 501)))
	if response.OK || response.Code != "work_handle_not_available_after_reservation" {
		t.Fatalf("consume race was not reported: %#v", response)
	}
	if len(control.issued) != 0 || api.jitCalls != 0 {
		t.Fatalf("failed reservation leaked state or issued JIT: issued=%#v calls=%d", control.issued, api.jitCalls)
	}
	data, err := os.ReadFile(filepath.Join(cfg.StateDir, "issued-handles.json"))
	if err != nil || !strings.Contains(string(data), `"records":{}`) {
		t.Fatalf("failed reservation tombstone remained durable: %q err=%v", data, err)
	}
}

func TestIssueJITRejectsScaleSetRemapBeforeHandleOrGitHub(t *testing.T) {
	root := t.TempDir()
	cfg := validRuntimeConfig(root)
	api := &fakeAPI{nextID: 40, sets: map[int64]crfgithub.ScaleSet{}}
	control, err := New(cfg, api)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	if got := control.Handle(context.Background(), request(cfg, "apply_sessions", 1, `{}`)); !got.OK {
		t.Fatalf("apply sessions failed: %#v", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	if err := control.stopSessions(ctx); err != nil {
		cancel()
		t.Fatal(err)
	}
	cancel()
	poller := &fencePoller{}
	control.poller = poller
	owned, err := control.ownership.Load()
	if err != nil || len(owned.Records) != 1 {
		t.Fatalf("ownership unavailable: state=%#v err=%v", owned, err)
	}

	response := control.Handle(context.Background(), request(cfg, "issue_jit", 2,
		issueJITPayload(t, cfg, "python", owned.Records[0].ScaleSetID+1, 501)))
	if response.OK || response.Code != "scale_set_mismatch" {
		t.Fatalf("scale-set remap was not fenced: %#v", response)
	}
	if poller.hasCalls != 0 || poller.consumeCalls != 0 || api.jitCalls != 0 || len(control.issued) != 0 {
		t.Fatalf("fenced request reached mutable boundary: poller=%#v calls=%d issued=%#v",
			poller, api.jitCalls, control.issued)
	}

	identityDrift := strings.Replace(
		issueJITPayload(t, cfg, "python", owned.Records[0].ScaleSetID, 501),
		cfg.OwnershipRevision, strings.Repeat("c", 64), 1)
	response = control.Handle(context.Background(), request(cfg, "issue_jit", 3, identityDrift))
	if response.OK || response.Code != "ownership_identity_mismatch" {
		t.Fatalf("ownership drift was not fenced: %#v", response)
	}
	if poller.hasCalls != 0 || poller.consumeCalls != 0 || api.jitCalls != 0 || len(control.issued) != 0 {
		t.Fatalf("ownership-fenced request reached mutable boundary: poller=%#v calls=%d issued=%#v",
			poller, api.jitCalls, control.issued)
	}
}

func issueJITPayload(t *testing.T, cfg RuntimeConfig, poolID string, scaleSetID, workHandle int64) string {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"pool_id":                     poolID,
		"expected_scale_set_id":       scaleSetID,
		"expected_ownership_revision": cfg.OwnershipRevision,
		"work_handle":                 workHandle,
		"runner_name":                 "runner-501",
		"work_folder":                 "_work",
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(payload)
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

func TestWriteRecordStateRejectsOversizedEncodingBeforeWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "issued-handles.json")
	records := make(map[string]issuedRecord, 50_000)
	poolID := "p" + strings.Repeat("x", 126)
	revision := strings.Repeat("a", 64)
	for handle := int64(1); handle <= 50_000; handle++ {
		scaleSetID := handle + 100_000
		key := fmt.Sprintf("%d:%d", scaleSetID, handle)
		records[key] = issuedRecord{
			State:             "issued",
			PoolID:            poolID,
			ScaleSetID:        scaleSetID,
			OwnershipRevision: revision,
			WorkHandle:        handle,
		}
	}

	if err := writeRecordState(path, records); err == nil || err.Error() != "jit_state_encoded_size_exceeded" {
		t.Fatalf("oversized encoded state was not rejected: %v", err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("oversized state reached durable path: %v", err)
	}
}
