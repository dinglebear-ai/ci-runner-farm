package localchecks

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// OwnerVerifier revalidates the opaque reservation against the same worker's
// authoritative admission owner. Implementations must verify live ownership,
// epoch and enforced aggregate limits, not just compare receipt strings.
type OwnerVerifier interface {
	Verify(context.Context, Reservation) error
}

// Invocation is a fixed Core-owned workload, not a caller-selected shell command.
// The worker's execution owner must keep admission held through terminal result,
// cancellation and cleanup. This value does not itself execute or release work.
type Invocation struct {
	Executable       string
	Arguments        []string
	WorkingDirectory string
}

// Prepare validates the transferred checkout and exact bundle before exposing
// the fixed checks-only entrypoint. Paths come from trusted worker configuration,
// never a network submission. Transfer remains owned by the existing coordinator.
func Prepare(ctx context.Context, root, bundle string, s Submission, r Reservation, owner OwnerVerifier) (Invocation, error) {
	if err := s.Validate(); err != nil {
		return Invocation{}, err
	}
	if owner == nil || !r.matches(s) || !identifier.MatchString(r.Host) {
		return Invocation{}, errors.New("local_checks_reservation_receipt_mismatch")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := owner.Verify(ctx, r); err != nil {
		return Invocation{}, errors.New("local_checks_owner_verification_failed")
	}
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil || !filepath.IsAbs(root) || filepath.Clean(root) != root || canonical != root {
		return Invocation{}, errors.New("local_checks_canonical_checkout_required")
	}
	info, err := os.Lstat(bundle)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 2<<30 {
		return Invocation{}, errors.New("local_checks_bundle_unavailable")
	}
	f, err := os.Open(bundle)
	if err != nil {
		return Invocation{}, errors.New("local_checks_bundle_unavailable")
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return Invocation{}, errors.New("local_checks_bundle_changed")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, io.LimitReader(f, 2<<30+1)); err != nil || hex.EncodeToString(hash.Sum(nil)) != s.BundleSHA256 {
		return Invocation{}, errors.New("local_checks_bundle_digest_mismatch")
	}
	checks := []struct {
		args []string
		want string
	}{
		{[]string{"rev-parse", "--show-toplevel"}, root},
		{[]string{"rev-parse", "HEAD"}, s.Commit},
		{[]string{"cat-file", "-t", s.Base}, "commit"},
		{[]string{"status", "--porcelain", "--untracked-files=all"}, ""},
	}
	for _, check := range checks {
		out, err := gitRead(ctx, root, check.args...)
		if err != nil || out != check.want {
			return Invocation{}, errors.New("local_checks_checkout_identity_mismatch")
		}
	}
	origin, err := gitRead(ctx, root, "remote", "get-url", "origin")
	if err != nil || (origin != "https://github.com/unraid/core.git" && origin != "https://github.com/unraid/core" && origin != "git@github.com:unraid/core.git") {
		return Invocation{}, errors.New("local_checks_repository_mismatch")
	}
	if _, err := gitRead(ctx, root, "merge-base", s.Commit, s.Base); err != nil {
		return Invocation{}, errors.New("local_checks_base_history_missing")
	}
	entry := filepath.Join(root, "core/scripts/local_ci_container.sh")
	entryResolved, err := filepath.EvalSymlinks(entry)
	if err != nil || entryResolved != entry {
		return Invocation{}, errors.New("local_checks_container_entrypoint_unavailable")
	}
	entryInfo, err := os.Stat(entry)
	if err != nil || !entryInfo.Mode().IsRegular() || entryInfo.Mode().Perm()&0111 == 0 {
		return Invocation{}, errors.New("local_checks_container_entrypoint_unavailable")
	}
	// Revalidate after potentially expensive hashing/Git work. A reservation may
	// have expired while the source was being checked.
	if err := ctx.Err(); err != nil {
		return Invocation{}, err
	}
	if err := owner.Verify(ctx, r); err != nil {
		return Invocation{}, errors.New("local_checks_owner_verification_failed")
	}
	if err := ctx.Err(); err != nil {
		return Invocation{}, err
	}
	return Invocation{Executable: entry, Arguments: []string{"checks", s.Commit, s.Base}, WorkingDirectory: root}, nil
}

func (r Reservation) matches(s Submission) bool {
	return r.RequestID == s.RequestID && r.Commit == s.Commit && r.Base == s.Base && r.BundleSHA256 == s.BundleSHA256 && r.CPUs == s.CPUs && r.MemoryMiB == s.MemoryMiB && r.ScratchMiB == s.ScratchMiB && r.TimeoutSeconds == s.TimeoutSeconds && r.Handle != ""
}

type boundedOutput struct{ bytes.Buffer }

func (w *boundedOutput) Write(p []byte) (int, error) {
	if w.Len()+len(p) > 16384 {
		return 0, errors.New("git output exceeded bound")
	}
	return w.Buffer.Write(p)
}
func gitRead(ctx context.Context, root string, args ...string) (string, error) {
	args = append([]string{"-c", "core.fsmonitor=false", "-C", root}, args...)
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0"}
	var output boundedOutput
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return strings.TrimSpace(output.String()), nil
}
