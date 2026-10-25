package nativebackend

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalChecksBackendExposesContractButRejectsUnboundedCommand(t *testing.T) {
	s := New(&fakeRunner{}, t.TempDir(), t.TempDir())
	defer s.Shutdown()
	response := s.Handle(Request{Action: "local-checks-contract"})
	if !response.OK {
		t.Fatal(response)
	}
	if response = s.Handle(Request{Action: "local-checks", Value: strings.Repeat("x", 16385)}); response.OK {
		t.Fatal("oversize command accepted")
	}
}
func TestNativeEnginePassesFleetFD8AndFixedProtectedBindingToHelper(t *testing.T) {
	root := t.TempDir()
	runtime := filepath.Join(root, "runtime")
	if err := os.Mkdir(runtime, 0700); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(root, "helper")
	script := "#!/bin/sh\ntest \"$1\" = --local-checks || exit 1\ntest -e /proc/self/fd/8 || exit 2\nprintf '%s\\n' \"$2\"\ncat\n"
	if err := os.WriteFile(executable, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	e := &Engine{Runtime: runtime, Config: root, Executable: executable}
	out, err := e.RunLocalChecks(context.Background(), `{"protocol":"farm-local-checks-worker/v1","action":"complete","epoch":"0123456789abcdef0123456789abcdef","requestID":"job-001"}`)
	if err != nil || !strings.Contains(out, filepath.Join(root, "native-local-checks.json")) {
		t.Fatal(out, err)
	}
}
