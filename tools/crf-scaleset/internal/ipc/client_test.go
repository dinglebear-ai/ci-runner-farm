package ipc

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

func TestClientRoundTripUsesBoundedUnixFrame(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control.sock")
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
	path := filepath.Join(t.TempDir(), "control.sock")
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
