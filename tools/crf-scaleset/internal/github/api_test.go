package github

import (
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestAdapterSelectsDedicatedScaleSetClient(t *testing.T) {
	admin, err := scaleset.NewClientWithPersonalAccessToken(
		scaleset.NewClientWithPersonalAccessTokenConfig{GitHubConfigURL: "https://github.com/dinglebear-ai",
			PersonalAccessToken: "token", SystemInfo: scaleset.SystemInfo{System: "test", Subsystem: "controller"}})
	if err != nil {
		t.Fatal(err)
	}
	seen := []int64{}
	adapter := NewAdapterWithScaleSetClientFactory(admin, "dinglebear-ai", func(id int64) (*scaleset.Client, error) {
		seen = append(seen, id)
		return scaleset.NewClientWithPersonalAccessToken(
			scaleset.NewClientWithPersonalAccessTokenConfig{GitHubConfigURL: "https://github.com/dinglebear-ai",
				PersonalAccessToken: "token", SystemInfo: scaleset.SystemInfo{System: "test", Subsystem: "listener", ScaleSetID: int(id)}})
	})
	ops, err := adapter.clientForScaleSet(74)
	if err != nil {
		t.Fatal(err)
	}
	rust, err := adapter.clientForScaleSet(70)
	if err != nil {
		t.Fatal(err)
	}
	if ops == rust || ops == admin || rust == admin {
		t.Fatal("adapter reused one client across scale sets")
	}
	if !slices.Equal(seen, []int64{74, 70}) || ops.SystemInfo().ScaleSetID != 74 || rust.SystemInfo().ScaleSetID != 70 {
		t.Fatalf("scale-set clients were not bound correctly: seen=%v ops=%#v rust=%#v",
			seen, ops.SystemInfo(), rust.SystemInfo())
	}
	if _, err := adapter.clientForScaleSet(0); err == nil {
		t.Fatal("invalid scale-set ID was accepted")
	}
}

func TestLabelsIncludeCanonicalScaleSetName(t *testing.T) {
	got := labels("crf-install-ops-revision", []string{"ci-pool-ops", "tailscale", "CRF-INSTALL-OPS-REVISION"})
	if len(got) != 3 {
		t.Fatalf("unexpected labels: %#v", got)
	}
	want := []scaleset.Label{
		{Type: "System", Name: "crf-install-ops-revision"},
		{Type: "System", Name: "ci-pool-ops"},
		{Type: "System", Name: "tailscale"},
	}
	if !slices.Equal(got, want) {
		t.Fatalf("canonical scale-set label missing or reordered: got=%#v want=%#v", got, want)
	}
}

func TestFromScaleSetPreservesAuthoritativeLabels(t *testing.T) {
	got, err := fromScaleSet(&scaleset.RunnerScaleSet{
		ID: 62, Name: "crf-install-ops-revision", RunnerGroupID: 4,
		Labels: []scaleset.Label{
			{Type: "System", Name: "crf-install-ops-revision"},
			{Type: "System", Name: "ci-pool-ops"},
			{Type: "System", Name: "tailscale"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got.Labels, []string{"crf-install-ops-revision", "ci-pool-ops", "tailscale"}) {
		t.Fatalf("adapter discarded authoritative labels: %#v", got.Labels)
	}
}

func TestFromScaleSetRejectsMissingOrMalformedResponse(t *testing.T) {
	for _, value := range []*scaleset.RunnerScaleSet{
		nil,
		{},
		{ID: 1, Name: "", RunnerGroupID: 2},
		{ID: 1, Name: "ci-pool-rust", RunnerGroupID: 2, Labels: []scaleset.Label{{Name: ""}}},
	} {
		if _, err := fromScaleSet(value); !errors.Is(err, ErrInvalidResponse) {
			t.Fatalf("accepted invalid scale-set response %#v: %v", value, err)
		}
	}
}

func TestLabelsForComparisonDistinguishesImplicitAndConfiguredName(t *testing.T) {
	opaque := ScaleSet{Name: "crf-install-ops-revision",
		Labels: []string{"crf-install-ops-revision", "ci-pool-ops", "tailscale"}}
	if got := LabelsForComparison(opaque, []string{"ci-pool-ops", "tailscale"}); !slices.Equal(got, []string{"ci-pool-ops", "tailscale"}) {
		t.Fatalf("implicit canonical label was not removed: %#v", got)
	}
	stable := ScaleSet{Name: "ci-pool-ops", Labels: []string{"tailscale", "ci-pool-ops"}}
	if got := LabelsForComparison(stable, []string{"ci-pool-ops", "tailscale"}); !slices.Equal(got, []string{"tailscale", "ci-pool-ops"}) {
		t.Fatalf("configured routing-name label was removed: %#v", got)
	}
}

func TestJobMetadataPreservesAdaptiveQueueSignals(t *testing.T) {
	queued := time.Date(2026, 8, 21, 6, 12, 0, 0, time.UTC)
	metadata := jobMetadata(&scaleset.JobMessageBase{
		OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main",
		JobDisplayName: "unit", QueueTime: queued, EventName: "push",
		RequestLabels: []string{"self-hosted", "linux"},
	})
	if metadata.OwnerName != "dinglebear-ai" || metadata.RepositoryName != "soma" ||
		metadata.JobDisplayName != "unit" || metadata.QueueTime != queued {
		t.Fatalf("adaptive scheduling identity was not preserved: %#v", metadata)
	}
	if metadata.JobWorkflowRef != "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main" {
		t.Fatalf("workflow identity changed: %#v", metadata)
	}
}

func TestDecodeAcquirableJobsValidatesAndPreservesMetadata(t *testing.T) {
	queued := time.Date(2026, 8, 21, 6, 30, 0, 0, time.UTC)
	jobs := []*scaleset.JobAvailable{{JobMessageBase: scaleset.JobMessageBase{
		RunnerRequestID: 101, OwnerName: "dinglebear-ai", RepositoryName: "soma",
		JobWorkflowRef: "dinglebear-ai/soma/.github/workflows/ci.yml@refs/heads/main",
		JobDisplayName: "unit", QueueTime: queued,
	}}}
	got, err := decodeAcquirableJobs(jobs)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].RequestID != 101 || got[0].Metadata.OwnerName != "dinglebear-ai" ||
		got[0].Metadata.RepositoryName != "soma" || got[0].Metadata.JobDisplayName != "unit" ||
		got[0].Metadata.QueueTime != queued {
		t.Fatalf("acquirable job metadata changed: %#v", got)
	}
}

func TestDecodeAcquirableJobsRejectsInvalidAndDuplicateEntries(t *testing.T) {
	valid := func(id int64) *scaleset.JobAvailable {
		return &scaleset.JobAvailable{JobMessageBase: scaleset.JobMessageBase{RunnerRequestID: id}}
	}
	for name, jobs := range map[string][]*scaleset.JobAvailable{
		"nil":       {nil},
		"zero":      {valid(0)},
		"negative":  {valid(-1)},
		"duplicate": {valid(7), valid(7)},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeAcquirableJobs(jobs); !errors.Is(err, ErrInvalidResponse) {
				t.Fatalf("invalid acquirable list was accepted: err=%v", err)
			}
		})
	}
}

func TestDecodeAcquirableJobsEnforcesResponseFuse(t *testing.T) {
	jobs := make([]*scaleset.JobAvailable, maxAcquirableJobs+1)
	for i := range jobs {
		jobs[i] = &scaleset.JobAvailable{JobMessageBase: scaleset.JobMessageBase{RunnerRequestID: int64(i + 1)}}
	}
	if _, err := decodeAcquirableJobs(jobs); !errors.Is(err, ErrInvalidResponse) {
		t.Fatalf("oversized acquirable list was accepted: err=%v", err)
	}
}

func TestStatsRejectsEveryNegativeCounter(t *testing.T) {
	minInt := -int(^uint(0)>>1) - 1
	fields := []struct {
		name string
		set  func(*scaleset.RunnerScaleSetStatistic, int)
	}{
		{"available", func(v *scaleset.RunnerScaleSetStatistic, n int) { v.TotalAvailableJobs = n }},
		{"acquired", func(v *scaleset.RunnerScaleSetStatistic, n int) { v.TotalAcquiredJobs = n }},
		{"assigned", func(v *scaleset.RunnerScaleSetStatistic, n int) { v.TotalAssignedJobs = n }},
		{"running", func(v *scaleset.RunnerScaleSetStatistic, n int) { v.TotalRunningJobs = n }},
		{"registered_runners", func(v *scaleset.RunnerScaleSetStatistic, n int) { v.TotalRegisteredRunners = n }},
		{"busy_runners", func(v *scaleset.RunnerScaleSetStatistic, n int) { v.TotalBusyRunners = n }},
		{"idle_runners", func(v *scaleset.RunnerScaleSetStatistic, n int) { v.TotalIdleRunners = n }},
	}
	for _, field := range fields {
		for _, negative := range []int{-1, minInt} {
			t.Run(fmt.Sprintf("%s_%d", field.name, negative), func(t *testing.T) {
				statistics := &scaleset.RunnerScaleSetStatistic{
					TotalAvailableJobs: 1, TotalAcquiredJobs: 1, TotalAssignedJobs: 1,
					TotalRunningJobs: 1, TotalRegisteredRunners: 1, TotalBusyRunners: 1,
					TotalIdleRunners: 1,
				}
				field.set(statistics, negative)
				if _, err := stats(statistics); !errors.Is(err, ErrInvalidResponse) {
					t.Fatalf("negative %s counter was accepted: %v", field.name, err)
				}
			})
		}
	}
}

func TestStatsRejectsContradictoryNegativeAvailableCount(t *testing.T) {
	value := &scaleset.RunnerScaleSetStatistic{TotalAvailableJobs: -1, TotalAssignedJobs: 4}
	if _, err := stats(value); !errors.Is(err, ErrInvalidResponse) {
		t.Fatalf("contradictory statistics were accepted: %v", err)
	}
}

func TestAssignedJobHandleUsesStableJobIdentityWhenRunnerRequestIDIsZero(t *testing.T) {
	job := &scaleset.JobAssigned{JobMessageBase: scaleset.JobMessageBase{
		JobID: "4dbf00ec-bdda-5ddd-a451-0bc7f6f980e3", RunnerRequestID: 0,
	}}
	first, err := assignedJobHandle(21, job)
	if err != nil {
		t.Fatal(err)
	}
	second, err := assignedJobHandle(21, job)
	if err != nil {
		t.Fatal(err)
	}
	if first <= 0 || first != second {
		t.Fatalf("assignment handle is not stable and positive: first=%d second=%d", first, second)
	}
	if first > maxJSONSafeInteger {
		t.Fatalf("assignment handle cannot survive JSON number round trips: %d", first)
	}

	other, err := assignedJobHandle(21, &scaleset.JobAssigned{JobMessageBase: scaleset.JobMessageBase{
		JobID: "43e081fe-cf9e-5ad4-a7ab-9874b80fe221", RunnerRequestID: 0,
	}})
	if err != nil {
		t.Fatal(err)
	}
	if other == first {
		t.Fatal("different jobs received the same work handle")
	}
}

func TestAssignedJobHandleRejectsMissingStableIdentity(t *testing.T) {
	if _, err := assignedJobHandle(21, &scaleset.JobAssigned{}); err == nil {
		t.Fatal("assignment without a stable job identity was accepted")
	}
}

func TestAssignedJobHandleSurvivesGitHubReassignment(t *testing.T) {
	base := scaleset.JobMessageBase{
		WorkflowRunID: 32490619097,
		OwnerName:     "dinglebear-ai", RepositoryName: "ci-runner-farm",
		JobWorkflowRef: "dinglebear-ai/ci-runner-farm/.github/workflows/distributed-farm-acceptance.yaml@refs/heads/main",
		JobDisplayName: "distributed-windows",
	}
	first := base
	first.JobID = "assignment-a"
	first.RunnerRequestID = 101
	second := base
	second.JobID = "assignment-b"
	second.RunnerRequestID = 202

	firstHandle, err := assignedJobHandle(112, &scaleset.JobAssigned{JobMessageBase: first})
	if err != nil {
		t.Fatal(err)
	}
	secondHandle, err := assignedJobHandle(112, &scaleset.JobAssigned{JobMessageBase: second})
	if err != nil {
		t.Fatal(err)
	}
	if firstHandle != secondHandle {
		t.Fatalf("reassigned workflow job changed handle: first=%d second=%d", firstHandle, secondHandle)
	}

	other := base
	other.JobDisplayName = "distributed-linux"
	otherHandle, err := assignedJobHandle(112, &scaleset.JobAssigned{JobMessageBase: other})
	if err != nil {
		t.Fatal(err)
	}
	if otherHandle == firstHandle {
		t.Fatal("different workflow jobs received the same handle")
	}
}
