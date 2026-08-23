package ipc

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

func TestClientRoundTripUsesBoundedUnixFrame(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "control.sock")
	uid := uint32(os.Geteuid())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server := &Server{Path: path, AllowedUID: &uid, Handler: func(_ context.Context, req protocol.Request) protocol.Response {
		return protocol.Response{SchemaVersion: 1, RequestID: req.RequestID, OK: true,
			Result: map[string]string{"operation": req.Operation}}
	}}
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if _, err := (Client{Path: path}).Call(context.Background(), protocol.Request{
			SchemaVersion: 1, RequestID: "request-1", Operation: "read_snapshot",
			ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
			ControllerInstanceID: "controller", Sequence: 1}); err == nil {
			cancel()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("client never completed a round trip")
}

func TestClientContextBoundsConnectedRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stalled.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = listener.Close() }()
	accepted := make(chan struct{})
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			close(accepted)
			defer func() { _ = conn.Close() }()
			time.Sleep(time.Second)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	_, err = (Client{Path: path}).Call(ctx, protocol.Request{
		SchemaVersion: 1, RequestID: "request-stall", Operation: "read_snapshot",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		ControllerInstanceID: "controller", Sequence: 1})
	if err == nil {
		t.Fatal("connected read ignored context timeout")
	}
	<-accepted
}

func TestClientRejectsOversizedResponse(t *testing.T) {
	// The production server is already bounded on requests. The client must also
	// avoid trusting an unbounded or compromised local peer response.
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "control.sock")
	uid := uint32(os.Geteuid())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server := &Server{Path: path, AllowedUID: &uid, Handler: func(_ context.Context, req protocol.Request) protocol.Response {
		return protocol.Response{SchemaVersion: 1, RequestID: req.RequestID, OK: true,
			Result: strings.Repeat("x", protocol.MaxFrameBytes)}
	}}
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		_, err := (Client{Path: path}).Call(context.Background(), protocol.Request{
			SchemaVersion: 1, RequestID: "request-2", Operation: "read_snapshot",
			ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
			ControllerInstanceID: "controller", Sequence: 2})
		if err != nil {
			cancel()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	t.Fatal("oversized response was accepted")
}

func TestServerBoundsReplayIdentitiesWithoutEvictingProtection(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "control.sock")
	uid := uint32(os.Geteuid())
	ctx, cancel := context.WithCancel(context.Background())
	server := &Server{Path: path, AllowedUID: &uid, MaxReplayIdentities: 1,
		Handler: func(_ context.Context, req protocol.Request) protocol.Response {
			return protocol.Response{SchemaVersion: 1, RequestID: req.RequestID, OK: true}
		}}
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	call := func(identity string, sequence uint64) protocol.Response {
		deadline := time.Now().Add(time.Second)
		for {
			response, err := (Client{Path: path}).Call(context.Background(), protocol.Request{
				SchemaVersion: 1, RequestID: identity, Operation: "read_snapshot",
				ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
				ControllerInstanceID: identity, Sequence: sequence})
			if err == nil {
				return response
			}
			if time.Now().After(deadline) {
				t.Fatal(err)
			}
			time.Sleep(time.Millisecond)
		}
	}
	if response := call("first", 2); !response.OK {
		t.Fatalf("first identity rejected: %#v", response)
	}
	if response := call("second", 1); response.Code != "replay_identity_capacity_exhausted" {
		t.Fatalf("unexpected capacity response: %#v", response)
	}
	if response := call("first", 1); response.Code != "sequence_regression" {
		t.Fatalf("replay protection was evicted: %#v", response)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestServerRefusesToUnlinkNonSocketPaths(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	uid := uint32(os.Geteuid())
	for _, kind := range []string{"regular", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			path := filepath.Join(dir, kind+".sock")
			if kind == "regular" {
				if err := os.WriteFile(path, []byte("preserve"), 0o600); err != nil {
					t.Fatal(err)
				}
			} else if err := os.Symlink(filepath.Join(dir, "missing"), path); err != nil {
				t.Fatal(err)
			}
			err := (&Server{Path: path, AllowedUID: &uid, Handler: func(context.Context, protocol.Request) protocol.Response {
				return protocol.Response{}
			}}).Serve(context.Background())
			if err == nil {
				t.Fatal("unsafe socket path was accepted")
			}
			if _, statErr := os.Lstat(path); statErr != nil {
				t.Fatalf("unsafe path was removed: %v", statErr)
			}
		})
	}
}

func TestServerRequiresPrivateRuntimeDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	uid := uint32(os.Geteuid())
	err := (&Server{Path: filepath.Join(dir, "control.sock"), AllowedUID: &uid,
		Handler: func(context.Context, protocol.Request) protocol.Response { return protocol.Response{} },
	}).Serve(context.Background())
	if err == nil || err.Error() != "socket_runtime_dir_not_private" {
		t.Fatalf("expected private runtime rejection, got %v", err)
	}
}
