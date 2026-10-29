package nativebackend

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAttachmentUsesOriginalOperationGateAndRequiresConfirmation(t *testing.T) {
	epoch := "0123456789abcdef0123456789abcdef"
	if _, _, err := ValidateOperation(Request{Action: "attach-qa", Args: []string{epoch, "/protected/attachment.json"}}); err == nil {
		t.Fatal("attachment without confirmation accepted")
	}
	action, args, err := ValidateOperation(Request{Action: "attach-qa", Args: []string{epoch, "/protected/attachment.json"}, Confirm: true})
	if err != nil || action != "native-attach-qa" || len(args) != 2 {
		t.Fatal("original native attachment dispatch missing", action, err)
	}
	for _, bad := range []Request{{Action: "attach-qa", Confirm: true}, {Action: "attach-qa", Args: []string{"short", "/protected/attachment.json"}, Confirm: true}, {Action: "attach-qa", Args: []string{epoch, "relative"}, Confirm: true}} {
		if _, _, err := ValidateOperation(bad); err == nil {
			t.Fatal("unsafe attachment operation accepted")
		}
	}
	runner := &fakeRunner{block: make(chan struct{}), started: make(chan struct{}, 1)}
	service := New(runner, t.TempDir(), t.TempDir())
	defer service.Shutdown()
	request := Request{Action: "attach-qa", Args: []string{epoch, "/protected/attachment.json"}, Confirm: true}
	if !service.Handle(request).OK {
		t.Fatal("attachment did not enter original operation gate")
	}
	<-runner.started
	if response := service.Handle(request); response.OK || response.Error != "backend_busy" {
		t.Fatal("overlapping attachment bypassed operation gate")
	}
	close(runner.block)
}

func TestEmbeddedAttachmentDispatchRetainsOriginalFleetDescriptor(t *testing.T) {
	root := t.TempDir()
	config := t.TempDir()
	runtime := t.TempDir()
	cache := t.TempDir()
	executable := filepath.Join(root, "capacity-fixture")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\n[ -f /proc/self/fd/8 ] || exit 31\nprintf '%s|%s|%s\\n' \"$1\" \"$2\" \"$3\"\nreadlink /proc/self/fd/8\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config, "ci-runner-farm.cfg"), []byte("CACHE_ROOT=\""+cache+"\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	engine := &Engine{Root: filepath.Join(root, "engine"), Config: config, Runtime: runtime, CapacityRoot: t.TempDir(), Executable: executable, BoundCache: cache}
	if err := engine.Extract(); err != nil {
		t.Fatal(err)
	}
	out, err := engine.Run(t.Context(), "native-attach-qa", []string{"0123456789abcdef0123456789abcdef", "/protected/request.json"}, "")
	want := "attach-qa|0123456789abcdef0123456789abcdef|/protected/request.json\n" + filepath.Join(runtime, "fleet.lock") + "\n"
	if err != nil || out != want {
		t.Fatal("embedded wrapper lost exact request or original fleet descriptor", out, err)
	}
}
