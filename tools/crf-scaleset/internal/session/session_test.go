package session

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/journal"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/supervisor"
)

type fakeAPI struct {
	mu                 sync.Mutex
	batch              crfgithub.MessageBatch
	acquire            crfgithub.AcquireResult
	acquireErr         error
	sessionCalls       int
	acquireCalls       int
	acquireIDs         []int64
	ackCalls           int
	ackSawCommit       bool
	ackErr             error
	closeCalls         int
	lastMessage        int64
	messageCapacity    int
	acquirable         []crfgithub.AvailableJob
	acquirableErr      error
	acquirableCalls    int
	acquirableDeadline bool
	store              journal.Store
	started            chan int64
	block              chan struct{}
}

func (*fakeAPI) CreateRunnerScaleSet(context.Context, crfgithub.CreateSpec) (crfgithub.ScaleSet, error) {
	return crfgithub.ScaleSet{}, nil
}
func (*fakeAPI) GetRunnerScaleSet(context.Context, int64) (crfgithub.ScaleSet, error) {
	return crfgithub.ScaleSet{}, nil
}
func (*fakeAPI) GetRunnerScaleSetByName(context.Context, int64, string) (crfgithub.ScaleSet, error) {
	return crfgithub.ScaleSet{}, nil
}
func (*fakeAPI) UpdateRunnerScaleSet(context.Context, int64, crfgithub.UpdateSpec) (crfgithub.ScaleSet, error) {
	return crfgithub.ScaleSet{}, nil
}
func (*fakeAPI) DeleteRunnerScaleSet(context.Context, int64) error { return nil }
func (*fakeAPI) GetRunnerGroupByName(context.Context, string) (crfgithub.RunnerGroup, error) {
	return crfgithub.RunnerGroup{}, nil
}
func (f *fakeAPI) CreateMessageSession(_ context.Context, id int64) (crfgithub.Session, error) {
	f.mu.Lock()
	f.sessionCalls++
	f.mu.Unlock()
	return crfgithub.Session{ScaleSetID: id, ID: "session-1"}, nil
}
func (f *fakeAPI) GetMessage(_ context.Context, session crfgithub.Session, lastMessage int64, capacity int) (crfgithub.MessageBatch, error) {
	f.mu.Lock()
	f.lastMessage = lastMessage
	f.messageCapacity = capacity
	batch := f.batch
	f.mu.Unlock()
	if f.started != nil {
		f.started <- session.ScaleSetID
	}
	if f.block != nil {
		<-f.block
	}
	return batch, nil
}
func (f *fakeAPI) GetAcquirableJobs(ctx context.Context, _ int64) ([]crfgithub.AvailableJob, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.acquirableCalls++
	_, f.acquirableDeadline = ctx.Deadline()
	return slices.Clone(f.acquirable), f.acquirableErr
}
func (f *fakeAPI) AcquireJobs(_ context.Context, _ crfgithub.Session, req crfgithub.AcquireRequest) (crfgithub.AcquireResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.acquireCalls++
	f.acquireIDs = slices.Clone(req.RequestIDs)
	return f.acquire, f.acquireErr
}
func (f *fakeAPI) AcknowledgeMessage(_ context.Context, _ crfgithub.Session, id int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ackCalls++
	replayed, _ := f.store.Replay()
	for key, entry := range replayed {
		if key.MessageID == id && (entry.Phase == "committed" || entry.Phase == "ack_pending") {
			f.ackSawCommit = true
		}
	}
	return f.ackErr
}
func (*fakeAPI) GenerateJitRunnerConfig(context.Context, int64, crfgithub.JITRequest) ([]byte, error) {
	return nil, nil
}
func (f *fakeAPI) CloseMessageSession(_ context.Context, _ crfgithub.Session) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closeCalls++
	return nil
}

func TestPollAcquiresOnlyRankedVisibleSubset(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	now := time.Now().UTC()
	longOne := testJob(101, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-3*time.Minute))
	longTwo := testJob(102, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-2*time.Minute))
	quick := testJob(103, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", now.Add(-time.Minute))
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{
		MessageID: 12, Statistics: &crfgithub.Statistics{TotalAssignedJobs: 0},
		Available: []int64{101, 102, 103}, AvailableJobs: []crfgithub.AvailableJob{longOne, longTwo, quick},
	}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	poller.runtimes[runtimeKey("build", longOne.Metadata)] = runtimeEstimate{duration: 20 * time.Minute, samples: 10}
	poller.runtimes[runtimeKey("build", quick.Metadata)] = runtimeEstimate{duration: 30 * time.Second, samples: 10}

	if _, err := poller.Poll(context.Background(), supervisor.Pool{ID: "build", ScaleSetID: 7}, 2); err != nil {
		t.Fatal(err)
	}
	if api.messageCapacity != 2 {
		t.Fatalf("poll inflated GitHub max capacity for lookahead: %d", api.messageCapacity)
	}
	if !slices.Equal(api.acquireIDs, []int64{103, 101}) {
		t.Fatalf("poll did not acquire only the ranked visible subset: %v", api.acquireIDs)
	}
}

func TestPollRanksHiddenAcquirableBacklog(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	now := time.Now().UTC()
	longVisible := testJob(101, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-2*time.Minute))
	quickHidden := testJob(102, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", now.Add(-time.Minute))
	longHidden := testJob(103, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-30*time.Second))
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{
		MessageID: 14, Statistics: &crfgithub.Statistics{TotalAvailableJobs: 3, TotalAssignedJobs: 0},
		Available: []int64{101}, AvailableJobs: []crfgithub.AvailableJob{longVisible},
	}, acquirable: []crfgithub.AvailableJob{longVisible, quickHidden, longHidden}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	poller.runtimes[runtimeKey("build", longVisible.Metadata)] = runtimeEstimate{duration: 20 * time.Minute, samples: 10}
	poller.runtimes[runtimeKey("build", quickHidden.Metadata)] = runtimeEstimate{duration: 30 * time.Second, samples: 10}

	if _, err := poller.Poll(context.Background(), supervisor.Pool{ID: "build", ScaleSetID: 7}, 1); err != nil {
		t.Fatal(err)
	}
	if api.messageCapacity != 1 {
		t.Fatalf("deep lookahead inflated GitHub max capacity: %d", api.messageCapacity)
	}
	if api.acquirableCalls != 1 || !api.acquirableDeadline {
		t.Fatalf("hidden backlog lookup was not bounded: calls=%d deadline=%v", api.acquirableCalls, api.acquirableDeadline)
	}
	if !slices.Equal(api.acquireIDs, []int64{102}) {
		t.Fatalf("hidden quick job was not acquired ahead of visible long work: %v", api.acquireIDs)
	}
}

func TestPollAcquirableLookupFailureFallsBackToVisibleBatch(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	visible := testJob(201, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", time.Now().UTC())
	api := &fakeAPI{store: store, acquirableErr: errors.New("lookup failed"), batch: crfgithub.MessageBatch{
		MessageID: 15, Statistics: &crfgithub.Statistics{TotalAvailableJobs: 2, TotalAssignedJobs: 0},
		Available: []int64{201}, AvailableJobs: []crfgithub.AvailableJob{visible},
	}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(), supervisor.Pool{ID: "build", ScaleSetID: 7}, 1); err != nil {
		t.Fatalf("optional lookahead failure blocked pool: %v", err)
	}
	if api.acquirableCalls != 1 || !slices.Equal(api.acquireIDs, []int64{201}) {
		t.Fatalf("visible fallback failed: calls=%d acquired=%v", api.acquirableCalls, api.acquireIDs)
	}
}

func TestPollSkipsAcquirableLookupWhenPoolIsFull(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	visible := testJob(251, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", time.Now().UTC())
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{
		MessageID: 18, Statistics: &crfgithub.Statistics{TotalAvailableJobs: 10, TotalAssignedJobs: 2},
		Available: []int64{251}, AvailableJobs: []crfgithub.AvailableJob{visible},
	}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(), supervisor.Pool{ID: "build", ScaleSetID: 7}, 2); err != nil {
		t.Fatal(err)
	}
	if api.acquirableCalls != 0 || api.acquireCalls != 0 {
		t.Fatalf("full pool performed unnecessary admission work: lookups=%d acquires=%d", api.acquirableCalls, api.acquireCalls)
	}
}

func TestPollSkipsAcquirableLookupWhenVisibleBatchCoversQueue(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	visible := testJob(301, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", time.Now().UTC())
	hidden := testJob(302, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", time.Now().UTC())
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{
		MessageID: 16, Statistics: &crfgithub.Statistics{TotalAvailableJobs: 1, TotalAssignedJobs: 0},
		Available: []int64{301}, AvailableJobs: []crfgithub.AvailableJob{visible},
	}, acquirable: []crfgithub.AvailableJob{hidden}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(), supervisor.Pool{ID: "build", ScaleSetID: 7}, 1); err != nil {
		t.Fatal(err)
	}
	if api.acquirableCalls != 0 || !slices.Equal(api.acquireIDs, []int64{301}) {
		t.Fatalf("covered visible queue caused unnecessary lookahead: calls=%d acquired=%v", api.acquirableCalls, api.acquireIDs)
	}
}

func TestPollEmptyAcquirableRaceKeepsVisibleCandidate(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	visible := testJob(401, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", time.Now().UTC())
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{
		MessageID: 17, Statistics: &crfgithub.Statistics{TotalAvailableJobs: 2, TotalAssignedJobs: 0},
		Available: []int64{401}, AvailableJobs: []crfgithub.AvailableJob{visible},
	}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(), supervisor.Pool{ID: "build", ScaleSetID: 7}, 1); err != nil {
		t.Fatal(err)
	}
	if api.acquirableCalls != 1 || !slices.Equal(api.acquireIDs, []int64{401}) {
		t.Fatalf("empty lookahead erased visible candidate: calls=%d acquired=%v", api.acquirableCalls, api.acquireIDs)
	}
}

func TestPollAcquiresOnlyAvailableJobsAndOffersAssignedJobs(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store,
		batch: crfgithub.MessageBatch{MessageID: 9, Statistics: &crfgithub.Statistics{TotalAssignedJobs: 0},
			Available: []int64{101, 102}, AssignedHandles: []int64{501, 502}},
		acquire: crfgithub.AcquireResult{AcquiredIDs: []int64{101, 102}},
	}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	result, err := poller.Poll(context.Background(), supervisor.Pool{ID: "python", ScaleSetID: 7}, 2)
	if err != nil {
		t.Fatal(err)
	}
	if result.AssignedJobs != 0 || result.MessageID != 9 ||
		!slices.Equal(result.AcquiredHandles, []int64{501, 502}) {
		t.Fatalf("unexpected poll result: %#v", result)
	}
	if !api.ackSawCommit || api.ackCalls != 1 || api.acquireCalls != 1 || api.sessionCalls != 1 {
		t.Fatalf("ordering/calls: %#v", api)
	}
	if !slices.Equal(api.acquireIDs, []int64{101, 102}) {
		t.Fatalf("wrong jobs acquired: %#v", api.acquireIDs)
	}
	replayed, err := store.Replay()
	if err != nil || replayed[journal.Key{ScaleSetID: 7, MessageID: 9}].Phase != "acked" {
		t.Fatalf("journal not acked: %#v err=%v", replayed, err)
	}
}

func TestCompletedRuntimeLearningWaitsForAckAndIsNotDuplicatedOnRedelivery(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	metadata := testJob(301, "soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", time.Now().UTC()).Metadata
	completed := crfgithub.CompletedJob{Metadata: metadata,
		RunnerAssignTime: time.Unix(100, 0), FinishTime: time.Unix(140, 0)}
	api := &fakeAPI{store: store, ackErr: errors.New("ack failed"), batch: crfgithub.MessageBatch{
		MessageID: 13, Statistics: &crfgithub.Statistics{TotalAssignedJobs: 0},
		CompletedJobs: []crfgithub.CompletedJob{completed},
	}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	pool := supervisor.Pool{ID: "build", ScaleSetID: 7}
	if _, err := poller.Poll(context.Background(), pool, 1); err == nil {
		t.Fatal("ack failure was accepted")
	}
	key := runtimeKey("build", metadata)
	if _, learned := poller.runtimes[key]; learned {
		t.Fatal("completion influenced runtime hints before message acknowledgement")
	}
	api.mu.Lock()
	api.ackErr = nil
	api.mu.Unlock()
	if _, err := poller.Poll(context.Background(), pool, 1); err != nil {
		t.Fatal(err)
	}
	if estimate := poller.runtimes[key]; estimate.samples != 1 || estimate.duration != 40*time.Second {
		t.Fatalf("acknowledged redelivery was not learned exactly once: %#v", estimate)
	}
}

func TestAcquireFailureIsNotAcknowledged(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{MessageID: 10,
		Statistics: &crfgithub.Statistics{TotalAssignedJobs: 0}, Available: []int64{201}},
		acquireErr: errors.New("timeout")}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(), supervisor.Pool{ID: "rust", ScaleSetID: 8}, 1); err == nil {
		t.Fatal("acquire failure was accepted")
	}
	if api.ackCalls != 0 {
		t.Fatal("failed acquisition was acknowledged")
	}
	replayed, _ := store.Replay()
	if replayed[journal.Key{ScaleSetID: 8, MessageID: 10}].Phase != "acquire_started" {
		t.Fatalf("unexpected phase: %#v", replayed[journal.Key{ScaleSetID: 8, MessageID: 10}])
	}
}

func TestRedeliveredCommittedMessageAcknowledgesWithoutReacquire(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	entry := journal.Entry{ScaleSetID: 12, SessionID: "session-1", MessageID: 22, Phase: "committed",
		AssignedCount: 1, AcquiredHandles: []int64{301}, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	if err := store.Append(entry); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{MessageID: 22,
		Statistics: &crfgithub.Statistics{TotalAssignedJobs: 1}, AssignedHandles: []int64{301}}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	result, err := poller.Poll(context.Background(), supervisor.Pool{ID: "go", ScaleSetID: 12}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if api.acquireCalls != 0 || api.ackCalls != 1 || !slices.Equal(result.AcquiredHandles, []int64{301}) {
		t.Fatalf("redelivery was not replay-safe: result=%#v api=%#v", result, api)
	}
}

func TestDirectJobAssignmentDoesNotCallAcquire(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{MessageID: 31,
		Statistics: &crfgithub.Statistics{TotalAssignedJobs: 1}, AssignedHandles: []int64{701}}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	result, err := poller.Poll(context.Background(), supervisor.Pool{ID: "python", ScaleSetID: 7}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if api.acquireCalls != 0 || api.ackCalls != 1 ||
		!slices.Equal(result.AcquiredHandles, []int64{701}) {
		t.Fatalf("direct assignment was mishandled: result=%#v api=%#v", result, api)
	}
}

func TestLegacyAcquireStartedAssignmentRecoversWithoutAcquire(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	entry := journal.Entry{ScaleSetID: 7, SessionID: "old-session", MessageID: 32,
		Phase: "acquire_started", AssignedCount: 1, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	if err := store.Append(entry); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{MessageID: 32,
		Statistics: &crfgithub.Statistics{TotalAssignedJobs: 1}, AssignedHandles: []int64{702}}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	result, err := poller.Poll(context.Background(), supervisor.Pool{ID: "python", ScaleSetID: 7}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if api.acquireCalls != 0 || api.ackCalls != 1 ||
		!slices.Equal(result.AcquiredHandles, []int64{702}) {
		t.Fatalf("legacy direct assignment did not recover safely: result=%#v api=%#v", result, api)
	}
	replayed, err := store.Replay()
	if err != nil || replayed[entry.Key()].Phase != "acked" {
		t.Fatalf("legacy entry was not acknowledged: replay=%#v err=%v", replayed, err)
	}
}

func TestAcquireStartedClosesSessionWithoutRetryingAvailableJobs(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	entry := journal.Entry{ScaleSetID: 7, SessionID: "old-session", MessageID: 33,
		Phase: "acquire_started", AssignedCount: 0, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	if err := store.Append(entry); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{MessageID: 33,
		Statistics: &crfgithub.Statistics{}, Available: []int64{801}},
		acquire: crfgithub.AcquireResult{AcquiredIDs: []int64{801}}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(),
		supervisor.Pool{ID: "python", ScaleSetID: 7}, 1); !errors.Is(err, ErrAmbiguousAcquire) {
		t.Fatalf("ambiguous acquisition did not reset its session: %v", err)
	}
	if api.acquireCalls != 0 || api.ackCalls != 0 || api.closeCalls != 1 {
		t.Fatalf("ambiguous redelivery made unsafe progress: %#v", api)
	}
	replayed, err := store.Replay()
	if err != nil || len(replayed) != 0 {
		t.Fatalf("reset session retained ambiguous replay: replay=%#v err=%v", replayed, err)
	}
}

func TestNonzeroMessageWithoutStatisticsMakesNoProgress(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{
		MessageID: 44, Available: []int64{901}}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(),
		supervisor.Pool{ID: "python", ScaleSetID: 7}, 1); err == nil {
		t.Fatal("message without authoritative statistics was accepted")
	}
	replayed, replayErr := store.Replay()
	if replayErr != nil || len(replayed) != 0 || api.acquireCalls != 0 || api.ackCalls != 0 {
		t.Fatalf("malformed message changed state: replay=%#v api=%#v err=%v",
			replayed, api, replayErr)
	}
}

func TestPollResumesAfterLastAcknowledgedMessage(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	entry := journal.Entry{ScaleSetID: 12, SessionID: "old-session", MessageID: 22, Phase: "acked",
		AssignedCount: 1, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	if err := store.Append(entry); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(), supervisor.Pool{ID: "go", ScaleSetID: 12}, 1); err != nil {
		t.Fatal(err)
	}
	if api.lastMessage != 22 {
		t.Fatalf("resumed from message %d, want 22", api.lastMessage)
	}
}

func TestRestartDoesNotReofferPersistedConsumedHandle(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	entry := journal.Entry{ScaleSetID: 12, SessionID: "old-session", MessageID: 22, Phase: "acked",
		AssignedCount: 1, AcquiredHandles: []int64{301}, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	if err := store.Append(entry); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64), ConsumedHandles: map[string]bool{"12:301": true}})
	if err != nil {
		t.Fatal(err)
	}
	result, err := poller.Poll(context.Background(), supervisor.Pool{ID: "go", ScaleSetID: 12}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(result.AcquiredHandles, int64(301)) {
		t.Fatalf("consumed handle was reoffered after restart: %#v", result)
	}
}

func TestRestartDropsPendingHandlesWhenLatestAssignedCountIsZero(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	for _, entry := range []journal.Entry{
		{ScaleSetID: 12, SessionID: "old-session", MessageID: 22, Phase: "acked",
			AssignedCount: 1, AcquiredHandles: []int64{301}, ConfigRevision: strings.Repeat("a", 64),
			OwnershipRevision: strings.Repeat("b", 64)},
		{ScaleSetID: 12, SessionID: "old-session", MessageID: 23, Phase: "acked",
			AssignedCount: 0, ConfigRevision: strings.Repeat("a", 64),
			OwnershipRevision: strings.Repeat("b", 64)},
	} {
		if err := store.Append(entry); err != nil {
			t.Fatal(err)
		}
	}
	api := &fakeAPI{store: store}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	result, err := poller.Poll(context.Background(), supervisor.Pool{ID: "go", ScaleSetID: 12}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.AcquiredHandles) != 0 {
		t.Fatalf("completed work remained pending after restart: %#v", result.AcquiredHandles)
	}
}

func TestIdleCapacityCreatesDurableJSONSafeWorkHandle(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	result, err := poller.Poll(context.Background(), supervisor.Pool{ID: "go", ScaleSetID: 12}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.AcquiredHandles) != 1 || result.AcquiredHandles[0] <= 0 ||
		result.AcquiredHandles[0] > maxJSONSafeInteger {
		t.Fatalf("invalid idle-capacity handle: %#v", result.AcquiredHandles)
	}
	replayed, err := store.Replay()
	capacity := replayed[journal.Key{ScaleSetID: 12, MessageID: 0}]
	if err != nil || capacity.Phase != "acked" ||
		!slices.Equal(capacity.AcquiredHandles, result.AcquiredHandles) {
		t.Fatalf("capacity handle was not durable: entry=%#v err=%v", capacity, err)
	}
}

func TestConsumedIdleCapacityHandleIsNotReofferedAfterRestart(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store}
	cfg := Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	first, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	initial, err := first.Poll(context.Background(), supervisor.Pool{ID: "go", ScaleSetID: 12}, 1)
	if err != nil {
		t.Fatal(err)
	}
	old := initial.AcquiredHandles[0]
	cfg.ConsumedHandles = map[string]bool{handleKey(12, old): true}
	restarted, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	after, err := restarted.Poll(context.Background(), supervisor.Pool{ID: "go", ScaleSetID: 12}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(after.AcquiredHandles) != 1 || after.AcquiredHandles[0] == old {
		t.Fatalf("consumed capacity handle was reused: old=%d after=%#v", old, after.AcquiredHandles)
	}
}

func TestCompletionRemovesItsPendingHandle(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	entry := journal.Entry{ScaleSetID: 12, SessionID: "old-session", MessageID: 22, Phase: "acked",
		AssignedCount: 1, AcquiredHandles: []int64{301}, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	if err := store.Append(entry); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{MessageID: 23,
		Statistics:      &crfgithub.Statistics{TotalAssignedJobs: 1},
		AssignedHandles: []int64{302}, ReleasedHandles: []int64{301}}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	result, err := poller.Poll(context.Background(), supervisor.Pool{ID: "go", ScaleSetID: 12}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(result.AcquiredHandles, []int64{302}) {
		t.Fatalf("completed handle was retained or replacement lost: %#v", result.AcquiredHandles)
	}
}

func TestRetireHandleCompactsDurableReplayState(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	entry := journal.Entry{ScaleSetID: 12, SessionID: "old-session", MessageID: 22, Phase: "acked",
		AssignedCount: 1, AcquiredHandles: []int64{301, 302}, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	if err := store.Append(entry); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if err := poller.RetireHandle(12, 301); err != nil {
		t.Fatal(err)
	}
	replayed, err := store.Replay()
	if err != nil {
		t.Fatal(err)
	}
	got := replayed[entry.Key()]
	if !slices.Equal(got.AcquiredHandles, []int64{302}) || poller.HasHandle(12, 301) {
		t.Fatalf("retired handle survived compaction: %#v", got)
	}
	if poller.consumed[handleKey(12, 301)] {
		t.Fatal("retired handle leaked in the in-memory consumed set")
	}
}

func TestDifferentScaleSetsPollConcurrently(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	started := make(chan int64, 2)
	block := make(chan struct{})
	defer close(block)
	api := &fakeAPI{store: store, started: started, block: block}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{7, 8} {
		go func() {
			_, _ = poller.Poll(context.Background(), supervisor.Pool{ID: "pool", ScaleSetID: id}, 0)
		}()
	}
	for range 2 {
		select {
		case <-started:
		case <-time.After(250 * time.Millisecond):
			t.Fatal("different pool poll was serialized behind another pool")
		}
	}
}

func TestCapacityChangeReturnsHandleWithoutWaitingForLongPoll(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	poller.setAdvertised(7, 0)
	api.block = make(chan struct{})
	done := make(chan supervisor.PollResult, 1)
	go func() {
		result, _ := poller.Poll(context.Background(),
			supervisor.Pool{ID: "python", ScaleSetID: 7}, 1)
		done <- result
	}()
	select {
	case result := <-done:
		if len(result.AcquiredHandles) != 1 {
			t.Fatalf("capacity change did not immediately advertise a handle: %#v", result)
		}
	case <-time.After(250 * time.Millisecond):
		close(api.block)
		t.Fatal("capacity change waited for the GitHub long poll")
	}
	close(api.block)
}
