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
	fixtureDir := t.TempDir()
	fixture := filepath.Join(fixtureDir, "checks")
	if err = os.WriteFile(fixture, []byte("#!/bin/sh\n# unsupported fixture uses observed adapter transport\n"), 0700); err != nil {
		t.Fatal(err)
	}
	python := filepath.Join(fixtureDir, "python3")
	body := "#!/bin/sh\ntest \"$EX_STANDARDS_TOKEN\" = fixture-private-transport || exit 71\ntest \"$1\" = -c || exit 72\nprintf '%s' \"$2\" | sha256sum | cut -d ' ' -f 1\nshift 2\nprintf '<%s>\\n' \"$@\"\n"
	if err = os.WriteFile(python, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	script := original.Args[len(original.Args)-4]
	script = strings.ReplaceAll(script, "/workspace/source/core/scripts/local_ci_container.sh", strconv.Quote(fixture))
	command := exec.Command("/bin/sh", "-c", script, "farm-checks", s.Commit, s.Base)
	command.Stdin = original.Stdin
	command.Env = []string{"PATH=" + fixtureDir + ":" + os.Getenv("PATH"), "FARM_CHECKS_CPUS=" + strconv.FormatUint(uint64(s.CPUs), 10), "FARM_CHECKS_MEMORY_BYTES=" + strconv.FormatUint(s.MemoryMiB<<20, 10), "FARM_CHECKS_TIMEOUT=" + strconv.FormatUint(uint64(s.TimeoutSeconds), 10)}
	output, err := command.CombinedOutput()
	sum := sha256.Sum256([]byte(observedCurrentCore))
	want := hex.EncodeToString(sum[:]) + "\n<" + s.Commit + ">\n<" + s.Base + ">\n<" + strconv.FormatUint(uint64(s.CPUs), 10) + ">\n<" + strconv.FormatUint(s.MemoryMiB<<20, 10) + ">\n<" + strconv.FormatUint(uint64(s.TimeoutSeconds), 10) + ">\n"
	if err != nil || string(output) != want {
		t.Fatalf("exact observed program/commits/budgets not preserved: %q %v", output, err)
	}

}

func TestV1ChecksPreparesUsingAuthoredWrapperBeforeContractChecks(t *testing.T) {
	for _, failSetup := range []bool{false, true} {
		t.Run(strconv.FormatBool(failSetup), func(t *testing.T) {
			s := submission()
			original, err := dockerChecksCommand(context.Background(), strings.Repeat("d", 64), s, []string{"EX_STANDARDS_TOKEN=private-fixture-value"})
			if err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			dir := filepath.Join(root, "core", "scripts")
			if err = os.MkdirAll(dir, 0700); err != nil {
				t.Fatal(err)
			}
			entry := filepath.Join(dir, "local_ci_container.sh")
			calls := filepath.Join(root, "calls")
			body := "#!/bin/bash\n# local-ci-resource-contract: 1\n" +
				"test \"$EX_STANDARDS_TOKEN\" = private-fixture-value || exit 71\n" +
				"printf '%s:%s:%s:%s:%s:%s\\n' \"$1\" \"$2\" \"$3\" \"${CORE_LOCAL_CI_RESOURCE_CONTRACT-unset}\" \"${CORE_LOCAL_CI_ADMITTED_CPUS-unset}\" \"${CORE_LOCAL_CI_ADMITTED_MEMORY_BYTES-unset}\" >> \"$FIXTURE_CALLS\"\n" +
				"if test \"$1\" = setup && test \"${FIXTURE_SETUP_FAIL-0}\" = 1; then exit 79; fi\n"
			if err = os.WriteFile(entry, []byte(body), 0700); err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"local_ci_linux.sh", "local_ci_resources.py"} {
				if err = os.WriteFile(filepath.Join(dir, name), []byte("# local-ci-resource-contract: 1\n"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			script := original.Args[len(original.Args)-4]
			script = strings.ReplaceAll(script, "/workspace/source", root)
			cmd := exec.Command("/bin/sh", "-c", script, "farm-checks", s.Commit, s.Base)
			cmd.Stdin = original.Stdin
			cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "FIXTURE_CALLS=" + calls, "FARM_CHECKS_CPUS=" + strconv.Itoa(int(s.CPUs)), "FARM_CHECKS_MEMORY_BYTES=" + strconv.FormatUint(s.MemoryMiB<<20, 10), "CORE_LOCAL_CI_RESOURCE_CONTRACT=1", "CORE_LOCAL_CI_ADMITTED_CPUS=999", "CORE_LOCAL_CI_ADMITTED_MEMORY_BYTES=999"}
			if failSetup {
				cmd.Env = append(cmd.Env, "FIXTURE_SETUP_FAIL=1")
			}
			output, runErr := cmd.CombinedOutput()
			if len(output) != 0 {
				t.Fatalf("unexpected output %q", output)
			}
			data, err := os.ReadFile(calls)
			if err != nil {
				t.Fatal(err)
			}
			want := "setup:" + s.Commit + ":" + s.Base + ":unset:unset:unset\n"
			if failSetup {
				if runErr == nil || cmd.ProcessState.ExitCode() != 79 {
					t.Fatalf("setup failure lost: %v", runErr)
				}
			} else {
				if runErr != nil {
					t.Fatal(runErr)
				}
				want += "checks:" + s.Commit + ":" + s.Base + ":1:" + strconv.Itoa(int(s.CPUs)) + ":" + strconv.FormatUint(s.MemoryMiB<<20, 10) + "\n"
			}
			if string(data) != want {
				t.Fatalf("wrong authored preparation/checks order: %q", data)
			}
		})
	}
}

func TestV1ChecksRefusesPartialResourceContractBeforeAnyWrapperCall(t *testing.T) {
	s := submission()
	original, err := dockerChecksCommand(context.Background(), strings.Repeat("d", 64), s, nil)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	scripts := filepath.Join(root, "core", "scripts")
	if err = os.MkdirAll(scripts, 0700); err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(scripts, "local_ci_container.sh")
	if err = os.WriteFile(entry, []byte("#!/bin/bash\n# local-ci-resource-contract: 1\necho WRAPPER_MUST_NOT_RUN\n"), 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"local_ci_linux.sh", "local_ci_resources.py"} {
		if err = os.WriteFile(filepath.Join(scripts, name), []byte("old helper\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	script := strings.ReplaceAll(original.Args[len(original.Args)-4], "/workspace/source", root)
	cmd := exec.Command("/bin/sh", "-c", script, "farm-checks", s.Commit, s.Base)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH")}
	cmd.Stdin = original.Stdin
	out, err := cmd.CombinedOutput()
	if err == nil || cmd.ProcessState.ExitCode() != 76 || !strings.Contains(string(out), "local_checks_core_resource_contract_incomplete") || strings.Contains(string(out), "WRAPPER_MUST_NOT_RUN") {
		t.Fatalf("partial source entered execution: %q %v", out, err)
	}
}
