package localchecks

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// dockerChecksCommand transports only the fixed Core checks workload into the
// charged worker. The one approved dependency credential crosses Docker's stdin
// stream, never Docker arguments, Docker Config.Env or the host subprocess env.
func dockerChecksCommand(ctx context.Context, id string, s Submission, environment []string) (*exec.Cmd, error) {
	if !immutableContainerID.MatchString(id) {
		return nil, errors.New("local_checks_container_identity_invalid")
	}
	if err := s.Validate(); err != nil {
		return nil, err
	}
	if len(environment) > 1 {
		return nil, errors.New("local_checks_secret_environment_invalid")
	}
	token := ""
	if len(environment) == 1 {
		if !strings.HasPrefix(environment[0], "EX_STANDARDS_TOKEN=") {
			return nil, errors.New("local_checks_secret_environment_invalid")
		}
		token = strings.TrimPrefix(environment[0], "EX_STANDARDS_TOKEN=")
		if len(token) < 8 || len(token) > 4096 || strings.ContainsAny(token, "\x00\n\r") {
			return nil, errors.New("local_checks_secret_environment_invalid")
		}
	}
	script := `set -eu
IFS= read -r EX_STANDARDS_TOKEN || exit 70
export EX_STANDARDS_TOKEN
unset CORE_LOCAL_CI_RESOURCE_CONTRACT CORE_LOCAL_CI_ADMITTED_CPUS CORE_LOCAL_CI_ADMITTED_MEMORY_BYTES
if grep -Fqx '# local-ci-resource-contract: 1' /workspace/source/core/scripts/local_ci_container.sh; then
  for helper in /workspace/source/core/scripts/local_ci_linux.sh /workspace/source/core/scripts/local_ci_resources.py; do
    if ! grep -Fqx '# local-ci-resource-contract: 1' "$helper"; then
      echo local_checks_core_resource_contract_incomplete >&2
      exit 76
    fi
  done
  bash /workspace/source/core/scripts/local_ci_container.sh setup "$@" || exit "$?"
  export CORE_LOCAL_CI_RESOURCE_CONTRACT=1
  export CORE_LOCAL_CI_ADMITTED_CPUS="$FARM_CHECKS_CPUS"
  export CORE_LOCAL_CI_ADMITTED_MEMORY_BYTES="$FARM_CHECKS_MEMORY_BYTES"
  unset FARM_CHECKS_CPUS FARM_CHECKS_MEMORY_BYTES FARM_CHECKS_TIMEOUT
  exec bash /workspace/source/core/scripts/local_ci_container.sh checks "$@"
fi
` + observedCurrentCoreShell()
	cmd := exec.CommandContext(ctx, "docker", "exec", "--interactive",
		"--env", "FARM_CHECKS_CPUS="+strconv.FormatUint(uint64(s.CPUs), 10),
		"--env", "FARM_CHECKS_MEMORY_BYTES="+strconv.FormatUint(s.MemoryMiB<<20, 10),
		"--env", "FARM_CHECKS_TIMEOUT="+strconv.FormatUint(uint64(s.TimeoutSeconds), 10),
		"--workdir", "/workspace/source", id, "sh", "-c", script, "farm-checks", s.Commit, s.Base)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent", "DOCKER_HOST=unix:///var/run/docker.sock"}
	cmd.Stdin = strings.NewReader(token + "\n")
	return cmd, nil
}

// nativeExecutionOwner is constructed only while WithNativeWorker holds the
// original policy/epoch lease and inherited fleet lock. It never reacquires or
// double-charges capacity, and always stops the entire worker before release.
type nativeExecutionOwner struct {
	worker      *nativeWorker
	receipt     NativeReceipt
	host        string
	environment []string
}

func (o *nativeExecutionOwner) Verify(ctx context.Context, r Reservation) error {
	if o == nil || o.worker == nil || !r.matches(o.receipt.Request) || r.Host != o.host || r.Handle != o.receipt.Fence {
		return errors.New("local_checks_reservation_receipt_mismatch")
	}
	current, err := o.worker.load(r.RequestID)
	if err != nil || current.State != "running" || current.Fence != r.Handle || current.ContainerID != o.receipt.ContainerID || current.Worker != o.receipt.Worker {
		return errors.New("local_checks_native_owner_changed")
	}
	bound, ok := o.worker.driver.(interface{ Binding() WorkerBinding })
	if !ok || bound.Binding() != current.Worker {
		return errors.New("local_checks_native_owner_changed")
	}
	snapshot, err := o.worker.broker.Status(&o.worker.policy)
	if err != nil {
		return err
	}
	grant, present := snapshot.Grants[o.worker.request(current.Request).ID]
	if !present || grant.Fence != r.Handle || grant.Cost.MemoryMiB != r.MemoryMiB || grant.Cost.VCPUs != r.CPUs {
		return errors.New("local_checks_native_grant_mismatch")
	}
	c, err := o.worker.driver.Inspect(ctx, current.ContainerID)
	if err != nil {
		return err
	}
	if !c.Running || !c.Managed || c.ID != current.ContainerID || c.Role != "local-checks" || c.RequestID != r.RequestID || c.SourceDigest != r.BundleSHA256 || c.MemoryMiB != r.MemoryMiB || c.CPUs != r.CPUs || !c.PrivateCgroup || !c.InnerDocker || c.HostDockerSocket {
		return errors.New("local_checks_native_execution_isolation_invalid")
	}
	return nil
}
func (o *nativeExecutionOwner) WithExecution(ctx context.Context, r Reservation, operation func(context.Context, OwnerVerifier, []string) error) error {
	if operation == nil {
		return errors.New("local_checks_execution_callback_required")
	}
	if err := o.Verify(ctx, r); err != nil {
		return err
	}
	stopper, ok := o.worker.driver.(interface {
		Stop(context.Context, string) error
	})
	if !ok {
		return errors.New("local_checks_native_stop_required")
	}
	result := operation(ctx, o, append([]string(nil), o.environment...))
	// Cancellation of a Docker CLI does not cancel the in-container child. Always
	// stop the complete worker using a separate bounded cleanup context, retaining
	// its original charge whenever stopping/absence cannot be positively proved.
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	if err := stopper.Stop(cleanup, o.receipt.ContainerID); err != nil {
		return errors.Join(result, err)
	}
	return errors.Join(result, o.worker.Complete(cleanup, r.RequestID))
}
func (o *nativeExecutionOwner) executionCommand(ctx context.Context, _ Invocation, environment []string) (*exec.Cmd, error) {
	return dockerChecksCommand(ctx, o.receipt.ContainerID, o.receipt.Request, environment)
}

func (d DockerNativeDriver) Stop(ctx context.Context, id string) error {
	c, err := d.Inspect(ctx, id)
	if err != nil {
		return err
	}
	if c.Running {
		if _, err = d.command(ctx, "container", "stop", "--timeout", "10", id); err != nil {
			return errors.New("local_checks_native_stop_uncertain")
		}
	}
	c, err = d.Inspect(ctx, id)
	if err != nil || c.Running || !c.Stopped {
		return errors.New("local_checks_native_stop_unproven")
	}
	return nil
}

func (o *nativeExecutionOwner) prepareExecution(ctx context.Context, root, bundle string, s Submission, _ Reservation) (Invocation, error) {
	if root != o.receipt.Worker.SourceRoot || s != o.receipt.Request || bundle != filepath.Join(filepath.Dir(root), "intent.json") {
		return Invocation{}, errors.New("local_checks_native_source_binding_mismatch")
	}
	bounded, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := verifyNativeSnapshot(bounded, NativeConfiguration{SnapshotRoot: filepath.Dir(root)}, s); err != nil {
		return Invocation{}, err
	}
	entry := filepath.Join(root, "core/scripts/local_ci_container.sh")
	canonical, err := filepath.EvalSymlinks(entry)
	if err != nil || canonical != entry {
		return Invocation{}, errors.New("local_checks_container_entrypoint_unavailable")
	}
	info, err := os.Stat(entry)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return Invocation{}, errors.New("local_checks_container_entrypoint_unavailable")
	}
	return Invocation{Executable: entry, Arguments: []string{"checks", s.Commit, s.Base}, WorkingDirectory: root}, nil
}

// ExecuteChecks is invoked under the native policy lease. The host, evidence
// path and in-memory credential come exclusively from protected native binding.
func (w *nativeWorker) ExecuteChecks(ctx context.Context, requestID, host, evidence string, environment []string) (Result, error) {
	var result Result
	if !identifier.MatchString(host) || !filepath.IsAbs(evidence) || filepath.Clean(evidence) != evidence {
		return result, errors.New("local_checks_native_execution_binding_invalid")
	}
	receipt, err := w.load(requestID)
	if err != nil {
		return result, err
	}
	s := receipt.Request
	r := Reservation{Host: host, RequestID: s.RequestID, Commit: s.Commit, Base: s.Base, BundleSHA256: s.BundleSHA256, Handle: receipt.Fence, CPUs: s.CPUs, MemoryMiB: s.MemoryMiB, ScratchMiB: s.ScratchMiB, TimeoutSeconds: s.TimeoutSeconds}
	owner := &nativeExecutionOwner{worker: w, receipt: receipt, host: host, environment: environment}
	root := receipt.Worker.SourceRoot
	return Execute(ctx, root, filepath.Join(filepath.Dir(root), "intent.json"), evidence, s, r, owner)
}
