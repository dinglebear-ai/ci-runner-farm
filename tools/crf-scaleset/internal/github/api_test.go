package github

import (
	"testing"

	"github.com/actions/scaleset"
)

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
