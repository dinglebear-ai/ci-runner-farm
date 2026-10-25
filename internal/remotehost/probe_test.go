package remotehost

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFixedProbeReadsOnlyNativeDiscoveryAndReturnsClosedProjection(t *testing.T) {
	root, err := os.MkdirTemp("", "frh-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	version := filepath.Join(root, "version")
	machine := filepath.Join(root, "machine")
	path := filepath.Join(root, "farm.sock")
	for p, b := range map[string]string{version: "version=\"8.0.0-test\"\n", machine: "fixture-host-id"} {
		if err := os.WriteFile(p, []byte(b), 0600); err != nil {
			t.Fatal(err)
		}
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan error, 1)
	go func() {
		for _, action := range []string{"local-checks-contract", "job-status", "admission-status"} {
			c, e := listener.Accept()
			if e != nil {
				done <- e
				return
			}
			_ = c.SetDeadline(time.Now().Add(3 * time.Second))
			var request map[string]string
			e = json.NewDecoder(c).Decode(&request)
			if e != nil || request["action"] != action {
				c.Close()
				done <- io.ErrUnexpectedEOF
				return
			}
			var data any
			switch action {
			case "local-checks-contract":
				data = map[string]any{"protocol": "farm-local-checks-worker/v1"}
			case "job-status":
				data = map[string]any{"active": nil}
			case "admission-status":
				data = map[string]any{"policyMatches": true, "grants": []any{}}
			}
			e = json.NewEncoder(c).Encode(map[string]any{"ok": true, "data": data})
			c.Close()
			if e != nil {
				done <- e
				return
			}
		}
		done <- nil
	}()
	source := strings.TrimSuffix(strings.TrimPrefix(remoteProbeCommand, "python3 -c '"), "'")
	source = strings.ReplaceAll(source, "/etc/unraid-version", version)
	source = strings.ReplaceAll(source, "/etc/machine-id", machine)
	source = strings.ReplaceAll(source, "/run/unraid-core/plugin-data/ci-runner-farm/backend.sock", path)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	raw, err := exec.CommandContext(ctx, "python3", "-c", source).CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v", raw, err)
	}
	var result Probe
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&result); err != nil {
		t.Fatal(err)
	}
	if !result.FarmAvailable || result.Phase != "admission_available" || result.InstallationStatus != "unsupported" || result.RuntimeQualified || result.Protocol != "farm-local-checks-worker/v1" || !referenceDigest.MatchString(result.IdentitySHA256) {
		t.Fatal(result)
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
}
