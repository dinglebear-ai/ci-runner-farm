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
