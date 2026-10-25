package remotehost

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestActualFixedProbeKeepsInstalledEvidenceWhenRuntimeObservationFails(t *testing.T) {
	for _, runtimeFails := range []bool{false, true} {
		t.Run(fmt.Sprint(runtimeFails), func(t *testing.T) {
			root, err := os.MkdirTemp(os.TempDir(), "fp-")
			if err != nil {
				t.Fatal(err)
			}
			defer os.RemoveAll(root)
			version := filepath.Join(root, "version")
			machine := filepath.Join(root, "machine")
			socket := filepath.Join(root, "backend.sock")
			if err = os.WriteFile(version, []byte("version=\"8.0.0\"\n"), 0600); err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(machine, []byte("owned-probe-fixture\n"), 0600); err != nil {
				t.Fatal(err)
			}
			proposal := strings.Repeat("d", 32)
			host, _ := os.Hostname()
			listener, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			_ = listener.(*net.UnixListener).SetDeadline(time.Now().Add(5 * time.Second))
			finished := make(chan error, 1)
			go func() {
				actions := []string{"local-checks-contract", "job-status", "admission-status", "remote-installation-status", "local-checks-readiness", "remote-setup-applied-status"}
				for _, want := range actions {
					c, e := listener.Accept()
					if e != nil {
						finished <- e
						return
					}
					_ = c.SetDeadline(time.Now().Add(3 * time.Second))
					var request map[string]any
					e = json.NewDecoder(c).Decode(&request)
					if e != nil || request["action"] != want {
						c.Close()
						finished <- fmt.Errorf("unexpected closed query %v %v", request, e)
						return
					}
					data := map[string]any{}
					ok := true
					switch want {
					case "local-checks-contract":
						data["protocol"] = "farm-local-checks-worker/v1"
					case "job-status":
						data["installationIdentity"] = true
						data["appliedSetupVerification"] = true
					case "admission-status":
						data["policyMatches"] = true
					case "remote-installation-status":
						data = map[string]any{"protocol": "farm-native-installation/v1", "version": "0.1.0-test", "treeSHA256": strings.Repeat("a", 64), "manifestSHA256": strings.Repeat("b", 64), "backendSHA256": strings.Repeat("c", 64)}
					case "remote-setup-applied-status":
						if request["value"] != proposal {
							c.Close()
							finished <- fmt.Errorf("wrong exact proposal request %v", request)
							return
						}
						data = map[string]any{"evidence": map[string]any{"protocol": "farm-applied-setup/v1", "proposalID": proposal, "proposalSHA256": strings.Repeat("e", 64), "packageSHA256": strings.Repeat("f", 64), "installedTreeSHA256": strings.Repeat("a", 64), "host": host, "epoch": strings.Repeat("1", 32), "policySHA256": strings.Repeat("2", 64), "settingsProjectionSHA256": strings.Repeat("3", 64), "ledgerPolicyDigest": strings.Repeat("4", 64)}}
					case "local-checks-readiness":
						ok = !runtimeFails
						data["runtimeQualified"] = false
					}
					e = json.NewEncoder(c).Encode(map[string]any{"ok": ok, "data": data})
					c.Close()
					if e != nil {
						finished <- e
						return
					}
				}
				finished <- nil
			}()
			source := strings.NewReplacer("/etc/unraid-version", version, "/etc/machine-id", machine, "/run/unraid-core/plugin-data/ci-runner-farm/backend.sock", socket).Replace(remoteProbeCommand)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "/bin/sh", "-c", source)
			payload, _ := json.Marshal(map[string]string{"proposalID": proposal})
			cmd.Stdin = strings.NewReader(string(payload))
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatal(err, string(output))
			}
			if err = <-finished; err != nil {
				t.Fatal(err)
			}
			var result Probe
			if json.Unmarshal(output, &result) != nil || !result.valid() {
				t.Fatal("invalid real script result", string(output))
			}
			if !result.Configured || result.ConfigurationStatus != "verified" || result.AppliedConfiguration == nil || result.AppliedConfiguration.ProposalID != proposal {
				t.Fatal("applied receipt not linked", result)
			}
			if result.Phase != "admission_available" || result.Installation == nil || result.InstallationStatus != "observed" || result.RuntimeQualified {
				t.Fatal(result)
			}
			want := "unqualified"
			if runtimeFails {
				want = "unavailable"
			}
			if result.RuntimeQualificationStatus != want {
				t.Fatal(result)
			}
		})
	}
}
