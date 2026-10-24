// Package nativebackend adapts the existing Farm engine to Core-owned native service lifetime.
package nativebackend

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	_ "embed"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

//go:generate python3 ../../scripts/embed-native-engine.py
//go:embed engine.tar.gz
var engineArchive []byte

// Engine retains the authored shell/provider/planner behavior; it is not another allocator.
type Engine struct{ Root, Config, Runtime, CapacityRoot, Executable, BoundCache string }

func (e *Engine) Extract() error {
	r, err := gzip.NewReader(bytes.NewReader(engineArchive))
	if err != nil {
		return err
	}
	defer r.Close()
	t := tar.NewReader(r)
	for {
		h, err := t.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if h.Typeflag != tar.TypeReg || h.Size > 2<<20 || filepath.Clean(h.Name) != h.Name || strings.HasPrefix(h.Name, "/") || strings.HasPrefix(h.Name, "..") {
			return errors.New("invalid embedded engine")
		}
		p := filepath.Join(e.Root, h.Name)
		if err = os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			return err
		}
		data, err := io.ReadAll(io.LimitReader(t, 2<<20))
		if err != nil {
			return err
		}
		if err = os.WriteFile(p, data, 0500); err != nil {
			return err
		}
	}
	if err = os.MkdirAll(filepath.Join(e.Root, "bin"), 0700); err != nil {
		return err
	}
	return os.Symlink(e.Executable, filepath.Join(e.Root, "bin", "ci-runner-capacity"))
}

type tailBuffer struct {
	data    []byte
	limit   int
	logPath string
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	n := len(p)
	b.data = append(b.data, p...)
	if len(b.data) > b.limit {
		b.data = append([]byte(nil), b.data[len(b.data)-b.limit:]...)
	}
	if b.logPath != "" {
		_ = atomicWrite(b.logPath, b.data, 0600)
	}
	return n, nil
}

func (e *Engine) Run(ctx context.Context, action string, args []string, override string) (string, error) {
	if err := requireClassicRetired(ctx); err != nil {
		return "", err
	}
	temporaryRoot := filepath.Join(e.Runtime, "native-tmp")
	if err := os.MkdirAll(temporaryRoot, 0700); err != nil {
		return "", err
	}
	temporary, err := os.MkdirTemp(temporaryRoot, "operation-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(temporary)
	argv := append([]string{filepath.Join(e.Root, "include/runner-farm.sh"), action}, args...)
	cmd := exec.CommandContext(ctx, "/bin/bash", argv...)
	cmd.Env = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/nonexistent", "TMPDIR=" + temporary, "CRF_NATIVE_MODE=1", "CRF_BOUND_CACHE_ROOT=" + e.BoundCache, "CRF_NATIVE_ACTION=" + action, "CRF_CFGDIR=" + e.Config, "CRF_RUNDIR=" + e.Runtime, "CRF_CAPACITY_ROOT=" + e.CapacityRoot}
	if override != "" {
		cmd.Env = append(cmd.Env, "CRF_CONFIG_FILE="+override)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = 2 * time.Second
	out := &tailBuffer{limit: 512 << 10, logPath: filepath.Join(e.Runtime, "native-operation.log")}
	cmd.Stdout = out
	cmd.Stderr = out
	err = cmd.Run()
	if ctx.Err() != nil && cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	return string(out.data), err
}
