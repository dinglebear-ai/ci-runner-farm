package nativebackend

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func testCompiledInstallation(t *testing.T) map[string]any {
	t.Helper()
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	return map[string]any{"protocol": "farm-native-installation/v1", "version": "0.1.0-test", "treeSHA256": strings.Repeat("a", 64), "manifestSHA256": strings.Repeat("b", 64), "backendSHA256": hex.EncodeToString(sum[:]), "files": 12, "bytes": 1024}
}

func TestInstalledBundleReceiptBindsActualExecutingHelperAndPersists(t *testing.T) {
	config := t.TempDir()
	runtime := t.TempDir()
	s := New(&fakeRunner{}, config, runtime)
	defer s.Shutdown()
	identity := testCompiledInstallation(t)
	raw, _ := json.Marshal(identity)
	response := s.Handle(Request{Action: "remote-installation-register", Value: string(raw)})
	if !response.OK {
		t.Fatalf("actual compiled installation was not recorded: %+v", response)
	}
	info, err := os.Stat(filepath.Join(config, "native-onboarding", "current-installation.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal(info, err)
	}
	next := New(&fakeRunner{}, config, runtime)
	defer next.Shutdown()
	observed := next.Handle(Request{Action: "remote-installation-status"})
	if !observed.OK {
		t.Fatal(observed)
	}
	encoded, _ := json.Marshal(observed.Data)
	var record map[string]any
	if json.Unmarshal(encoded, &record) != nil || record["treeSHA256"] != identity["treeSHA256"] || record["backendSHA256"] != identity["backendSHA256"] || record["observedAt"] == nil {
		t.Fatal(string(encoded))
	}
	identity["backendSHA256"] = strings.Repeat("0", 64)
	changed, _ := json.Marshal(identity)
	if next.Handle(Request{Action: "remote-installation-register", Value: string(changed)}).OK {
		t.Fatal("stale or foreign helper identity admitted")
	}
	for _, request := range []Request{{Action: "remote-installation-register", Value: string(raw), Args: []string{"foreign"}}, {Action: "remote-installation-status", Value: "foreign"}, {Action: "remote-installation-register", Value: strings.TrimSuffix(string(raw), "}") + `,"archiveSHA256":"` + strings.Repeat("c", 64) + `"}`}} {
		if next.Handle(request).OK {
			t.Fatal("unobserved archive or arbitrary identity field admitted", request.Action)
		}
	}
}

func TestInstallationHelperIdentityUsesExecutingImageAfterPathReplacement(t *testing.T) {
	if os.Getenv("FARM_INSTALLATION_IDENTITY_CHILD") == "1" {
		if _, err := os.Stdout.WriteString("ready\n"); err != nil {
			os.Exit(71)
		}
		var one [1]byte
		if _, err := os.Stdin.Read(one[:]); err != nil {
			os.Exit(72)
		}
		digest, err := actualInstallationHelper()
		if err != nil {
			os.Exit(73)
		}
		_, _ = os.Stdout.WriteString(digest + "\n")
		os.Exit(0)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	copyPath := filepath.Join(t.TempDir(), "owned-helper")
	if err = os.WriteFile(copyPath, body, 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, copyPath, "-test.run=^TestInstallationHelperIdentityUsesExecutingImageAfterPathReplacement$")
	command.Env = append(os.Environ(), "FARM_INSTALLATION_IDENTITY_CHILD=1")
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(output)
	if !scanner.Scan() || scanner.Text() != "ready" {
		t.Fatal("helper did not become ready")
	}
	if err = os.Rename(copyPath, copyPath+".retained"); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(copyPath, []byte("replacement-not-executing"), 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(copyPath + ".retained"); err != nil {
		t.Fatal(err)
	}
	_, _ = input.Write([]byte{1})
	_ = input.Close()
	if !scanner.Scan() {
		t.Fatal("missing helper digest")
	}
	got := scanner.Text()
	if err = command.Wait(); err != nil {
		t.Fatal(err)
	}
	expected := sha256.Sum256(body)
	if got != hex.EncodeToString(expected[:]) {
		t.Fatal("identity followed replaced filename instead of the executing image")
	}
}

func TestInstallationReceiptFIFORefusedWithoutBlocking(t *testing.T) {
	path := filepath.Join(t.TempDir(), "current-installation.json")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() { _, err := readInstallation(path); finished <- err }()
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("FIFO receipt accepted")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("FIFO receipt blocked bounded status")
	}
}
