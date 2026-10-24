package nativebackend

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeRunner struct {
	mu      sync.Mutex
	calls   []string
	block   chan struct{}
	started chan struct{}
	reply   string
}

func (f *fakeRunner) Run(ctx context.Context, action string, args []string, override string) (string, error) {
	f.mu.Lock()
	f.calls = append(f.calls, action)
	f.mu.Unlock()
	if f.started != nil {
		select {
		case f.started <- struct{}{}:
		default:
		}
	}
	if f.block != nil {
		select {
		case <-f.block:
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
	if f.reply != "" {
		return f.reply, nil
	}
	return `{}`, nil
}
func TestTypedCommandsRejectInjectionAndMissingConfirmation(t *testing.T) {
	for _, r := range []Request{{Action: "scale", Args: []string{"1;rm -rf /"}}, {Action: "scale", Args: []string{"65"}}, {Action: "stop"}, {Action: "recycle", Args: []string{"../../foreign"}, Confirm: true}, {Action: "prune-completed-docker", Args: []string{"--apply"}}, {Action: "arbitrary-shell"}} {
		if _, _, err := ValidateOperation(r); err == nil {
			t.Fatalf("accepted unsafe request: %s", r.Action)
		}
	}
	if action, _, err := ValidateOperation(Request{Action: "scale", Args: []string{"2"}}); err != nil || action != "scale" {
		t.Fatal(err)
	}
}
func TestConcurrentJobsAreRefusedAndUnloadClosesAdmission(t *testing.T) {
	f := &fakeRunner{block: make(chan struct{}), started: make(chan struct{}, 1)}
	s := New(f, t.TempDir(), t.TempDir())
	defer s.Shutdown()
	if !s.Handle(Request{Action: "start"}).OK {
		t.Fatal("start refused")
	}
	<-f.started
	if r := s.Handle(Request{Action: "scale", Args: []string{"2"}}); r.OK || r.Error != "backend_busy" {
		t.Fatal("queued overlapping mutation")
	}
	if r := s.Handle(Request{Action: "prepare-unload"}); r.OK || r.Error != "active_job_prevents_unload" {
		t.Fatal("unload admitted active work")
	}
	if r := s.Handle(Request{Action: "start"}); r.OK || r.Error != "backend_quiesced" {
		t.Fatal("gate reopened")
	}
	close(f.block)
	s.wg.Wait()
	f.block = nil
	if !s.Handle(Request{Action: "abort-unload"}).OK {
		t.Fatal("abort failed")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.calls) != 1 {
		t.Fatal("expired queued mutation ran")
	}
}
func TestCredentialWritesArePrivateAtomicAndNotReturned(t *testing.T) {
	dir := t.TempDir()
	s := New(&fakeRunner{}, dir, t.TempDir())
	defer s.Shutdown()
	secret := "ghp_abcdefghijklmnopqrstuvwxyz123456"
	response := s.Handle(Request{Action: "set-credential", Kind: "github-token", Value: secret})
	if !response.OK {
		t.Fatal(response)
	}
	s.wg.Wait()
	b, err := os.ReadFile(filepath.Join(dir, "token"))
	if err != nil || string(b) != secret {
		t.Fatal("credential not written")
	}
	info, _ := os.Stat(filepath.Join(dir, "token"))
	if info.Mode().Perm() != 0600 {
		t.Fatal("credential mode")
	}
	status := s.Handle(Request{Action: "job-status"})
	bytes, _ := json.Marshal(status)
	if strings.Contains(string(bytes), secret) {
		t.Fatal("credential escaped to status")
	}
	if s.redact("failed "+secret) != "failed [REDACTED]" {
		t.Fatal("literal redaction failed")
	}
}
func TestFailedFleetObservationNeverAllowsUnload(t *testing.T) {
	s := New(&fakeRunner{reply: `{"count":1,"runners":[{}]}`}, t.TempDir(), t.TempDir())
	defer s.Shutdown()
	if r := s.Handle(Request{Action: "prepare-unload"}); r.OK || r.Error != "running_fleet_prevents_unload" {
		t.Fatal("live fleet orphaned")
	}
}
func TestCancelledJobRetainsAnUncertainEffectsWarning(t *testing.T) {
	f := &fakeRunner{block: make(chan struct{}), started: make(chan struct{}, 1)}
	s := New(f, t.TempDir(), t.TempDir())
	defer s.Shutdown()
	s.Handle(Request{Action: "start"})
	<-f.started
	if !s.Handle(Request{Action: "cancel", Confirm: true}).OK {
		t.Fatal("cancel refused")
	}
	s.wg.Wait()
	r := s.Handle(Request{Action: "job-status"})
	bytes, _ := json.Marshal(r)
	if !strings.Contains(string(bytes), "cancelled") || !strings.Contains(string(bytes), "partial effects") {
		t.Fatal("cancel falsely claimed cleanup")
	}
}
func TestManagedDirectoriesRefuseSymlinkAndWritableOwnership(t *testing.T) {
	dir := t.TempDir()
	if err := CheckDirectory(dir, uint32(os.Geteuid())); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(dir, link); err != nil {
		t.Fatal(err)
	}
	if CheckDirectory(link, uint32(os.Geteuid())) == nil {
		t.Fatal("symlink admitted")
	}
	if err := os.Chmod(dir, 0777); err != nil {
		t.Fatal(err)
	}
	if CheckDirectory(dir, uint32(os.Geteuid())) == nil {
		t.Fatal("writable directory admitted")
	}
}
func TestEngineProjectionUsesOnlyOwnedRuntimeSources(t *testing.T) {
	dir := t.TempDir()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	e := &Engine{Root: dir, Executable: executable}
	if err = e.Extract(); err != nil {
		t.Fatal(err)
	}
	authored := "../../src/usr/local/emhttp/plugins/ci-runner-farm"
	count := 0
	err = filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		if strings.HasSuffix(rel, ".page") || strings.HasSuffix(rel, "exec.php") {
			return errors.New("classic UI bundled")
		}
		actual, _ := os.ReadFile(path)
		want, err := os.ReadFile(filepath.Join(authored, rel))
		if err != nil || string(actual) != string(want) {
			return errors.New("generated engine projection is stale")
		}
		count++
		return nil
	})
	if err != nil || count < 10 {
		t.Fatalf("projection invalid: %v (%d files)", err, count)
	}
}
func TestRealEmbeddedConfigurationReportDoesNotNeedDockerOrGitHub(t *testing.T) {
	e := &Engine{Root: t.TempDir(), Config: t.TempDir(), Runtime: t.TempDir(), CapacityRoot: t.TempDir(), Executable: "/bin/false"}
	if err := e.Extract(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := e.Run(ctx, "native-config-json", nil, "")
	if err != nil {
		t.Fatalf("config report failed: %v %s", err, out)
	}
	var values map[string]string
	if json.Unmarshal([]byte(out), &values) != nil || values["GH_SCOPE"] != "repo" {
		t.Fatalf("invalid real report: %s", out)
	}
	for key := range values {
		if strings.HasPrefix(key, "GITLAB") || strings.Contains(key, "TOKEN") {
			t.Fatal("private/provider-incompatible config exported")
		}
	}
}

func TestActiveProgressRedactsCredentialRemovedDuringOperation(t *testing.T) {
	f := &fakeRunner{block: make(chan struct{}), started: make(chan struct{}, 1)}
	config, runtime := t.TempDir(), t.TempDir()
	secret := "registry-private-test-secret"
	if err := os.WriteFile(filepath.Join(config, "registry-token"), []byte(secret), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(runtime, "native-operation.log"), []byte("previous private output"), 0600); err != nil {
		t.Fatal(err)
	}
	s := New(f, config, runtime)
	defer s.Shutdown()
	if !s.Handle(Request{Action: "start"}).OK {
		t.Fatal("start rejected")
	}
	<-f.started
	prior, _ := os.ReadFile(filepath.Join(runtime, "native-operation.log"))
	if len(prior) != 0 {
		t.Fatal("previous operation log leaked into new job")
	}
	if err := os.Remove(filepath.Join(config, "registry-token")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(runtime, "native-operation.log"), []byte("progress "+secret), 0600); err != nil {
		t.Fatal(err)
	}
	report, _ := json.Marshal(s.Handle(Request{Action: "job-status"}))
	if strings.Contains(string(report), secret) || !strings.Contains(string(report), "REDACTED") {
		t.Fatal("removed credential escaped active progress")
	}
	report, _ = json.Marshal(s.Handle(Request{Action: "build-log"}))
	if strings.Contains(string(report), secret) {
		t.Fatal("removed credential escaped live build log")
	}
	close(f.block)
	s.wg.Wait()
	report, _ = json.Marshal(s.Handle(Request{Action: "build-log"}))
	if strings.Contains(string(report), secret) {
		t.Fatal("removed credential escaped retained build log")
	}
}

func TestSlowObservationRefusesBacklogAndQuiescesImmediately(t *testing.T) {
	f := &fakeRunner{block: make(chan struct{}), started: make(chan struct{}, 1)}
	s := New(f, t.TempDir(), t.TempDir())
	defer s.Shutdown()
	done := make(chan Response, 1)
	go func() { done <- s.Handle(Request{Action: "status-json"}) }()
	<-f.started
	start := time.Now()
	for i := 0; i < 3; i++ {
		if r := s.Handle(Request{Action: "status-json"}); r.OK || r.Error != "backend_busy" {
			t.Fatal("inspection was queued", r)
		}
	}
	if r := s.Handle(Request{Action: "prepare-unload"}); r.OK || r.Error != "inspection_prevents_unload" {
		t.Fatal("unload waited behind inspection", r)
	}
	if r := s.Handle(Request{Action: "start"}); r.OK || r.Error != "backend_quiesced" {
		t.Fatal("quiescence did not close admission", r)
	}
	if time.Since(start) > time.Second {
		t.Fatal("busy admission blocked")
	}
	close(f.block)
	<-done
	f.mu.Lock()
	n := len(f.calls)
	f.mu.Unlock()
	if n != 1 {
		t.Fatal("expired observation launched", n)
	}
}
