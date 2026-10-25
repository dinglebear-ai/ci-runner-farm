package localchecks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProtectedBindingIsClosedPrivateAndRequiresQualifiedRuntime(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "native-local-checks.json")
	b := ProtectedBinding{Version: 1, Epoch: strings.Repeat("a", 32), Host: "worker", Image: "sha256:" + strings.Repeat("b", 64), Root: filepath.Join(root, "jobs"), RuntimeQualified: true}
	raw, _ := json.Marshal(b)
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadProtectedBinding(path, uint32(os.Getuid())); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadProtectedBinding(path, uint32(os.Getuid())); err == nil {
		t.Fatal("nonprivate binding accepted")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	b.RuntimeQualified = false
	raw, _ = json.Marshal(b)
	_ = os.WriteFile(path, raw, 0600)
	if _, err := loadProtectedBinding(path, uint32(os.Getuid())); err == nil {
		t.Fatal("unqualified runtime enabled")
	}
}

func TestOwnedWorkerDirectoryCannotFollowSymlinkOrUseSharedDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "docker")
	if err := preparePrivateDockerRoot(root, path, uint32(os.Getuid())); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	if err := os.Symlink(other, path); err != nil {
		t.Fatal(err)
	}
	if err := preparePrivateDockerRoot(root, path, uint32(os.Getuid())); err == nil {
		t.Fatal("symlinked worker directory accepted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0777); err != nil {
		t.Fatal(err)
	}
	if err := preparePrivateDockerRoot(root, path, uint32(os.Getuid())); err == nil {
		t.Fatal("shared task root accepted")
	}
}

func protectedFixtureBinding(t *testing.T, qualified bool) string {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "native-local-checks.json")
	b := ProtectedBinding{Version: 1, Epoch: strings.Repeat("a", 32), Host: "worker", Image: "sha256:" + strings.Repeat("b", 64), Root: filepath.Join(root, "jobs"), RuntimeQualified: qualified}
	raw, _ := json.Marshal(b)
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProtectedCanaryPinsCompleteSubmissionWithoutGeneralQualification(t *testing.T) {
	s := submission()
	b := ProtectedBinding{CanarySubmissionSHA256: submissionDigest(s)}
	for _, action := range []string{"create-admit", "execute"} {
		if err := b.authorizeCanary(action, s); err != nil {
			t.Fatal(err)
		}
	}
	mutations := []func(*Submission){func(x *Submission) { x.RequestID += "x" }, func(x *Submission) { x.Commit = strings.Repeat("f", 40) }, func(x *Submission) { x.Base = strings.Repeat("e", 40) }, func(x *Submission) { x.BundleSHA256 = strings.Repeat("d", 64) }, func(x *Submission) { x.CPUs++ }, func(x *Submission) { x.MemoryMiB++ }, func(x *Submission) { x.TimeoutSeconds++ }, func(x *Submission) { x.ScratchMiB++ }}
	for i, mutate := range mutations {
		x := s
		mutate(&x)
		if b.authorizeCanary("execute", x) == nil {
			t.Fatalf("mutation %d accepted", i)
		}
	}
	if b.authorizeCanary("admit-start", s) == nil {
		t.Fatal("canary accepted external admission")
	}
	if (ProtectedBinding{}).authorizeCanary("execute", s) == nil {
		t.Fatal("false without pin accepted")
	}
	if (ProtectedBinding{RuntimeQualified: true}).authorizeCanary("execute", s) != nil {
		t.Fatal("qualified behavior changed")
	}
	if NativeWorkerContract().RuntimeQualified {
		t.Fatal("canary advertised general readiness")
	}
}
