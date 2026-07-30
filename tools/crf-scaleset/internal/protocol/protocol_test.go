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
