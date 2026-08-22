package session

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/journal"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/supervisor"
)

func fastLaneTestConfig(store journal.Store, api crfgithub.ScaleSetAPI) Config {
	return Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)}
}

func TestFastLaneStatePersistsAcrossPollerRestart(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay", "messages.jsonl")}
	api := &fakeAPI{store: store}
	poller, err := New(fastLaneTestConfig(store, api))
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now().UTC().Truncate(time.Millisecond)
	policy := fastLanePolicy{longThreshold: 6 * time.Minute, holdDuration: 15 * time.Second, reserveSlots: 2}
	poller.startFastLaneWithPolicy(7, 4, started, policy)

	info, err := os.Stat(fastLaneStatePath(store))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("fast lane state permissions are not private: %o", info.Mode().Perm())
	}

	restarted, err := New(fastLaneTestConfig(store, api))
	if err != nil {
		t.Fatal(err)
	}
	lane, ok := restarted.fastLanes[7]
	if !ok || lane.capacity != 4 || lane.reservedSlots != policy.reserveSlots || lane.borrowPending ||
		lane.longThreshold != policy.longThreshold || lane.holdDuration != policy.holdDuration ||
		!lane.holdUntil.Equal(started.Add(policy.holdDuration)) {
		t.Fatalf("fast lane did not survive restart: %#v", restarted.fastLanes)
	}
}

func TestExpiredFastLaneRestoresAsBorrowPending(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Millisecond)
	path := filepath.Join(t.TempDir(), "state", "fast-lanes.json")
	if err := saveFastLaneState(path, map[int64]fastLaneState{
		7: {capacity: 4, holdUntil: now.Add(-time.Second)},
	}); err != nil {
		t.Fatal(err)
	}
	lanes, err := loadFastLaneState(path, now)
	if err != nil {
		t.Fatal(err)
	}
	if !lanes[7].borrowPending {
		t.Fatalf("expired reservation did not restore as one-shot borrow: %#v", lanes[7])
	}
}

func TestClearedFastLaneRemainsClearedAfterRestart(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay", "messages.jsonl")}
	api := &fakeAPI{store: store}
	poller, err := New(fastLaneTestConfig(store, api))
	if err != nil {
		t.Fatal(err)
	}
	poller.startFastLane(7, 4, time.Now().UTC())
	poller.clearFastLane(7)

	restarted, err := New(fastLaneTestConfig(store, api))
	if err != nil {
		t.Fatal(err)
	}
	if len(restarted.fastLanes) != 0 {
		t.Fatalf("cleared reservation resurrected after restart: %#v", restarted.fastLanes)
	}
}

func TestMalformedFastLaneStateDoesNotBlockStartup(t *testing.T) {
	root := t.TempDir()
	store := journal.Store{Path: filepath.Join(root, "replay", "messages.jsonl")}
	if err := os.MkdirAll(filepath.Dir(fastLaneStatePath(store)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fastLaneStatePath(store), []byte("not-json"), 0o600); err != nil {
		t.Fatal(err)
	}
	poller, err := New(fastLaneTestConfig(store, &fakeAPI{store: store}))
	if err != nil {
		t.Fatalf("optional fast lane state blocked startup: %v", err)
	}
	if len(poller.fastLanes) != 0 {
		t.Fatalf("malformed fast lane state was accepted: %#v", poller.fastLanes)
	}
}

func TestFastLanePersistenceFailureKeepsInMemoryReservation(t *testing.T) {
	root := t.TempDir()
	blocked := filepath.Join(root, "blocked")
	if err := os.WriteFile(blocked, []byte("not-a-directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	poller := &Poller{cfg: Config{Store: journal.Store{Path: filepath.Join(blocked, "messages.jsonl")}},
		fastLanes: map[int64]fastLaneState{}}
	poller.startFastLane(7, 4, time.Now().UTC())
	if _, ok := poller.fastLanes[7]; !ok {
		t.Fatal("persistence failure discarded the live reservation")
	}
}

func TestFastLaneLookupFailurePersistsOneShotBorrowAcrossRestart(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay", "messages.jsonl")}
	api := &fakeAPI{store: store, acquirableErr: errors.New("lookup unavailable")}
	poller, err := New(fastLaneTestConfig(store, api))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	poller.startFastLane(7, 4, now)
	hold, borrow := poller.fastLanePreflight(context.Background(), supervisor.Pool{ID: "build", ScaleSetID: 7}, 4, now.Add(time.Second))
	if hold || !borrow {
		t.Fatalf("lookup degradation did not fail open to one-shot borrow: hold=%v borrow=%v", hold, borrow)
	}

	restarted, err := New(fastLaneTestConfig(store, api))
	if err != nil {
		t.Fatal(err)
	}
	lane, ok := restarted.fastLanes[7]
	if !ok || !lane.borrowPending {
		t.Fatalf("borrow-on-degradation state did not survive restart: %#v", restarted.fastLanes)
	}
}

func TestFastLaneRejectsOverflowingPersistedThreshold(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Millisecond)
	path := filepath.Join(t.TempDir(), "fast-lanes.json")
	payload := []byte(`{"schema_version":1,"entries":[{"scale_set_id":7,"capacity":4,"hold_until_ms":` +
		`1,"long_threshold_ms":9223372036854775807,"borrow_pending":true}]}`)
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadFastLaneState(path, now); err == nil {
		t.Fatal("overflowing persisted threshold was accepted")
	}
}

func TestFastLaneRejectsImplausibleFutureDeadline(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Millisecond)
	path := filepath.Join(t.TempDir(), "fast-lanes.json")
	if err := saveFastLaneState(path, map[int64]fastLaneState{
		7: {capacity: 4, holdUntil: now.Add(10 * time.Minute)},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := loadFastLaneState(path, now); err == nil {
		t.Fatal("implausible future reservation deadline was accepted")
	}
}
