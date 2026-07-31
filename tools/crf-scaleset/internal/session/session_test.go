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

	crfgithub "github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/journal"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/supervisor"
)

type fakeAPI struct {
	mu           sync.Mutex
	batch        crfgithub.MessageBatch
	acquire      crfgithub.AcquireResult
	acquireErr   error
	sessionCalls int
	acquireCalls int
	acquireIDs   []int64
	ackCalls     int
	ackSawCommit bool
	lastMessage  int64
	store        journal.Store
	started      chan int64
	block        chan struct{}
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
func (f *fakeAPI) GetMessage(_ context.Context, session crfgithub.Session, lastMessage int64, _ int) (crfgithub.MessageBatch, error) {
	f.mu.Lock()
	f.lastMessage = lastMessage
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
		if key.MessageID == id && entry.Phase == "ack_pending" {
			f.ackSawCommit = true
		}
	}
	return nil
}
func (*fakeAPI) GenerateJitRunnerConfig(context.Context, int64, crfgithub.JITRequest) ([]byte, error) {
	return nil, nil
}

func TestPollAcquiresOnlyAvailableJobsAndOffersAssignedJobs(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store,
		batch: crfgithub.MessageBatch{MessageID: 9, Statistics: &crfgithub.Statistics{TotalAssignedJobs: 3},
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
	if result.AssignedJobs != 3 || result.MessageID != 9 ||
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

func TestAcquireFailureIsNotAcknowledged(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{MessageID: 10,
		Statistics: &crfgithub.Statistics{TotalAssignedJobs: 1}, Available: []int64{201}},
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

func TestAcquireStartedAvailableJobRemainsFailClosed(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay.jsonl")}
	entry := journal.Entry{ScaleSetID: 7, SessionID: "old-session", MessageID: 33,
		Phase: "acquire_started", AssignedCount: 0, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
	if err := store.Append(entry); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store, batch: crfgithub.MessageBatch{MessageID: 33,
		Statistics: &crfgithub.Statistics{}, Available: []int64{801}}}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := poller.Poll(context.Background(),
		supervisor.Pool{ID: "python", ScaleSetID: 7}, 1); !errors.Is(err, ErrAmbiguousAcquire) {
		t.Fatalf("ambiguous available-job acquisition was not rejected: %v", err)
	}
	if api.acquireCalls != 0 || api.ackCalls != 0 {
		t.Fatalf("ambiguous acquisition caused a side effect: %#v", api)
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
