package session

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/journal"
)

var benchmarkRanked []crfgithub.AvailableJob

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
	runtimes := map[string]runtimeEstimate{
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
	runtimes := map[string]runtimeEstimate{
		runtimeKey("build", oldLong.Metadata):  {duration: 20 * time.Minute, samples: 6},
		runtimeKey("build", newShort.Metadata): {duration: 30 * time.Second, samples: 4},
	}
	ranked := rankAvailable("build", []crfgithub.AvailableJob{newShort, oldLong}, runtimes, now)
	if ranked[0].RequestID != oldLong.RequestID {
		t.Fatalf("aged long job remained starved: %#v", ranked)
	}
}

func TestCompletedRuntimeLearningNormalizesWorkflowRef(t *testing.T) {
	poller := &Poller{runtimes: map[string]runtimeEstimate{}}
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
	poller := &Poller{cfg: Config{Store: store}, runtimes: map[string]runtimeEstimate{}}
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
	poller := &Poller{runtimes: map[string]runtimeEstimate{}}
	batch := crfgithub.MessageBatch{Statistics: &crfgithub.Statistics{TotalAssignedJobs: 3}, AvailableJobs: []crfgithub.AvailableJob{one, two}}
	if selected := poller.selectedAvailable(batch, "build", 4, now); len(selected) != 1 {
		t.Fatalf("selected beyond remaining capacity: %v", selected)
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
	if runtimeKey("build", missingOwner) != "" {
		t.Fatal("runtime key accepted missing owner identity")
	}
	oversized := base
	oversized.JobDisplayName = strings.Repeat("x", 2048)
	if runtimeKey("build", oversized) != "" {
		t.Fatal("oversized runtime metadata was accepted")
	}
}

func TestAdaptiveAdmissionPrefersQuickWorkWithinVisibleLongBuildConvoy(t *testing.T) {
	now := time.Date(2026, 8, 21, 6, 0, 0, 0, time.UTC)
	longOne := testJob(1, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-3*time.Minute))
	longTwo := testJob(2, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "rust-build", now.Add(-2*time.Minute))
	quick := testJob(3, "dinglebear-ai/soma", "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main", "unit", now.Add(-time.Minute))
	poller := &Poller{runtimes: map[string]runtimeEstimate{
		runtimeKey("build", longOne.Metadata): {duration: 20 * time.Minute, samples: 20},
		runtimeKey("build", quick.Metadata):   {duration: 30 * time.Second, samples: 20},
	}}
	batch := crfgithub.MessageBatch{Statistics: &crfgithub.Statistics{TotalAssignedJobs: 0},
		AvailableJobs: []crfgithub.AvailableJob{longOne, longTwo, quick}}
	if selected := poller.selectedAvailable(batch, "build", 2, now); !slices.Equal(selected, []int64{3, 1}) {
		t.Fatalf("quick work remained behind visible long builds: %v", selected)
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
	runtimes := map[string]runtimeEstimate{
		runtimeKey("build", jobs[0].Metadata): {duration: 20 * time.Minute, samples: 100},
		runtimeKey("build", jobs[1].Metadata): {duration: 30 * time.Second, samples: 100},
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		benchmarkRanked = rankAvailable("build", jobs, runtimes, now)
	}
}
