package localchecks

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func git(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	b, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

type verifier struct {
	called            bool
	err               error
	calls             int
	failAfter         int
	cancelAfterSecond context.CancelFunc
}

func (v *verifier) Verify(context.Context, Reservation) error {
	v.called = true
	v.calls++
	if v.calls == 2 && v.cancelAfterSecond != nil {
		v.cancelAfterSecond()
	}
	if v.failAfter > 0 && v.calls >= v.failAfter {
		return errors.New("grant expired")
	}
	return v.err
}
func workerFixture(t *testing.T) (string, string, Submission, Reservation) {
	t.Helper()
	root := t.TempDir()
	git(t, root, "init", "--quiet")
	git(t, root, "remote", "add", "origin", "https://github.com/unraid/core.git")
	path := filepath.Join(root, "core", "scripts")
	if err := os.MkdirAll(path, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "local_ci_container.sh"), []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	git(t, root, "add", ".")
	git(t, root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "fixture")
	s := submission()
	s.Commit = git(t, root, "rev-parse", "HEAD")
	s.Commit = s.Commit[:40]
	s.Base = s.Commit
	bundle := filepath.Join(t.TempDir(), "source.bundle")
	git(t, root, "bundle", "create", bundle, "HEAD")
	data, err := os.ReadFile(bundle)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	s.BundleSHA256 = hex.EncodeToString(digest[:])
	r := Reservation{Host: "host", RequestID: s.RequestID, Commit: s.Commit, Base: s.Base, BundleSHA256: s.BundleSHA256, CPUs: s.CPUs, MemoryMiB: s.MemoryMiB, ScratchMiB: s.ScratchMiB, TimeoutSeconds: s.TimeoutSeconds, Handle: "owner-receipt"}
	return root, bundle, s, r
}
func TestWorkerChecksExactCheckoutBundleAndOwnerBeforeReturningInvocation(t *testing.T) {
	root, bundle, s, r := workerFixture(t)
	v := &verifier{}
	inv, err := Prepare(context.Background(), root, bundle, s, r, v)
	if err != nil {
		t.Fatal(err)
	}
	if !v.called || inv.Executable != filepath.Join(root, "core/scripts/local_ci_container.sh") || len(inv.Arguments) != 3 || inv.Arguments[0] != "checks" || inv.Arguments[1] != s.Commit || inv.Arguments[2] != s.Base {
		t.Fatal("wrong invocation", inv)
	}
	if err := os.WriteFile(filepath.Join(root, "core/scripts/local_ci_container.sh"), []byte("changed"), 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := Prepare(context.Background(), root, bundle, s, r, &verifier{}); err == nil {
		t.Fatal("accepted modified runner")
	}
}
func TestWorkerRejectsBundleOrReservationMismatch(t *testing.T) {
	root, bundle, s, r := workerFixture(t)
	bad := r
	bad.MemoryMiB++
	if _, err := Prepare(context.Background(), root, bundle, s, bad, &verifier{}); err == nil {
		t.Fatal("accepted mismatched grant")
	}
	if err := os.WriteFile(bundle, []byte("different bundle"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Prepare(context.Background(), root, bundle, s, r, &verifier{}); err == nil {
		t.Fatal("accepted bundle with wrong digest")
	}
}

func TestWorkerRechecksExpiredOwnerAndRefusesSymlinkCheckout(t *testing.T) {
	root, bundle, s, r := workerFixture(t)
	v := &verifier{failAfter: 2}
	if _, err := Prepare(context.Background(), root, bundle, s, r, v); err == nil || v.calls != 2 {
		t.Fatal("expired owner accepted", err, v.calls)
	}
	link := filepath.Join(t.TempDir(), "checkout")
	if err := os.Symlink(root, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Prepare(context.Background(), link, bundle, s, r, &verifier{}); err == nil {
		t.Fatal("accepted noncanonical checkout")
	}
	git(t, root, "remote", "set-url", "origin", "https://github.com/other/core.git")
	if _, err := Prepare(context.Background(), root, bundle, s, r, &verifier{}); err == nil {
		t.Fatal("accepted unrelated repository")
	}
}

func TestWorkerCancellationDuringFinalGrantCheckCannotExecute(t *testing.T) {
	root, bundle, s, r := workerFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if _, err := Prepare(ctx, root, bundle, s, r, &verifier{cancelAfterSecond: cancel}); err == nil {
		t.Fatal("cancelled preparation returned executable invocation")
	}
}
