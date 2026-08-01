package protocol

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func validRequest() Request {
	return Request{SchemaVersion: 1, RequestID: "request-1", Operation: "read_snapshot",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		ControllerInstanceID: "controller-1", Sequence: 1}
}
func TestDecodeBoundsAndUnknownFields(t *testing.T) {
	req := validRequest()
	data, _ := json.Marshal(req)
	if _, err := Decode(bytes.NewReader(data)); err != nil {
		t.Fatal(err)
	}
	if _, err := Decode(strings.NewReader(strings.Repeat("x", MaxFrameBytes+1))); err == nil {
		t.Fatal("accepted oversized frame")
	}
	data = append(data[:len(data)-1], []byte(`,"path":"/bin/sh"}`)...)
	if _, err := Decode(bytes.NewReader(data)); err == nil {
		t.Fatal("accepted unknown path")
	}
}
func TestSnapshotFreshnessAndPoolBound(t *testing.T) {
	now := time.Now()
	s := Snapshot{SchemaVersion: 1, ControllerInstanceID: "controller-1",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		ObservedAt: now, ValidUntil: now.Add(10 * time.Second)}
	if err := s.Validate(now); err != nil {
		t.Fatal(err)
	}
	s.ValidUntil = now.Add(-time.Second)
	if err := s.Validate(now); err == nil {
		t.Fatal("accepted stale snapshot")
	}
}

func TestSnapshotRejectsDuplicatePoolsAndUnboundedValues(t *testing.T) {
	now := time.Now()
	base := Snapshot{SchemaVersion: 1, ControllerInstanceID: "controller-1",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		ObservedAt: now, ValidUntil: now.Add(10 * time.Second)}
	tests := []struct {
		name  string
		pools []PoolSnapshot
	}{
		{"duplicate pool", []PoolSnapshot{{PoolID: "python"}, {PoolID: "python"}}},
		{"invalid pool", []PoolSnapshot{{PoolID: "../python"}}},
		{"negative scale set", []PoolSnapshot{{PoolID: "python", ScaleSetID: -1}}},
		{"negative jobs", []PoolSnapshot{{PoolID: "python", AssignedJobs: -1}}},
		{"negative capacity", []PoolSnapshot{{PoolID: "python", AdvertisedCapacity: -1}}},
		{"too many handles", []PoolSnapshot{{PoolID: "python", AcquiredHandles: make([]int64, 65)}}},
		{"invalid handle", []PoolSnapshot{{PoolID: "python", AcquiredHandles: []int64{0}}}},
		{"invalid pool freshness", []PoolSnapshot{{PoolID: "python", ObservedAt: now,
			ValidUntil: now.Add(31 * time.Second)}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			snapshot := base
			snapshot.Pools = tt.pools
			if err := snapshot.Validate(now); err == nil {
				t.Fatalf("accepted invalid pools: %#v", tt.pools)
			}
		})
	}
}
