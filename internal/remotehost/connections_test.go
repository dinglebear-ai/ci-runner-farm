package remotehost

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func privateRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return root
}

func endpoint(t *testing.T) Endpoint {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return Endpoint{Host: "192.0.2.10", User: "qa-operator", Port: 22, HostPublicKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key))), ConfirmedFingerprint: ssh.FingerprintSHA256(key)}
}

func TestProtectedConnectionPinsHostAndIsolatesActor(t *testing.T) {
	root := privateRoot(t)
	view, err := Create(root, "core-alice", endpoint(t))
	if err != nil {
		t.Fatal(err)
	}
	views, err := List(root, "core-alice")
	if err != nil || len(views) != 1 || views[0] != view {
		t.Fatalf("persisted receipt readback failed: %v", err)
	}
	other, err := List(root, "core-bob")
	if err != nil || len(other) != 0 {
		t.Fatal("cross-owner inventory")
	}
	if strings.Contains(view.PublicKey, "PRIVATE") || view.Reference == "" {
		t.Fatalf("unsafe public view: %+v", view)
	}
	connection, err := Load(root, "core-alice", view.Reference)
	if err != nil {
		t.Fatal(err)
	}
	command, err := connection.TransportCommand(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(command.Args, " ")
	for _, want := range []string{"StrictHostKeyChecking=yes", "BatchMode=yes", "IdentitiesOnly=yes", "python3"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %s", want)
		}
	}
	if strings.Contains(joined, "accept-new") {
		t.Fatal("implicit host trust")
	}
	if _, err = Load(root, "core-bob", view.Reference); err == nil {
		t.Fatal("cross-owner connection access")
	}
	if _, err = Load(root, "core-alice", "../../other"); err == nil {
		t.Fatal("unsafe reference")
	}
	if _, err = Load(root, "", view.Reference); err == nil {
		t.Fatal("missing authenticated actor")
	}
}

func TestCreateRejectsUnverifiedHostBeforeWriting(t *testing.T) {
	root := privateRoot(t)
	e := endpoint(t)
	e.ConfirmedFingerprint = "SHA256:wrong"
	if _, err := Create(root, "core-alice", e); err == nil {
		t.Fatal("unverified host pin accepted")
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatalf("failed create retained credentials: %v %v", entries, err)
	}
	e = endpoint(t)
	e.Host = "-oProxyCommand=bad"
	if _, err = Create(root, "core-alice", e); err == nil {
		t.Fatal("option injection accepted")
	}
}

func TestLoadRefusesSymlinkOrExposedKey(t *testing.T) {
	root := privateRoot(t)
	view, err := Create(root, "core-alice", endpoint(t))
	if err != nil {
		t.Fatal(err)
	}
	dir := connectionDirectory(root, "core-alice", view.Reference)
	key := filepath.Join(dir, "identity")
	file, err := os.Open(key)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err = file.Chmod(0o644); err != nil {
		t.Fatal(err)
	}
	if _, err = Load(root, "core-alice", view.Reference); err == nil {
		t.Fatal("public private key accepted")
	}
	if err = os.Remove(key); err != nil {
		t.Fatal(err)
	}
	if err = os.Symlink(filepath.Join(root, "foreign"), key); err != nil {
		t.Fatal(err)
	}
	if _, err = Load(root, "core-alice", view.Reference); err == nil {
		t.Fatal("symlink key accepted")
	}
}

func TestRemoteStatusDeadlineIsBounded(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := Status(ctx, t.TempDir(), "core-alice", "bad-ref"); err == nil {
		t.Fatal("missing reference should fail before network")
	}
}

func TestStatusHonorsCallerDeadlineWithoutNetwork(t *testing.T) {
	root := privateRoot(t)
	view, err := Create(root, "core-alice", endpoint(t))
	if err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	if err = os.WriteFile(filepath.Join(bin, "ssh"), []byte("#!/bin/sh\nexec sleep 30\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	script, err := os.Open(filepath.Join(bin, "ssh"))
	if err != nil {
		t.Fatal(err)
	}
	defer script.Close()
	if err = script.Chmod(0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Millisecond)
	defer cancel()
	started := time.Now()
	if _, err = Status(ctx, root, "core-alice", view.Reference); err == nil {
		t.Fatal("hung SSH reported success")
	}
	if time.Since(started) > 2*time.Second {
		t.Fatal("caller deadline not bounded")
	}
}

func TestRemoteFailuresReturnClosedActionableCategories(t *testing.T) {
	for _, fixture := range []struct{ message, code string }{
		{"ssh: Host key verification failed.", "remote_host_identity_rejected"},
		{"Permission denied (publickey).", "remote_authentication_failed"},
		{"context deadline exceeded", "remote_connection_timeout"},
		{"qa-vm-service: command not found", "remote_service_missing"},
		{"connect: Connection refused", "remote_connection_unavailable"},
		{"untrusted remote output with private values", "remote_protocol_error"},
	} {
		if got := statusFailureCode(errors.New(fixture.message)); got != fixture.code {
			t.Fatalf("got %s want %s", got, fixture.code)
		}
	}
}

func TestCoreURLCannotRedirectTheNativeInstallLink(t *testing.T) {
	e := endpoint(t)
	for _, value := range []string{"javascript:alert(1)", "https://other.invalid", "https://user:secret@192.0.2.10", "https://192.0.2.10/plugins?install=other"} {
		e.CoreURL = value
		if _, err := validateEndpoint(&e); err == nil {
			t.Fatal("unsafe target Core URL accepted", value)
		}
	}
	e.CoreURL = "https://192.0.2.10:8443"
	if _, err := validateEndpoint(&e); err != nil {
		t.Fatal(err)
	}
}

func TestConcurrentConnectionAdmissionPreservesExistingKeysAndLimit(t *testing.T) {
	root := privateRoot(t)
	e := endpoint(t)
	actor := "core-concurrent"
	for i := 0; i < 127; i++ {
		if _, err := Create(root, actor, e); err != nil {
			t.Fatal(err)
		}
	}
	original := rand.Reader
	gate := &admissionRandomGate{reader: original, release: make(chan struct{})}
	timer := time.AfterFunc(100*time.Millisecond, func() { gate.once.Do(func() { close(gate.release) }) })
	defer timer.Stop()
	rand.Reader = gate
	defer func() { rand.Reader = original }()
	start := make(chan struct{})
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() { <-start; _, err := Create(root, actor, e); results <- err }()
	}
	close(start)
	admitted := 0
	for i := 0; i < 8; i++ {
		if <-results == nil {
			admitted++
		}
	}
	entries, err := os.ReadDir(actorDirectory(root, actor))
	if err != nil {
		t.Fatal(err)
	}
	if admitted != 1 || len(entries) != 128 {
		t.Fatalf("concurrent admission exceeded bound: admitted=%d retained=%d", admitted, len(entries))
	}
	if views, err := List(root, actor); err != nil || len(views) != 128 {
		t.Fatalf("retained keys lost/unreadable: %d %v", len(views), err)
	}
}

type admissionRandomGate struct {
	reader  io.Reader
	calls   atomic.Int32
	release chan struct{}
	once    sync.Once
}

func (g *admissionRandomGate) Read(p []byte) (int, error) {
	if g.calls.Add(1) == 8 {
		g.once.Do(func() { close(g.release) })
	}
	<-g.release
	return g.reader.Read(p)
}

func TestListWaitsForCredentialPublicationUnderActorLease(t *testing.T) {
	root := privateRoot(t)
	actor := "core-publication"
	view, err := Create(root, actor, endpoint(t))
	if err != nil {
		t.Fatal(err)
	}
	lock, err := os.OpenFile(actorDirectory(root, actor)+".inventory.lock", os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	incomplete := connectionDirectory(root, actor, strings.Repeat("f", 32))
	if err = os.Mkdir(incomplete, 0700); err != nil {
		t.Fatal(err)
	}
	type listing struct {
		views []View
		err   error
	}
	done := make(chan listing, 1)
	go func() { v, e := List(root, actor); done <- listing{v, e} }()
	select {
	case result := <-done:
		t.Fatalf("reader observed partial credential publication: %d %v", len(result.views), result.err)
	case <-time.After(75 * time.Millisecond):
	}
	for _, name := range []string{"identity", "connection.json", "known_hosts"} {
		raw, e := os.ReadFile(filepath.Join(connectionDirectory(root, actor, view.Reference), name))
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(incomplete, name), raw, 0600); e != nil {
			t.Fatal(e)
		}
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-done:
		if result.err != nil || len(result.views) != 2 {
			t.Fatalf("published inventory unreadable: %d %v", len(result.views), result.err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("reader lease did not finish")
	}
}

func TestProbeSeparatesAdmissionFromObservedInstallationAndQualification(t *testing.T) {
	p := Probe{Schema: "farm-remote-host/v1", Hostname: "target", UnraidVersion: "8.0.0", IdentitySHA256: strings.Repeat("a", 64), FarmAvailable: true, Phase: "admission_available", Protocol: "farm-local-checks-worker/v1"}
	if !p.valid() {
		t.Fatal("admission-only observation rejected")
	}
	p.RuntimeQualified = true
	p.RuntimeQualificationStatus = "qualified"
	if p.valid() {
		t.Fatal("runtime advertised without actual installation observation")
	}
	p.Installation = &InstallationSummary{Version: "0.1.0-test", TreeSHA256: strings.Repeat("b", 64), ManifestSHA256: strings.Repeat("c", 64), BackendSHA256: strings.Repeat("d", 64)}
	if !p.valid() {
		t.Fatal("actual installed identity rejected")
	}
	p.Installation.BackendSHA256 = "foreign"
	if p.valid() {
		t.Fatal("invalid helper identity advertised")
	}
}
