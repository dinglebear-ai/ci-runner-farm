package nativebackend

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMigrationRefusesInstalledClassicBootReplayAndOrphanWorkers(t *testing.T) {
	root := t.TempDir()
	engine := filepath.Join(root, "classic", "runner-farm.sh")
	boot := filepath.Join(root, "classic.plg")
	proc := filepath.Join(root, "proc")
	config := filepath.Join(root, "retained.cfg")
	if err := os.MkdirAll(filepath.Dir(engine), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(proc, "123"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proc, "123", "cmdline"), []byte("/bin/bash\x00"+engine+"\x00boot-autostart\x00dummy-private-value"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{engine, boot, config} {
		if err := os.WriteFile(path, []byte("retained"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	status, err := inspectClassicMigration(t.Context(), engine, boot, proc, config)
	if err != nil || status.Ready || status.Workers != 1 || !status.ClassicInstalled || !status.BootReplay || !status.RetainedConfiguration {
		t.Fatal(status, err)
	}
	report, _ := json.Marshal(status)
	if strings.Contains(string(report), "dummy-private-value") {
		t.Fatal("process arguments escaped migration report")
	}
	for _, path := range []string{engine, boot} {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	status, err = inspectClassicMigration(t.Context(), engine, boot, proc, config)
	if err != nil || status.Ready {
		t.Fatal("orphan classic creator accepted", err)
	}
	if err := os.WriteFile(filepath.Join(proc, "123", "cmdline"), []byte("/usr/bin/stat\x00"+engine), 0600); err != nil {
		t.Fatal(err)
	}
	status, err = inspectClassicMigration(t.Context(), engine, boot, proc, config)
	if err != nil || !status.Ready || !status.RetainedConfiguration {
		t.Fatal("supported retirement lost retained settings", status, err)
	}
	if err := os.WriteFile(boot, nil, 0600); err != nil {
		t.Fatal(err)
	}
	status, err = inspectClassicMigration(t.Context(), engine, boot, proc, config)
	if err != nil || status.Ready {
		t.Fatal("boot replay accepted", status, err)
	}
}
func TestMigrationFailsClosedOnIncompleteWorkerInventory(t *testing.T) {
	root := t.TempDir()
	proc := filepath.Join(root, "proc")
	if err := os.MkdirAll(filepath.Join(proc, "123"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(proc, "123", "cmdline"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectClassicMigration(t.Context(), filepath.Join(root, "engine"), filepath.Join(root, "boot"), proc, filepath.Join(root, "config")); err == nil {
		t.Fatal("incomplete worker inventory accepted")
	}
}

func TestMigrationCommitPinsRetainedConfigurationAndDoesNotCopyCredentials(t *testing.T) {
	root := t.TempDir()
	config := filepath.Join(root, "config")
	receiptPath := filepath.Join(root, "native-migration.json")
	token := filepath.Join(root, "token")
	ledger := filepath.Join(root, "existing-ledger")
	original := []byte("CACHE_ROOT=\"/mnt/cache/existing-farm\"\n")
	for path, data := range map[string][]byte{config: original, token: []byte("private-credential-kept-in-place"), ledger: []byte("original grants and fences")} {
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	sum := sha256.Sum256(original)
	receipt := migrationReceipt{Schema: 1, ConfigSHA256: hex.EncodeToString(sum[:]), CacheRoot: "/mnt/cache/existing-farm", OwnerEpoch: "original-epoch", OwnerSHA256: "original-owner-digest"}
	if err := os.WriteFile(config, []byte("changed configuration"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := commitMigrationReceipt(receiptPath, config, sum, receipt); err == nil {
		t.Fatal("changed retained config committed")
	}
	if _, err := os.Stat(receiptPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("failed migration left completed receipt")
	}
	if err := os.WriteFile(config, original, 0600); err != nil {
		t.Fatal(err)
	}
	if err := commitMigrationReceipt(receiptPath, config, sum, receipt); err != nil {
		t.Fatal(err)
	}
	report, err := os.ReadFile(receiptPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(report), "private-credential") {
		t.Fatal("credential copied into migration metadata")
	}
	info, _ := os.Stat(receiptPath)
	if info.Mode().Perm() != 0600 {
		t.Fatal("migration record is not private")
	}
	if data, _ := os.ReadFile(token); string(data) != "private-credential-kept-in-place" {
		t.Fatal("credential changed")
	}
	if data, _ := os.ReadFile(ledger); string(data) != "original grants and fences" {
		t.Fatal("ledger changed")
	}
}

func TestMigrationRejectsRelativeClassicWorkerAfterRuntimeRetired(t *testing.T) {
	root := t.TempDir()
	engine := filepath.Join(root, "classic", "runner-farm.sh")
	proc := filepath.Join(root, "proc")
	pid := filepath.Join(proc, "321")
	if err := os.MkdirAll(pid, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(engine), filepath.Join(pid, "cwd")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pid, "cmdline"), []byte("/bin/bash\x00./runner-farm.sh\x00watchdog"), 0600); err != nil {
		t.Fatal(err)
	}
	status, err := inspectClassicMigration(t.Context(), engine, filepath.Join(root, "absent.plg"), proc, filepath.Join(root, "absent.cfg"))
	if err != nil || status.Ready || status.Workers != 1 {
		t.Fatal("relative orphan escaped migration inventory", status, err)
	}
}
