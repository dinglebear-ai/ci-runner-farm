package github

import (
	"slices"
	"testing"

	"github.com/actions/scaleset"
)

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

func TestFromScaleSetHidesCanonicalNameLabel(t *testing.T) {
	got := fromScaleSet(&scaleset.RunnerScaleSet{
		ID: 62, Name: "crf-install-ops-revision", RunnerGroupID: 4,
		Labels: []scaleset.Label{
			{Type: "System", Name: "crf-install-ops-revision"},
			{Type: "System", Name: "ci-pool-ops"},
			{Type: "System", Name: "tailscale"},
		},
	})
	if !slices.Equal(got.Labels, []string{"ci-pool-ops", "tailscale"}) {
		t.Fatalf("adapter leaked canonical name into configured labels: %#v", got.Labels)
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
