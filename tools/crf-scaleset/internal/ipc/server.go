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
	"time"

	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

type Handler func(context.Context, protocol.Request) protocol.Response

type Server struct {
	Path        string
	Handler     Handler
	AllowedUID  *uint32
	mu          sync.Mutex
	lastSeq     map[string]uint64
	MaxHandlers int
	IOTimeout   time.Duration
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
	defer func() { _ = listener.Close() }()
	defer func() { _ = os.Remove(s.Path) }()
	if err := os.Chmod(s.Path, 0o600); err != nil {
		return err
	}
	s.lastSeq = map[string]uint64{}
	maxHandlers := s.MaxHandlers
	if maxHandlers <= 0 {
		maxHandlers = 32
	}
	timeout := s.IOTimeout
	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	handlers := make(chan struct{}, maxHandlers)
	go func() { <-ctx.Done(); _ = listener.Close() }()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			continue
		}
		select {
		case handlers <- struct{}{}:
			go func() {
				defer func() { <-handlers }()
				_ = conn.SetDeadline(time.Now().Add(timeout))
				requestCtx, cancel := context.WithTimeout(ctx, timeout)
				defer cancel()
				s.handle(requestCtx, conn)
			}()
		case <-ctx.Done():
			_ = conn.Close()
			return nil
		default:
			_ = conn.SetDeadline(time.Now().Add(time.Second))
			_ = json.NewEncoder(conn).Encode(protocol.Response{
				SchemaVersion: 1, OK: false, Code: "server_busy"})
			_ = conn.Close()
		}
	}
}

func (s *Server) handle(ctx context.Context, conn net.Conn) {
	defer func() { _ = conn.Close() }()
	allowedUID := uint32(0)
	if s.AllowedUID != nil {
		allowedUID = *s.AllowedUID
	}
	if !authorizedPeer(conn, allowedUID) {
		_ = json.NewEncoder(conn).Encode(protocol.Response{SchemaVersion: 1, OK: false, Code: "peer_not_root"})
		return
	}
	req, err := protocol.Decode(bufio.NewReaderSize(conn, protocol.MaxFrameBytes+1))
	if err != nil {
		_ = json.NewEncoder(conn).Encode(protocol.Response{SchemaVersion: 1, OK: false, Code: "invalid_frame", Error: err.Error()})
		return
	}
	s.mu.Lock()
	last := s.lastSeq[req.ControllerInstanceID]
	if req.Sequence <= last {
		s.mu.Unlock()
		_ = json.NewEncoder(conn).Encode(protocol.Response{SchemaVersion: 1, RequestID: req.RequestID, OK: false, Code: "sequence_regression"})
		return
	}
	s.lastSeq[req.ControllerInstanceID] = req.Sequence
	s.mu.Unlock()
	_ = json.NewEncoder(conn).Encode(s.Handler(ctx, req))
}

func authorizedPeer(conn net.Conn, allowedUID uint32) bool {
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
	return uid == allowedUID
}
