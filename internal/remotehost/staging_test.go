package remotehost

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestActualTargetProgramStagesExactBytesAndRefusesReplay(t *testing.T) {
	root := t.TempDir()
	version := filepath.Join(root, "version")
	identity := filepath.Join(root, "machine")
	stageRoot := filepath.Join(root, "stage")
	os.WriteFile(version, []byte("version=\"8.0.0-test\"\n"), 0600)
	os.WriteFile(identity, []byte("fixture-target"), 0600)
	source := strings.TrimSuffix(strings.TrimPrefix(remoteStageCommand, "python3 -c '"), "'")
	source = strings.ReplaceAll(source, "/etc/unraid-version", version)
	source = strings.ReplaceAll(source, "/etc/machine-id", identity)
	source = strings.ReplaceAll(source, remoteBootstrapRoot, stageRoot)
	source = strings.ReplaceAll(source, "os.geteuid()!=0", "os.geteuid()!="+strconv.Itoa(os.Geteuid()))
	source = strings.ReplaceAll(source, "s.st_uid!=0", "s.st_uid!="+strconv.Itoa(os.Geteuid()))
	raw := fixturePackage(t, "ci-runner-farm")
	sum := sha256.Sum256(raw)
	digest := hex.EncodeToString(sum[:])
	op := strings.Repeat("a", 32)
	header, _ := json.Marshal(map[string]any{"protocol": "farm-native-package-stage/v1", "operationID": op, "sha256": digest, "bytes": len(raw)})
	run := func() ([]byte, error) {
		ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "python3", "-c", source)
		cmd.Stdin = bytes.NewReader(append(append(header, '\n'), raw...))
		return cmd.CombinedOutput()
	}
	out, err := run()
	if err != nil {
		t.Fatalf("%s %v", out, err)
	}
	var receipt StageReceipt
	if json.Unmarshal(out, &receipt) != nil || receipt.SHA256 != digest || receipt.State != "staged_waiting_native_approval" {
		t.Fatal(string(out))
	}
	stored, err := os.ReadFile(receipt.TargetPath)
	if err != nil || !bytes.Equal(stored, raw) {
		t.Fatal("target bytes differ", err)
	}
	if _, err = run(); err == nil {
		t.Fatal("same operation was replayed")
	}
	again, _ := os.ReadFile(receipt.TargetPath)
	if !bytes.Equal(again, raw) {
		t.Fatal("replay replaced artifact")
	}
	if _, err = os.Stat(filepath.Join(stageRoot, op, "stage-receipt.json")); err != nil {
		t.Fatal(err)
	}
}

func TestActualObservationRecoversLostResponseWithoutWritingTarget(t *testing.T) {
	root := t.TempDir()
	stage := filepath.Join(root, "stage")
	op := strings.Repeat("b", 32)
	task := filepath.Join(stage, op)
	if err := os.MkdirAll(task, 0700); err != nil {
		t.Fatal(err)
	}
	identity := filepath.Join(root, "machine")
	os.WriteFile(identity, []byte("peer"), 0600)
	raw := []byte("exact immutable package")
	sum := sha256.Sum256(raw)
	digest := hex.EncodeToString(sum[:])
	metadata := map[string]any{"protocol": "farm-native-package-stage/v1", "operationID": op, "sha256": digest, "bytes": len(raw)}
	intent := map[string]any{}
	for k, v := range metadata {
		intent[k] = v
	}
	intent["state"] = "before_receive"
	intent["pid"] = 123
	encoded, _ := json.Marshal(intent)
	os.WriteFile(filepath.Join(task, "stage-intent.json"), encoded, 0600)
	file := filepath.Join(task, "ci-runner-farm.tgz")
	os.WriteFile(file, raw, 0600)
	source := strings.TrimSuffix(strings.TrimPrefix(remoteObserveCommand, "python3 -c '"), "'")
	source = strings.ReplaceAll(source, remoteBootstrapRoot, stage)
	source = strings.ReplaceAll(source, "/etc/machine-id", identity)
	source = strings.ReplaceAll(source, "os.geteuid()!=0", "os.geteuid()!="+strconv.Itoa(os.Geteuid()))
	source = strings.ReplaceAll(source, "s.st_uid!=0", "s.st_uid!="+strconv.Itoa(os.Geteuid()))
	header, _ := json.Marshal(metadata)
	run := func() ([]byte, error) {
		cmd := exec.CommandContext(t.Context(), "python3", "-c", source)
		cmd.Stdin = bytes.NewReader(append(header, '\n'))
		return cmd.CombinedOutput()
	}
	before, _ := os.Stat(file)
	out, err := run()
	if err != nil {
		t.Fatalf("%s %v", out, err)
	}
	var receipt StageReceipt
	if json.Unmarshal(out, &receipt) != nil || receipt.SHA256 != digest || receipt.State != "staged_waiting_native_approval" {
		t.Fatal(string(out))
	}
	after, _ := os.Stat(file)
	if !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("observation changed artifact")
	}
	if _, err = os.Stat(filepath.Join(task, "stage-receipt.json")); !os.IsNotExist(err) {
		t.Fatal("read-only observation wrote target receipt")
	}
	os.WriteFile(file, bytes.Repeat([]byte("x"), len(raw)), 0600)
	if _, err = run(); err == nil {
		t.Fatal("corrupt artifact recovered as success")
	}
	os.Remove(file)
	os.WriteFile(filepath.Join(task, "package.receiving"), raw, 0600)
	if _, err = run(); err == nil {
		t.Fatal("incomplete transfer recovered as success")
	}
}
