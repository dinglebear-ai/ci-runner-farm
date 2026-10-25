package nativebackend

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"github.com/unraid/ci-runner-farm/internal/remotehost"
	"golang.org/x/crypto/ssh"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRemoteHostsStayActorScopedAndNeverReturnPrivateMaterial(t *testing.T) {
	config := t.TempDir()
	if err := os.Chmod(config, 0700); err != nil {
		t.Fatal(err)
	}
	runtime := t.TempDir()
	s := New(&fakeRunner{}, config, runtime)
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	key, _ := ssh.NewPublicKey(pub)
	e := remotehost.Endpoint{Host: "192.0.2.20", User: "root", Port: 22, HostPublicKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key))), ConfirmedFingerprint: ssh.FingerprintSHA256(key)}
	raw, _ := json.Marshal(e)
	if s.Handle(Request{Action: "remote-host-create", Value: string(raw)}).OK {
		t.Fatal("missing actor accepted")
	}
	result := s.Handle(Request{Action: "remote-host-create", Value: string(raw), Values: map[string]string{"actor": "core-alice"}})
	if !result.OK {
		t.Fatal(result)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		s.mu.Lock()
		active := s.active != nil
		s.mu.Unlock()
		if !active {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("connection create did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	listed := s.Handle(Request{Action: "remote-host-list", Values: map[string]string{"actor": "core-alice"}})
	if !listed.OK {
		t.Fatal(listed)
	}
	views := listed.Data.([]remotehost.View)
	if len(views) != 1 {
		t.Fatal(views)
	}
	encoded, _ := json.Marshal(listed)
	if strings.Contains(string(encoded), "PRIVATE") || strings.Contains(string(encoded), filepath.Join(config, "remote-hosts")) {
		t.Fatal("private material exposed")
	}
	other := s.Handle(Request{Action: "remote-host-list", Values: map[string]string{"actor": "core-bob"}})
	if !other.OK || len(other.Data.([]remotehost.View)) != 0 {
		t.Fatal("cross-actor inventory")
	}
	injected := strings.TrimSuffix(string(raw), "}") + `,"command":"arbitrary"}`
	if s.Handle(Request{Action: "remote-host-create", Value: injected, Values: map[string]string{"actor": "core-alice"}}).OK {
		t.Fatal("caller command accepted")
	}
}

func TestRemotePackageActionsRejectUntrustedAuthorityAndPaths(t *testing.T) {
	config := t.TempDir()
	os.Chmod(config, 0700)
	s := New(&fakeRunner{}, config, t.TempDir())
	for _, action := range []string{"remote-package-upload", "remote-package-list", "remote-package-stage", "remote-package-observe"} {
		if s.Handle(Request{Action: action, Value: "browser-input"}).OK {
			t.Fatal(action, "accepted missing actor")
		}
		if s.Handle(Request{Action: action, Values: map[string]string{"actor": "core-alice", "path": "/arbitrary/file"}}).OK {
			t.Fatal(action, "accepted caller filesystem path")
		}
		if s.Handle(Request{Action: action, Values: map[string]string{"actor": "core-alice", "command": "arbitrary"}}).OK {
			t.Fatal(action, "accepted caller command")
		}
	}
	if s.Handle(Request{Action: "remote-package-upload", Value: "eA==", Values: map[string]string{"actor": "core-alice"}}).OK {
		t.Fatal("upload accepted without protected cache binding")
	}
}
