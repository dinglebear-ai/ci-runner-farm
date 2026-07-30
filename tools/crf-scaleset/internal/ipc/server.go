package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"

	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

type Handler func(context.Context, protocol.Request) protocol.Response

type Server struct {
	Path    string
	Handler Handler
	mu      sync.Mutex
	lastSeq map[string]uint64
}

func (s *Server) Serve(ctx context.Context) error {
	if s.Handler == nil {
		return errors.New("handler_required")
	}
	if err := os.MkdirAll(filepath.Dir(s.Path), 0o700); err != nil {
		return err
	}
	if err := os.Chmod(filepath.Dir(s.Path), 0o700); err != nil {
		return err
	}
	_ = os.Remove(s.Path)
	listener, err := net.Listen("unix", s.Path)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(s.Path)
	if err := os.Chmod(s.Path, 0o600); err != nil {
		return err
	}
	s.lastSeq = map[string]uint64{}
	go func() { <-ctx.Done(); listener.Close() }()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			continue
		}
		go s.handle(ctx, conn)
	}
}

func (s *Server) handle(ctx context.Context, conn net.Conn) {
	defer conn.Close()
	if !rootPeer(conn) {
		json.NewEncoder(conn).Encode(protocol.Response{SchemaVersion: 1, OK: false, Code: "peer_not_root"})
		return
	}
	req, err := protocol.Decode(bufio.NewReaderSize(conn, protocol.MaxFrameBytes+1))
	if err != nil {
		json.NewEncoder(conn).Encode(protocol.Response{SchemaVersion: 1, OK: false, Code: "invalid_frame", Error: err.Error()})
		return
	}
	s.mu.Lock()
	last := s.lastSeq[req.ControllerInstanceID]
	if req.Sequence <= last {
		s.mu.Unlock()
		json.NewEncoder(conn).Encode(protocol.Response{SchemaVersion: 1, RequestID: req.RequestID, OK: false, Code: "sequence_regression"})
		return
	}
	s.lastSeq[req.ControllerInstanceID] = req.Sequence
	s.mu.Unlock()
	json.NewEncoder(conn).Encode(s.Handler(ctx, req))
}

func rootPeer(conn net.Conn) bool {
	unix, ok := conn.(*net.UnixConn)
	if !ok {
		return false
	}
	raw, err := unix.SyscallConn()
	if err != nil {
		return false
	}
	uid := uint32(^uint32(0))
	if err := raw.Control(func(fd uintptr) {
		cred, e := syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
		if e == nil {
			uid = cred.Uid
		}
	}); err != nil {
		return false
	}
	return uid == 0
}
