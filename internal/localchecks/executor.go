package localchecks

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ExecutionOwner adapts an already charged worker sandbox. It MUST hold the
// original epoch/lease and enforced aggregate resources throughout callback,
// terminal evidence and stopped-owner proof. It must retain uncertain grants,
// and may release only after its existing sandbox owner proves all children
// stopped. An advisory queue ticket or a naked Broker grant is insufficient.
// Environment entries are injected in memory from the approved secret owner.
type ExecutionOwner interface {
	WithExecution(context.Context, Reservation, func(context.Context, OwnerVerifier, []string) error) error
}

type Result struct {
	RequestID    string    `json:"requestID"`
	Host         string    `json:"host"`
	Commit       string    `json:"commit"`
	Base         string    `json:"base"`
	BundleSHA256 string    `json:"bundleSHA256"`
	Status       string    `json:"status"`
	ExitCode     int       `json:"exitCode"`
	StartedAt    time.Time `json:"startedAt"`
	FinishedAt   time.Time `json:"finishedAt"`
	LogPath      string    `json:"logPath"`
	ReceiptPath  string    `json:"receiptPath"`
}

// Execute runs the fixed checks invocation only inside the supplied charged
// execution owner's lease. It never opens SSH, changes host policy or creates a
// competing grant/queue. Evidence is private and bounded; no ambient credential
// environment is inherited. Source custody remains exclusive to this worker.
func Execute(ctx context.Context, root, bundle, evidenceRoot string, s Submission, r Reservation, owner ExecutionOwner) (result Result, resultErr error) {
	if err := s.Validate(); err != nil {
		return result, err
	}
	if owner == nil {
		return result, errors.New("local_checks_execution_owner_required")
	}
	if !filepath.IsAbs(evidenceRoot) || filepath.Clean(evidenceRoot) != evidenceRoot {
		return result, errors.New("local_checks_evidence_root_invalid")
	}
	result = Result{RequestID: s.RequestID, Host: r.Host, Commit: s.Commit, Base: s.Base, BundleSHA256: s.BundleSHA256, Status: "not_started", ExitCode: -1}
	resultErr = owner.WithExecution(ctx, r, func(held context.Context, proof OwnerVerifier, secretEnvironment []string) error {
		var invocation Invocation
		var err error
		if transport, ok := owner.(interface {
			prepareExecution(context.Context, string, string, Submission, Reservation) (Invocation, error)
		}); ok {
			invocation, err = transport.prepareExecution(held, root, bundle, s, r)
			if err == nil {
				err = proof.Verify(held, r)
			}
		} else {
			invocation, err = Prepare(held, root, bundle, s, r, proof)
		}
		if err != nil {
			return err
		}
		// Only the explicit dependency credential crosses this boundary. In
		// particular, no GitHub runner registration key or ambient agent token does.
		env := []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent"}
		var secrets []string
		if len(secretEnvironment) > 1 {
			return errors.New("local_checks_secret_environment_invalid")
		}
		for _, entry := range secretEnvironment {
			if !strings.HasPrefix(entry, "EX_STANDARDS_TOKEN=") || strings.ContainsRune(entry, '\x00') {
				return errors.New("local_checks_secret_environment_invalid")
			}
			env = append(env, entry)
			value := strings.TrimPrefix(entry, "EX_STANDARDS_TOKEN=")
			if len(value) < 8 || len(value) > 4096 {
				return errors.New("local_checks_secret_environment_invalid")
			}
			secrets = append(secrets, value)
		}
		if err := os.MkdirAll(evidenceRoot, 0700); err != nil {
			return errors.New("local_checks_evidence_unavailable")
		}
		canonical, err := filepath.EvalSymlinks(evidenceRoot)
		if err != nil || canonical != evidenceRoot {
			return errors.New("local_checks_evidence_root_invalid")
		}
		info, err := os.Stat(evidenceRoot)
		if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
			return errors.New("local_checks_evidence_root_private_required")
		}
		jobdir := filepath.Join(evidenceRoot, s.RequestID)
		if err := os.Mkdir(jobdir, 0700); err != nil {
			return errors.New("local_checks_evidence_already_exists_or_unavailable")
		}
		result.LogPath = filepath.Join(jobdir, "checks.log")
		result.ReceiptPath = filepath.Join(jobdir, "result.json")
		log, err := os.OpenFile(result.LogPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return errors.New("local_checks_log_unavailable")
		}
		defer log.Close()
		runctx, cancel := context.WithTimeout(held, time.Duration(s.TimeoutSeconds)*time.Second)
		defer cancel()
		output := &executionOutput{destination: log, remaining: 16 << 20, cancel: cancel, secrets: secrets}
		cmd := exec.CommandContext(runctx, invocation.Executable, invocation.Arguments...)
		cmd.Dir = invocation.WorkingDirectory
		cmd.Env = env
		if transport, ok := owner.(interface {
			executionCommand(context.Context, Invocation, []string) (*exec.Cmd, error)
		}); ok {
			cmd, err = transport.executionCommand(runctx, invocation, secretEnvironment)
			if err != nil {
				return err
			}
		}
		cmd.Stdout = output
		cmd.Stderr = output
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		var escalation *time.Timer
		cmd.Cancel = func() error {
			err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
			escalation = time.AfterFunc(250*time.Millisecond, func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) })
			return err
		}
		cmd.WaitDelay = time.Second
		result.StartedAt = time.Now().UTC()
		result.Status = "running"
		err = cmd.Run()
		if flushErr := output.Flush(); flushErr != nil {
			err = errors.Join(err, flushErr)
		}
		if escalation != nil {
			escalation.Stop()
		}
		// A descendant must not survive just because its shell exited normally.
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		result.FinishedAt = time.Now().UTC()
		if cmd.ProcessState != nil {
			result.ExitCode = cmd.ProcessState.ExitCode()
		}
		switch {
		case output.exceeded:
			result.Status = "output_limited"
		case runctx.Err() != nil:
			if held.Err() != nil {
				result.Status = "cancelled"
			} else {
				result.Status = "timed_out"
			}
		case err != nil:
			result.Status = "failed"
		default:
			result.Status = "passed"
		}
		if syncErr := log.Sync(); syncErr != nil {
			return errors.New("local_checks_evidence_commit_failed")
		}
		if closeErr := log.Close(); closeErr != nil {
			return errors.New("local_checks_evidence_commit_failed")
		}
		pending := filepath.Join(jobdir, "result.pending")
		receipt, writeErr := os.OpenFile(pending, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if writeErr != nil {
			return errors.New("local_checks_evidence_commit_failed")
		}
		writeErr = json.NewEncoder(receipt).Encode(result)
		if writeErr == nil {
			writeErr = receipt.Sync()
		}
		writeErr = errors.Join(writeErr, receipt.Close())
		if writeErr == nil {
			writeErr = os.Rename(pending, result.ReceiptPath)
		}
		if writeErr == nil {
			directory, openErr := os.Open(jobdir)
			if openErr != nil {
				writeErr = openErr
			} else {
				writeErr = errors.Join(directory.Sync(), directory.Close())
			}
		}
		if writeErr != nil {
			return errors.New("local_checks_evidence_commit_failed")
		}
		if result.Status != "passed" {
			return errors.New("local_checks_" + result.Status)
		}
		return nil
	})
	return result, resultErr
}

type executionOutput struct {
	mu          sync.Mutex
	destination io.Writer
	remaining   int
	exceeded    bool
	cancel      context.CancelFunc
	secrets     []string
	pending     string
	written     int
}

func (w *executionOutput) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(p) > w.remaining {
		w.exceeded = true
		w.cancel()
		return 0, errors.New("local_checks_output_limit")
	}
	w.remaining -= len(p)
	w.pending += string(p)
	if err := w.emit(false); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (w *executionOutput) Flush() error { w.mu.Lock(); defer w.mu.Unlock(); return w.emit(true) }
func (w *executionOutput) emit(final bool) error {
	maxSecret := 1
	for _, secret := range w.secrets {
		if len(secret) > maxSecret {
			maxSecret = len(secret)
		}
	}
	var out strings.Builder
	for len(w.pending) > 0 && (final || len(w.pending) >= maxSecret) {
		matched := false
		for _, secret := range w.secrets {
			if final && w.pending != "" && strings.HasPrefix(secret, w.pending) {
				out.WriteString("[redacted]")
				w.pending = ""
				matched = true
				break
			}
			if secret != "" && strings.HasPrefix(w.pending, secret) {
				out.WriteString("[redacted]")
				w.pending = w.pending[len(secret):]
				matched = true
				break
			}
		}
		if !matched {
			out.WriteByte(w.pending[0])
			w.pending = w.pending[1:]
		}
	}
	if w.written+out.Len() > 16<<20 {
		w.exceeded = true
		w.cancel()
		return errors.New("local_checks_output_limit")
	}
	n, err := io.WriteString(w.destination, out.String())
	w.written += n
	return err
}
