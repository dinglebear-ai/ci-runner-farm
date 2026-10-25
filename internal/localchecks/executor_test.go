package localchecks

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// fixtureOwner holds a real exclusive execution lease; it does not claim that
// this test machine supplies Farm/Docker production resource isolation.
type fixtureOwner struct {
	mu            sync.Mutex
	active        bool
	released      bool
	beforeRelease func()
	environment   []string
}

func TestExecutorLogRedactsInjectedCredentialAcrossWrites(t *testing.T) {
	var out bytes.Buffer
	w := &executionOutput{destination: &out, remaining: 4096, cancel: func() {}, secrets: []string{"fixture-private-value"}}
	for _, part := range []string{"before fixture-pri", "vate-value after"} {
		if _, err := w.Write([]byte(part)); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "fixture-private-value") || out.String() != "before [redacted] after" {
		t.Fatal("credential leaked", out.String())
	}
}

func TestExecutorLogLimitCancelsWithoutWritingUnboundedOutput(t *testing.T) {
	var out bytes.Buffer
	cancelled := false
	w := &executionOutput{destination: &out, remaining: 8, cancel: func() { cancelled = true }}
	if _, err := w.Write([]byte("longer than eight bytes")); err == nil || !cancelled || !w.exceeded || out.Len() != 0 {
		t.Fatal("output limit did not stop writer")
	}
}

func TestExecutorLogRedactsIncompleteCredentialAtCancellationBoundary(t *testing.T) {
	var out bytes.Buffer
	w := &executionOutput{destination: &out, remaining: 1024, cancel: func() {}, secrets: []string{"fixture-private-value"}}
	if _, err := w.Write([]byte("before fixture-priv")); err != nil {
		t.Fatal(err)
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	if out.String() != "before [redacted]" {
		t.Fatal("partial credential retained")
	}
}

func (o *fixtureOwner) Verify(context.Context, Reservation) error {
	if !o.active {
		return errors.New("lease not held")
	}
	return nil
}
func (o *fixtureOwner) WithExecution(ctx context.Context, _ Reservation, fn func(context.Context, OwnerVerifier, []string) error) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.active = true
	defer func() { o.active = false; o.released = true }()
	err := fn(ctx, o, o.environment)
	if o.beforeRelease != nil {
		o.beforeRelease()
	}
	return err
}
func executionFixture(t *testing.T, script string) (string, string, Submission, Reservation) {
	root, bundle, s, r := workerFixture(t)
	if err := os.WriteFile(filepath.Join(root, "core/scripts/local_ci_container.sh"), []byte("#!/bin/sh\n"+script+"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	git(t, root, "add", ".")
	git(t, root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "workload")
	s.Commit = git(t, root, "rev-parse", "HEAD")[:40]
	r.Commit = s.Commit
	if err := os.Remove(bundle); err != nil {
		t.Fatal(err)
	}
	git(t, root, "bundle", "create", bundle, "HEAD")
	data, err := os.ReadFile(bundle)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	s.BundleSHA256 = hex.EncodeToString(digest[:])
	r.BundleSHA256 = s.BundleSHA256
	return root, bundle, s, r
}
func TestExecutorRunsFixedWorkloadAndPersistsTerminalEvidenceUnderLease(t *testing.T) {
	root, bundle, s, r := executionFixture(t, `test "$1" = checks; printf 'fixture-checks-passed\n'`)
	owner := &fixtureOwner{}
	evidence := filepath.Join(t.TempDir(), "evidence")
	owner.beforeRelease = func() {
		if _, err := os.Stat(filepath.Join(evidence, s.RequestID, "result.json")); err != nil {
			t.Error("owner released before terminalreceipt", err)
		}
	}
	result, err := Execute(context.Background(), root, bundle, evidence, s, r, owner)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != "passed" || !owner.released || owner.active {
		t.Fatal(result, owner)
	}
	b, err := os.ReadFile(result.LogPath)
	if err != nil || string(b) != "fixture-checks-passed\n" {
		t.Fatal(string(b), err)
	}
	if _, err := os.Stat(result.ReceiptPath); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(result.LogPath); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("log not private")
	}
}
func TestExecutorCancellationStopsOwnedWorkloadAndRetainsResult(t *testing.T) {
	pidpath := filepath.Join(t.TempDir(), "child.pid")
	script := fmt.Sprintf("trap 'kill \"$child\" 2>/dev/null || true; wait \"$child\" 2>/dev/null || true; exit 143' TERM\nsleep 30 & child=$!\nprintf '%%s' \"$child\" > %q\nwait", pidpath)
	root, bundle, s, r := executionFixture(t, script)
	owner := &fixtureOwner{}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	started := time.Now()
	result, err := Execute(ctx, root, bundle, filepath.Join(t.TempDir(), "evidence"), s, r, owner)
	if err == nil || result.Status != "cancelled" || !owner.released || time.Since(started) > 3*time.Second {
		t.Fatal(result, err)
	}
	if _, err := os.Stat(result.ReceiptPath); err != nil {
		t.Fatal(err)
	}
	data, readErr := os.ReadFile(pidpath)
	if readErr != nil {
		t.Fatal("child did not start", readErr)
	}
	pid, parseErr := strconv.Atoi(string(data))
	if parseErr != nil {
		t.Fatal(parseErr)
	}
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatal("owned child survived cancellation", pid, err)
	}
}

func TestExecutorDeadlineProducesTimedOutReceipt(t *testing.T) {
	root, bundle, s, r := executionFixture(t, `trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 143' TERM
sleep 30 & child=$!
wait`)
	s.TimeoutSeconds = 1
	r.TimeoutSeconds = 1
	result, err := Execute(context.Background(), root, bundle, filepath.Join(t.TempDir(), "evidence"), s, r, &fixtureOwner{})
	if err == nil || result.Status != "timed_out" {
		t.Fatal(result, err)
	}
	if _, err := os.Stat(result.ReceiptPath); err != nil {
		t.Fatal(err)
	}
}

func TestExecutorInjectsApprovedEnvironmentAndRedactsRealSubprocessOutput(t *testing.T) {
	root, bundle, s, r := executionFixture(t, `printf 'credential=%s\n' "$EX_STANDARDS_TOKEN"`)
	owner := &fixtureOwner{environment: []string{"EX_STANDARDS_TOKEN=fixture-not-a-real-credential"}}
	result, err := Execute(context.Background(), root, bundle, filepath.Join(t.TempDir(), "evidence"), s, r, owner)
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(result.LogPath)
	if err != nil || string(b) != "credential=[redacted]\n" {
		t.Fatal("approved credential was not redacted")
	}
	owner.environment = []string{"GITHUB_TOKEN=fixture-forbidden-credential"}
	if _, err := Execute(context.Background(), root, bundle, filepath.Join(t.TempDir(), "evidence"), s, r, owner); err == nil {
		t.Fatal("forwarded unauthorized credential")
	}
}
