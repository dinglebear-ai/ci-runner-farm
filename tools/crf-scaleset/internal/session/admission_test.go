package session

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/journal"
)

var (
	benchmarkRanked   []crfgithub.AvailableJob
	benchmarkSelected []int64
)

func testJob(id int64, repository, workflow, name string, queued time.Time) crfgithub.AvailableJob {
	return crfgithub.AvailableJob{RequestID: id, Metadata: crfgithub.JobMetadata{
		OwnerName: "dinglebear-ai", RepositoryName: repository, JobWorkflowRef: workflow, JobDisplayName: name, QueueTime: queued,
	}}
}

func TestRankAvailablePrefersLearnedShortWork(t *testing.T) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	short := testJob(3, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", now.Add(-time.Minute))
	unknown := testJob(2, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "new-check", now.Add(-2*time.Minute))
	long := testJob(1, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/feature", "rust-build", now.Add(-3*time.Minute))
	runtimes := map[runtimeDigest]runtimeEstimate{
		runtimeKey("build", short.Metadata): {duration: 30 * time.Second, samples: 4},
		runtimeKey("build", long.Metadata):  {duration: 20 * time.Minute, samples: 6},
	}
	ranked := rankAvailable("build", []crfgithub.AvailableJob{long, unknown, short}, runtimes, now)
	got := []int64{ranked[0].RequestID, ranked[1].RequestID, ranked[2].RequestID}
	if !slices.Equal(got, []int64{3, 2, 1}) {
		t.Fatalf("runtime ranking did not prefer short work: %v", got)
	}
}

func TestRankAvailableAgingPreventsLongJobStarvation(t *testing.T) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	oldLong := testJob(1, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-queueStarvationAge-time.Second))
	newShort := testJob(2, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", now.Add(-time.Minute))
	runtimes := map[runtimeDigest]runtimeEstimate{
		runtimeKey("build", oldLong.Metadata):  {duration: 20 * time.Minute, samples: 6},
		runtimeKey("build", newShort.Metadata): {duration: 30 * time.Second, samples: 4},
	}
	ranked := rankAvailable("build", []crfgithub.AvailableJob{newShort, oldLong}, runtimes, now)
	if ranked[0].RequestID != oldLong.RequestID {
		t.Fatalf("aged long job remained starved: %#v", ranked)
	}
}

func TestCompletedRuntimeLearningNormalizesWorkflowRef(t *testing.T) {
	poller := &Poller{runtimes: map[runtimeDigest]runtimeEstimate{}}
	metadata := crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/feature", JobDisplayName: "unit"}
	poller.observeCompleted("build", []crfgithub.CompletedJob{{Metadata: metadata,
		RunnerAssignTime: time.Unix(100, 0), FinishTime: time.Unix(140, 0)}})
	main := metadata
	main.JobWorkflowRef = "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main"
	estimate, ok := poller.runtimes[runtimeKey("build", main)]
	if !ok || estimate.duration != 40*time.Second || estimate.samples != 1 {
		t.Fatalf("runtime history was not learned across refs: %#v", poller.runtimes)
	}
}

func TestRuntimeHistoryPersistsAcrossPollerRestart(t *testing.T) {
	root := t.TempDir()
	store := journal.Store{Path: filepath.Join(root, "replay", "messages.jsonl")}
	metadata := crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", JobDisplayName: "unit"}
	poller := &Poller{cfg: Config{Store: store}, runtimes: map[runtimeDigest]runtimeEstimate{}}
	poller.observeCompleted("build", []crfgithub.CompletedJob{{Metadata: metadata,
		RunnerAssignTime: time.Unix(100, 0), FinishTime: time.Unix(140, 0)}})

	historyPath := runtimeHistoryPath(store)
	info, err := os.Stat(historyPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("runtime history permissions are not private: %o", info.Mode().Perm())
	}
	history, err := os.ReadFile(historyPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, plaintext := range []string{"dinglebear-ai", "soma", "ci.yml", "unit"} {
		if strings.Contains(string(history), plaintext) {
			t.Fatalf("runtime history persisted plaintext job metadata %q", plaintext)
		}
	}

	api := &fakeAPI{store: store}
	restarted, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	estimate, ok := restarted.runtimes[runtimeKey("build", metadata)]
	if !ok || estimate.duration != 40*time.Second || estimate.samples != 1 {
		t.Fatalf("runtime history did not survive restart: %#v", restarted.runtimes)
	}
}

func TestRuntimeHistoryIsDeterministicallyBoundedInMemory(t *testing.T) {
	const total = maxRuntimeHistoryEntries + 37
	metadata := make([]crfgithub.JobMetadata, total)
	for i := range metadata {
		metadata[i] = crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
			JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main",
			JobDisplayName: fmt.Sprintf("job-%04d", i)}
	}
	learn := func(reverse bool) *Poller {
		poller := &Poller{runtimes: map[runtimeDigest]runtimeEstimate{}}
		for n := range metadata {
			i := n
			if reverse {
				i = len(metadata) - 1 - n
			}
			poller.observeCompleted("build", []crfgithub.CompletedJob{{Metadata: metadata[i],
				RunnerAssignTime: time.Unix(100, 0), FinishTime: time.Unix(140, 0)}})
		}
		return poller
	}
	forward, reverse := learn(false), learn(true)
	if len(forward.runtimes) != maxRuntimeHistoryEntries || len(reverse.runtimes) != maxRuntimeHistoryEntries {
		t.Fatalf("runtime maps grew beyond bound: forward=%d reverse=%d", len(forward.runtimes), len(reverse.runtimes))
	}
	for key := range forward.runtimes {
		if _, ok := reverse.runtimes[key]; !ok {
			t.Fatal("deterministic eviction depended on observation order")
		}
	}
}

func TestRuntimeHistoryEvictionRetainsHotEstimate(t *testing.T) {
	hotMetadata := crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", JobDisplayName: "hot"}
	hotKey := runtimeKey("build", hotMetadata)
	poller := &Poller{runtimes: map[runtimeDigest]runtimeEstimate{
		hotKey: {duration: 15 * time.Second, samples: 100},
	}}
	for i := 0; i < maxRuntimeHistoryEntries+64; i++ {
		metadata := crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
			JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main",
			JobDisplayName: fmt.Sprintf("cold-%04d", i)}
		poller.observeCompleted("build", []crfgithub.CompletedJob{{Metadata: metadata,
			RunnerAssignTime: time.Unix(100, 0), FinishTime: time.Unix(140, 0)}})
	}
	if len(poller.runtimes) != maxRuntimeHistoryEntries {
		t.Fatalf("runtime map grew to %d entries", len(poller.runtimes))
	}
	if got := poller.runtimes[hotKey]; got.samples != 100 || got.duration != 15*time.Second {
		t.Fatalf("hot estimate was evicted or mutated: %#v", got)
	}
}

func TestCloseFlushesDirtyRuntimeHints(t *testing.T) {
	store := journal.Store{Path: filepath.Join(t.TempDir(), "replay", "messages.jsonl")}
	poller := &Poller{cfg: Config{API: &fakeAPI{}, Store: store},
		runtimes: map[runtimeDigest]runtimeEstimate{}, acquirableHealth: map[int64]string{}}
	metadata := crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", JobDisplayName: "unit"}
	poller.lastRuntimePersist = time.Now()
	poller.observeCompleted("build", []crfgithub.CompletedJob{{Metadata: metadata,
		RunnerAssignTime: time.Unix(100, 0), FinishTime: time.Unix(140, 0)}})
	if _, err := os.Stat(runtimeHistoryPath(store)); !os.IsNotExist(err) {
		t.Fatalf("throttled observation persisted early: %v", err)
	}
	if err := poller.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadRuntimeHistory(runtimeHistoryPath(store))
	if err != nil || loaded[runtimeKey("build", metadata)].samples != 1 {
		t.Fatalf("close did not flush dirty hints: %#v err=%v", loaded, err)
	}
}

func TestRuntimePersistenceFailureRemainsDirtyUntilSuccessfulRetry(t *testing.T) {
	root := t.TempDir()
	blocked := filepath.Join(root, "blocked")
	if err := os.WriteFile(blocked, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := journal.Store{Path: filepath.Join(blocked, "messages.jsonl")}
	poller := &Poller{cfg: Config{Store: store}, runtimes: map[runtimeDigest]runtimeEstimate{}}
	metadata := crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", JobDisplayName: "unit"}
	poller.observeCompleted("build", []crfgithub.CompletedJob{{Metadata: metadata,
		RunnerAssignTime: time.Unix(100, 0), FinishTime: time.Unix(140, 0)}})
	if !poller.runtimeDirty || !poller.lastRuntimePersist.IsZero() {
		t.Fatalf("failed persistence was marked successful: dirty=%v persisted=%v",
			poller.runtimeDirty, poller.lastRuntimePersist)
	}
	if err := os.Remove(blocked); err != nil {
		t.Fatal(err)
	}
	if err := poller.persistRuntimeHints(true); err != nil {
		t.Fatal(err)
	}
	if poller.runtimeDirty || poller.lastRuntimePersist.IsZero() {
		t.Fatalf("successful retry did not clear dirty state: dirty=%v persisted=%v",
			poller.runtimeDirty, poller.lastRuntimePersist)
	}
}

func TestClosePersistenceFailureStillClosesActiveSession(t *testing.T) {
	root := t.TempDir()
	blocked := filepath.Join(root, "blocked")
	if err := os.WriteFile(blocked, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{}
	poller := &Poller{
		cfg:      Config{API: api, Store: journal.Store{Path: filepath.Join(blocked, "messages.jsonl")}},
		sessions: map[int64]crfgithub.Session{7: {ScaleSetID: 7, ID: "session-1"}},
		runtimes: map[runtimeDigest]runtimeEstimate{
			runtimeDigest{1}: {duration: time.Minute, samples: 1},
		},
		runtimeDirty: true, runtimeGeneration: 1,
	}
	err := poller.Close(context.Background())
	if err == nil {
		t.Fatal("Close hid runtime persistence failure")
	}
	if api.closeCalls != 1 {
		t.Fatalf("CloseMessageSession calls=%d, want 1", api.closeCalls)
	}
}

func TestMalformedRuntimeHistoryDoesNotBlockStartup(t *testing.T) {
	root := t.TempDir()
	store := journal.Store{Path: filepath.Join(root, "replay", "messages.jsonl")}
	if err := os.MkdirAll(filepath.Dir(runtimeHistoryPath(store)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(runtimeHistoryPath(store), []byte("not-json"), 0o600); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{store: store}
	poller, err := New(Config{API: api, Store: store, ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64)})
	if err != nil {
		t.Fatalf("optional runtime history blocked startup: %v", err)
	}
	if len(poller.runtimes) != 0 {
		t.Fatalf("malformed runtime history was accepted: %#v", poller.runtimes)
	}
}

func TestRuntimeHistoryRejectsOverflowingDurationMillis(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime-history.json")
	payload := []byte(`{"schema_version":1,"entries":[{"key":"` + strings.Repeat("a", 64) +
		`","duration_millis":9223372036854775807,"samples":1}]}`)
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadRuntimeHistory(path); err == nil {
		t.Fatal("overflowing duration_millis was accepted")
	}
}

func TestAdmissionNeverExceedsRemainingCapacity(t *testing.T) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	one := testJob(1, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", now)
	two := testJob(2, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "lint", now)
	poller := &Poller{runtimes: map[runtimeDigest]runtimeEstimate{}}
	batch := crfgithub.MessageBatch{Statistics: &crfgithub.Statistics{TotalAssignedJobs: 3}, AvailableJobs: []crfgithub.AvailableJob{one, two}}
	if selected := poller.selectedAvailable(batch, "build", 4, now); len(selected) != 1 {
		t.Fatalf("selected beyond remaining capacity: %v", selected)
	}
}

func TestAdmissionDefenseNeverExceedsCapacityForNegativeAssigned(t *testing.T) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	jobs := []crfgithub.AvailableJob{
		testJob(1, "dinglebear-ai/soma", "workflow@refs/heads/main", "one", now),
		testJob(2, "dinglebear-ai/soma", "workflow@refs/heads/main", "two", now),
		testJob(3, "dinglebear-ai/soma", "workflow@refs/heads/main", "three", now),
	}
	poller := &Poller{runtimes: map[runtimeDigest]runtimeEstimate{}}
	minInt := -int(^uint(0)>>1) - 1
	for _, assigned := range []int{-1, minInt} {
		batch := crfgithub.MessageBatch{Statistics: &crfgithub.Statistics{TotalAssignedJobs: assigned}, AvailableJobs: jobs}
		if selected := poller.selectedAvailable(batch, "build", 2, now); len(selected) != 2 {
			t.Fatalf("negative assigned count escaped capacity bound: assigned=%d selected=%v", assigned, selected)
		}
	}
}

func TestRuntimeKeyScopesOwnersAndBoundsUntrustedMetadata(t *testing.T) {
	base := crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", JobDisplayName: "unit"}
	other := base
	other.OwnerName = "another-owner"
	if runtimeKey("build", base) == runtimeKey("build", other) {
		t.Fatal("runtime key collided across owners")
	}
	key := runtimeKey("build", base)
	if !validRuntimeDigest(key) {
		t.Fatalf("runtime key is not a bounded digest: %q", key)
	}
	if key == runtimeKey("windows", base) {
		t.Fatal("runtime key collided across pools")
	}
	missingOwner := base
	missingOwner.OwnerName = ""
	if validRuntimeDigest(runtimeKey("build", missingOwner)) {
		t.Fatal("runtime key accepted missing owner identity")
	}
	oversized := base
	oversized.JobDisplayName = strings.Repeat("x", 2048)
	if validRuntimeDigest(runtimeKey("build", oversized)) {
		t.Fatal("oversized runtime metadata was accepted")
	}
}

func TestTopCandidatesMatchesFullRankingPrefix(t *testing.T) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	jobs := make([]crfgithub.AvailableJob, 0, 257)
	for i := 0; i < 257; i++ {
		name := "unit"
		if i%5 == 0 {
			name = "rust-build"
		}
		queued := now.Add(-time.Duration((i*37)%900) * time.Second)
		jobs = append(jobs, testJob(int64(257-i), "dinglebear-ai/soma",
			"dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", name, queued))
	}
	runtimes := map[runtimeDigest]runtimeEstimate{
		runtimeKey("build", jobs[0].Metadata): {duration: 20 * time.Minute, samples: 20},
		runtimeKey("build", jobs[1].Metadata): {duration: 30 * time.Second, samples: 20},
	}
	full := rankCandidates("build", jobs, runtimes, now)
	for _, limit := range []int{1, 2, 7, 64, 128, len(jobs)} {
		top := topCandidates("build", jobs, runtimes, now, limit)
		if len(top) != limit {
			t.Fatalf("top candidate length mismatch: limit=%d got=%d", limit, len(top))
		}
		for i := 0; i < limit; i++ {
			if top[i].job.RequestID != full[i].job.RequestID {
				t.Fatalf("top-K diverged from full ranking: limit=%d index=%d got=%d want=%d",
					limit, i, top[i].job.RequestID, full[i].job.RequestID)
			}
		}
	}
}

func TestRuntimeKeyNormalizesAsciiCaseAndBranchRef(t *testing.T) {
	upper := crfgithub.JobMetadata{OwnerName: "DINGLEBEAR-AI", RepositoryName: "SOMA",
		JobWorkflowRef: "Dinglebear-AI/Soma/.github/workflows/CI.yml@refs/heads/FEATURE", JobDisplayName: "UNIT"}
	lower := crfgithub.JobMetadata{OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", JobDisplayName: "unit"}
	if runtimeKey("BUILD", upper) != runtimeKey("build", lower) {
		t.Fatal("runtime identity did not normalize ASCII case and branch ref")
	}
}

func TestAdaptiveAdmissionPrefersQuickWorkWithinVisibleLongBuildConvoy(t *testing.T) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	longOne := testJob(1, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-3*time.Minute))
	longTwo := testJob(2, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-2*time.Minute))
	quick := testJob(3, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", now.Add(-time.Minute))
	poller := &Poller{runtimes: map[runtimeDigest]runtimeEstimate{
		runtimeKey("build", longOne.Metadata): {duration: 20 * time.Minute, samples: 20},
		runtimeKey("build", quick.Metadata):   {duration: 30 * time.Second, samples: 20},
	}}
	batch := crfgithub.MessageBatch{Statistics: &crfgithub.Statistics{TotalAssignedJobs: 0},
		AvailableJobs: []crfgithub.AvailableJob{longOne, longTwo, quick}}
	if selected := poller.selectedAvailable(batch, "build", 2, now); !slices.Equal(selected, []int64{3, 1}) {
		t.Fatalf("quick work remained behind visible long builds: %v", selected)
	}
}

func BenchmarkSelectAvailable10000Jobs64Slots(b *testing.B) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	jobs := make([]crfgithub.AvailableJob, 0, 10_000)
	for i := 0; i < 10_000; i++ {
		name := "unit"
		if i%4 == 0 {
			name = "rust-build"
		}
		jobs = append(jobs, testJob(int64(i+1), "dinglebear-ai/soma",
			"dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", name,
			now.Add(-time.Duration(i%300)*time.Second)))
	}
	poller := &Poller{runtimes: map[runtimeDigest]runtimeEstimate{
		runtimeKey("build", jobs[0].Metadata): {duration: 20 * time.Minute, samples: 100},
		runtimeKey("build", jobs[1].Metadata): {duration: 30 * time.Second, samples: 100},
	}}
	batch := crfgithub.MessageBatch{Statistics: &crfgithub.Statistics{TotalAssignedJobs: 0}, AvailableJobs: jobs}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		benchmarkSelected = poller.selectedAvailable(batch, "build", 64, now)
	}
}

func BenchmarkRankAvailable64Jobs(b *testing.B) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	jobs := make([]crfgithub.AvailableJob, 0, 64)
	for i := 0; i < 64; i++ {
		name := "unit"
		if i%2 == 0 {
			name = "rust-build"
		}
		jobs = append(jobs, testJob(int64(i+1), "dinglebear-ai/soma",
			"dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", name,
			now.Add(-time.Duration(i)*time.Second)))
	}
	runtimes := map[runtimeDigest]runtimeEstimate{
		runtimeKey("build", jobs[0].Metadata): {duration: 20 * time.Minute, samples: 100},
		runtimeKey("build", jobs[1].Metadata): {duration: 30 * time.Second, samples: 100},
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		benchmarkRanked = rankAvailable("build", jobs, runtimes, now)
	}
}
