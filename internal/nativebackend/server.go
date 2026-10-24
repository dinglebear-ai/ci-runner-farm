package nativebackend

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// Serve exposes a root-only local socket. No TCP listener or browser credentials.
// Each connection carries one bounded request; concurrent connections are capped.
func (s *Service) Serve(ctx context.Context, socket string) error {
	if _, err := os.Lstat(socket); err == nil {
		return errors.New("socket_exists_require_owned_recovery")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(socket)
	if err = os.Chmod(socket, 0600); err != nil {
		return err
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			listener.Close()
		case <-done:
		}
	}()
	slots := make(chan struct{}, 8)
	for {
		c, err := listener.AcceptUnix()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		select {
		case slots <- struct{}{}:
			go func() {
				defer func() { <-slots }()
				defer c.Close()
				c.SetDeadline(time.Now().Add(12 * time.Second))
				if !rootPeer(c) {
					return
				}
				decoder := json.NewDecoder(io.LimitReader(c, 1<<20))
				decoder.DisallowUnknownFields()
				var r Request
				if decoder.Decode(&r) != nil {
					_ = json.NewEncoder(c).Encode(fail("invalid_request"))
					return
				}
				_ = json.NewEncoder(c).Encode(s.Handle(r))
			}()
		default:
			c.Close()
		}
	}
}
func rootPeer(c *net.UnixConn) bool {
	raw, err := c.SyscallConn()
	if err != nil {
		return false
	}
	ok := false
	if raw.Control(func(fd uintptr) {
		credentials, err := syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
		ok = err == nil && credentials.Uid == 0
	}) != nil {
		return false
	}
	return ok
}

// CheckDirectory refuses mutable aliases and unsafe host ownership. Test callers
// use their own expected UID; the daemon always selects root.
func CheckDirectory(path string, owner uint32) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("noncanonical_directory")
	}
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil || canonical != path {
		return errors.New("symlinked_or_missing_directory")
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != owner || !info.IsDir() || info.Mode().Perm()&0022 != 0 {
		return errors.New("unsafe_directory")
	}
	return nil
}
