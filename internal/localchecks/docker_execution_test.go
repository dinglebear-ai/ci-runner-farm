package localchecks

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestDockerChecksCommandIsFixedAndCredentialUsesOnlyStdin(t *testing.T) {
	s := submission()
	id := strings.Repeat("d", 64)
	token := "private-fixture-value"
	cmd, err := dockerChecksCommand(context.Background(), id, s, []string{"EX_STANDARDS_TOKEN=" + token})
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(cmd.Args, " ")
	if strings.Contains(joined, token) || strings.Contains(strings.Join(cmd.Env, " "), token) {
		t.Fatal("credential exposed outside protected stdin")
	}
	for _, want := range []string{"exec --interactive", id, "/workspace/source/core/scripts/local_ci_container.sh", s.Commit, s.Base} {
		if !strings.Contains(joined, want) {
			t.Fatal(cmd.Args)
		}
	}
	for _, env := range [][]string{{"EX_STANDARDS_TOKEN=bad\nvalue"}, {"GITHUB_TOKEN=not-allowed"}} {
		if _, err := dockerChecksCommand(context.Background(), id, s, env); err == nil {
			t.Fatal("unapproved credential accepted")
		}
	}
}

type stoppableFixture struct {
	*nativeFixtureDriver
	stops int
	fail  bool
}

func (d *stoppableFixture) Stop(context.Context, string) error {
	d.stops++
	if d.fail {
		return errors.New("stop uncertain")
	}
	d.container.Running = false
	d.container.Stopped = true
	return nil
}
func TestNativeExecutionHoldsGrantThroughCallbackAndStopsBeforeRelease(t *testing.T) {
	for _, fail := range []bool{false, true} {
		t.Run(map[bool]string{false: "stopped", true: "uncertain"}[fail], func(t *testing.T) {
			w, d, s := nativeFixture(t)
			driver := &stoppableFixture{nativeFixtureDriver: d, fail: fail}
			w.driver = driver
			receipt, err := w.AdmitStart(context.Background(), s, d.container.ID)
			if err != nil {
				t.Fatal(err)
			}
			r := Reservation{Host: "worker", RequestID: s.RequestID, Commit: s.Commit, Base: s.Base, BundleSHA256: s.BundleSHA256, Handle: receipt.Fence, CPUs: s.CPUs, MemoryMiB: s.MemoryMiB, ScratchMiB: s.ScratchMiB, TimeoutSeconds: s.TimeoutSeconds}
			owner := &nativeExecutionOwner{worker: w, receipt: receipt, host: "worker"}
			err = owner.WithExecution(context.Background(), r, func(ctx context.Context, v OwnerVerifier, _ []string) error {
				if err := v.Verify(ctx, r); err != nil {
					t.Fatal(err)
				}
				snapshot, _ := w.broker.Status(&w.policy)
				if len(snapshot.Grants) != 1 {
					t.Fatal("grant missing during execution")
				}
				return errors.New("workload failure")
			})
			if err == nil || driver.stops != 1 {
				t.Fatal(err, driver.stops)
			}
			snapshot, _ := w.broker.Status(&w.policy)
			if (fail && len(snapshot.Grants) != 1) || (!fail && len(snapshot.Grants) != 0) {
				t.Fatal("unsafe release", snapshot)
			}
		})
	}
}

func TestNativePrepareUsesCanonicalTwoPackManifest(t *testing.T) {
	root, _, s, _ := workerFixture(t)
	snapshot := t.TempDir()
	checkout := filepath.Join(snapshot, "repo")
	if err := os.Rename(root, checkout); err != nil {
		t.Fatal(err)
	}
	manifest := FleetSnapshot{Commit: s.Commit, Base: s.Base, MergeBase: s.Base, Files: map[string]PackArtifact{}}
	for _, name := range []string{"history.pack", "snapshots.pack"} {
		data := []byte("fixture-" + name)
		digest := sha256.Sum256(data)
		manifest.Files[name] = PackArtifact{Bytes: uint64(len(data)), SHA256: hex.EncodeToString(digest[:])}
		if err := os.WriteFile(filepath.Join(snapshot, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	raw, _ := json.MarshalIndent(manifest, "", "  ")
	if err := os.WriteFile(filepath.Join(snapshot, "intent.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	s.BundleSHA256 = manifest.Digest()
	owner := &nativeExecutionOwner{receipt: NativeReceipt{Request: s, Worker: WorkerBinding{SourceRoot: checkout}}}
	inv, err := owner.prepareExecution(context.Background(), checkout, filepath.Join(snapshot, "intent.json"), s, Reservation{})
	if err != nil || inv.Executable != filepath.Join(checkout, "core/scripts/local_ci_container.sh") {
		t.Fatal(inv, err)
	}
	if _, err := owner.prepareExecution(context.Background(), checkout, filepath.Join(snapshot, "different.json"), s, Reservation{}); err == nil {
		t.Fatal("unbound source allowed")
	}
}

func TestNativeExecutionRefusesChangedProtectedWorkerBinding(t *testing.T) {
	w, d, s := nativeFixture(t)
	receipt, err := w.AdmitStart(context.Background(), s, d.container.ID)
	if err != nil {
		t.Fatal(err)
	}
	owner := &nativeExecutionOwner{worker: w, receipt: receipt, host: "worker"}
	r := Reservation{Host: "worker", RequestID: s.RequestID, Commit: s.Commit, Base: s.Base, BundleSHA256: s.BundleSHA256, Handle: receipt.Fence, CPUs: s.CPUs, MemoryMiB: s.MemoryMiB, ScratchMiB: s.ScratchMiB, TimeoutSeconds: s.TimeoutSeconds}
	altered := receipt
	altered.Worker.SourceRoot = "/changed/source"
	if err = w.save(altered); err != nil {
		t.Fatal(err)
	}
	if err := owner.Verify(context.Background(), r); err == nil {
		t.Fatal("changed protected worker binding accepted")
	}
}

func TestDockerChecksShellTransportsExactSHAsAndCredentialViaStdin(t *testing.T) {
	s := submission()
	token := "fixture-private-transport"
	original, err := dockerChecksCommand(context.Background(), strings.Repeat("d", 64), s, []string{"EX_STANDARDS_TOKEN=" + token})
	if err != nil {
		t.Fatal(err)
	}
	fixture := filepath.Join(t.TempDir(), "checks")
	// Read the credential only in the fixture process environment and never print it.
	body := "#!/bin/sh\ntest \"$EX_STANDARDS_TOKEN\" = fixture-private-transport || exit 71\nprintf '<%s>\\n' \"$@\"\n"
	if err = os.WriteFile(fixture, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	script := original.Args[len(original.Args)-4]
	script = strings.Replace(script, "exec bash /workspace/source/core/scripts/local_ci_container.sh", "exec "+strconv.Quote(fixture), 1)
	command := exec.Command("/bin/sh", "-c", script, "farm-checks", s.Commit, s.Base)
	command.Stdin = original.Stdin
	command.Env = []string{"PATH=" + os.Getenv("PATH")}
	output, err := command.CombinedOutput()
	want := "<checks>\n<" + s.Commit + ">\n<" + s.Base + ">\n"
	if err != nil || string(output) != want {
		t.Fatalf("exact committed identities not preserved: %q %v", output, err)
	}
}
