package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"testing"
)

func TestClassicQualificationProbeEntrypoint(t *testing.T) {
	if os.Getenv("FARM_TEST_PROBE_CHILD") == "1" {
		os.Args = []string{"ci-runner-capacity", "--local-checks-probe"}
		main()
		os.Exit(0)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestClassicQualificationProbeEntrypoint$")
	cmd.Env = append(os.Environ(), "FARM_TEST_PROBE_CHILD=1")
	var out, errout bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errout
	err := cmd.Run()
	if err != nil {
		// The host test process may have unbounded cgroups. The probe must still
		// reach the exact kernel validator, not ordinary capacity command dispatch.
		if !bytes.HasPrefix(errout.Bytes(), []byte("local_checks_kernel_probe_failed classic_local_checks_operation_failed: local_checks_")) {
			t.Fatalf("probe was not dispatched: %q", errout.String())
		}
	} else {
		var proof map[string]any
		if json.Unmarshal(out.Bytes(), &proof) != nil || proof["cpuPeriod"] == nil {
			t.Fatalf("invalid kernel proof: %s", out.String())
		}
	}
}

func TestClassicFailureOnlyReturnsClosedIdentifiers(t *testing.T) {
	if classicFailure(errors.New("local_checks_nested_probe_failed")) != "classic_local_checks_operation_failed: local_checks_nested_probe_failed" {
		t.Fatal("missing fixed diagnosis")
	}
	for _, text := range []string{"secret=PRIVATE", "local_checks_secret=PRIVATE", "local_checks_failed\nPRIVATE", "/private/path"} {
		if classicFailure(errors.New(text)) != "classic_local_checks_operation_failed" {
			t.Fatal("unsafe diagnostic")
		}
	}
}
