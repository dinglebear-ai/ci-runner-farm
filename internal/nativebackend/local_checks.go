package nativebackend

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/unraid/ci-runner-farm/internal/localchecks"
)

// RunLocalChecks transports the closed request to the same native executable
// with the existing fleet lock inherited as FD8. It creates no queue or grant.
func (e *Engine) RunLocalChecks(ctx context.Context, request string, dependency ...string) (string, error) {
	commandValue, err := localchecks.DecodeNativeCommand(strings.NewReader(request))
	if err != nil {
		return "", err
	}
	raw, err := json.Marshal(commandValue)
	if err != nil {
		return "", err
	}
	if len(dependency) > 1 {
		return "", errors.New("local_checks_native_envelope_invalid")
	}
	secret := ""
	if len(dependency) == 1 {
		secret = dependency[0]
	}
	envelope := string(raw) + "\n" + secret
	if _, _, err := localchecks.DecodeNativeEnvelope(strings.NewReader(envelope)); err != nil {
		return "", err
	}
	fd, err := syscall.Open(filepath.Join(e.Runtime, "fleet.lock"), syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if err != nil {
		return "", errors.New("local_checks_fleet_lock_unavailable")
	}
	lock := os.NewFile(uintptr(fd), "fleet.lock")
	defer lock.Close()
	if err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return "", errors.New("local_checks_fleet_busy")
	}
	defer syscall.Flock(fd, syscall.LOCK_UN)
	// FD3..7 are intentionally empty; only the actual lock is inherited as FD8.
	dummy, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return "", err
	}
	defer dummy.Close()
	command := exec.CommandContext(ctx, e.Executable, "--local-checks", filepath.Join(e.Config, "native-local-checks.json"))
	command.ExtraFiles = []*os.File{dummy, dummy, dummy, dummy, dummy, lock}
	command.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent"}
	command.Stdin = strings.NewReader(envelope)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return command.Process.Signal(syscall.SIGTERM) }
	// Helper handles TERM by stopping the entire charged worker. Killing only its
	// docker-exec client is not sufficient. A forced exit leaves the charge intact.
	command.WaitDelay = 45 * time.Second
	var out tailBuffer
	out.limit = 32768
	command.Stdout = &out
	command.Stderr = io.Discard
	err = command.Run()
	return string(out.data), err
}

func (e *Engine) LocalChecksReadiness(ctx context.Context) (string, error) {
	bounded, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	command := exec.CommandContext(bounded, e.Executable, "--local-checks-readiness", filepath.Join(e.Config, "native-local-checks.json"))
	command.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent"}
	var out tailBuffer
	out.limit = 32768
	command.Stdout = &out
	command.Stderr = io.Discard
	err := command.Run()
	return string(out.data), err
}
