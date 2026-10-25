package capacitycmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"io"
	"testing"
)

func TestClassicReadinessUsesFixedBindingAndExistingDiagnosticOwner(t *testing.T) {
	config := &hostcapacity.Config{Host: "fixture", Epoch: "epoch", Mode: "active"}
	var output bytes.Buffer
	calls := 0
	err := writeClassicReadiness(config, &output, func(path string, w io.Writer) error {
		if path != ClassicLocalChecksBinding {
			t.Fatal(path)
		}
		_, err := io.WriteString(w, `{"protocol":"farm-local-checks-worker/v1","runtimeQualified":false,"host":"fixture","epoch":"epoch","image":"sha256:fixture","reason":"qualification_missing_or_changed"}`)
		return err
	}, func(got *hostcapacity.Config) (sharedcapacity.Diagnostics, error) {
		calls++
		if got != config {
			t.Fatal("changed policy")
		}
		return sharedcapacity.Diagnostics{PolicyMatches: true}, nil
	})
	if err != nil || calls != 1 {
		t.Fatal(err, calls)
	}
	var value map[string]any
	if json.Unmarshal(output.Bytes(), &value) != nil || value["protocol"] != "farm-classic-capabilities/v1" || value["transport"] != "classic" || value["readiness"].(map[string]any)["runtimeQualified"] != false {
		t.Fatal(output.String())
	}
}
func TestClassicReadinessRefusesChangedOwnerBeforeDiagnosis(t *testing.T) {
	for _, raw := range []string{`{}`, `{"protocol":"farm-local-checks-worker/v1","host":"other","epoch":"epoch"}`, `{"protocol":"farm-local-checks-worker/v1","host":"fixture","epoch":"other"}`} {
		called := false
		err := writeClassicReadiness(&hostcapacity.Config{Host: "fixture", Epoch: "epoch", Mode: "active"}, io.Discard, func(_ string, w io.Writer) error { _, e := io.WriteString(w, raw); return e }, func(*hostcapacity.Config) (sharedcapacity.Diagnostics, error) {
			called = true
			return sharedcapacity.Diagnostics{}, nil
		})
		if err == nil || called {
			t.Fatal("accepted changed owner")
		}
	}
}
func TestClassicReadinessReturnsDiagnosticFailureWithoutPartialReceipt(t *testing.T) {
	marker := errors.New("diagnostic failed")
	var output bytes.Buffer
	err := writeClassicReadiness(&hostcapacity.Config{Host: "fixture", Epoch: "epoch", Mode: "active"}, &output, func(_ string, w io.Writer) error {
		_, e := io.WriteString(w, `{"protocol":"farm-local-checks-worker/v1","host":"fixture","epoch":"epoch"}`)
		return e
	}, func(*hostcapacity.Config) (sharedcapacity.Diagnostics, error) {
		return sharedcapacity.Diagnostics{}, marker
	})
	if !errors.Is(err, marker) || output.Len() != 0 {
		t.Fatal(err, output.String())
	}
}
func TestClassicReadinessAndReviewRejectCallerBindingAndFlags(t *testing.T) {
	for _, args := range [][]string{{}, {"local-checks-readiness", "/caller/binding"}, {"local-checks-readiness", "--qualified"}} {
		if WriteClassicLocalChecksReadiness(args, io.Discard) == nil {
			t.Fatal(args)
		}
	}
	for _, args := range [][]string{{}, {"local-checks-qualification-review", "kernel", "full", "/caller"}} {
		if ReviewClassicLocalChecksQualification(args, io.Discard) == nil {
			t.Fatal(args)
		}
	}
}
