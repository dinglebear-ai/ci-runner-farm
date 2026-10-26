package localchecks

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// KernelLimits reports cgroup-v2 values read from the running process's own
// namespace root. It contains no account, host, token or process arguments.
type KernelLimits struct {
	CPUQuota        uint64 `json:"cpuQuota"`
	CPUPeriod       uint64 `json:"cpuPeriod"`
	MemoryBytes     uint64 `json:"memoryBytes"`
	SwapBytes       uint64 `json:"swapBytes"`
	SwapMode        string `json:"swapMode,omitempty"`
	PIDs            uint64 `json:"pids"`
	Domain          bool   `json:"domain"`
	RunnerProcesses int    `json:"runnerProcesses"`
}

func readKernelLimits(root string) (KernelLimits, error) {
	return readKernelLimitsWithProc(root, "/proc")
}

func readKernelLimitsWithProc(root, proc string) (KernelLimits, error) {
	var proof KernelLimits
	read := func(name string) (string, error) {
		raw, err := os.ReadFile(filepath.Join(root, name))
		if err != nil || len(raw) > 4096 {
			return "", errors.New("local_checks_kernel_limits_unavailable")
		}
		return strings.TrimSpace(string(raw)), nil
	}
	cpu, err := read("cpu.max")
	if err != nil {
		return proof, err
	}
	fields := strings.Fields(cpu)
	if len(fields) != 2 {
		return proof, errors.New("local_checks_kernel_limits_invalid")
	}
	proof.CPUQuota, err = strconv.ParseUint(fields[0], 10, 64)
	if err != nil {
		return proof, errors.New("local_checks_kernel_limits_unbounded")
	}
	proof.CPUPeriod, err = strconv.ParseUint(fields[1], 10, 64)
	if err != nil || proof.CPUPeriod == 0 || proof.CPUPeriod > 1000000000 {
		return proof, errors.New("local_checks_kernel_limits_invalid")
	}
	for name, target := range map[string]*uint64{"memory.max": &proof.MemoryBytes, "pids.max": &proof.PIDs} {
		value, err := read(name)
		if err != nil {
			return proof, err
		}
		*target, err = strconv.ParseUint(value, 10, 64)
		if err != nil {
			return proof, errors.New("local_checks_kernel_limits_unbounded")
		}
	}
	swap, swapErr := os.ReadFile(filepath.Join(root, "memory.swap.max"))
	if swapErr == nil && len(swap) <= 4096 && strings.TrimSpace(string(swap)) != "max" {
		proof.SwapBytes, err = strconv.ParseUint(strings.TrimSpace(string(swap)), 10, 64)
		if err != nil {
			return proof, errors.New("local_checks_kernel_limits_invalid")
		}
	} else if (swapErr == nil && len(swap) <= 4096 && strings.TrimSpace(string(swap)) == "max") || errors.Is(swapErr, os.ErrNotExist) {
		if err := verifyHostNoSwap(proc); err != nil {
			return proof, err
		}
		proof.SwapMode = "host-no-swap"
	} else {
		return proof, errors.New("local_checks_kernel_limits_unavailable")
	}
	kind, err := read("cgroup.type")
	if err != nil {
		return proof, err
	}
	proof.Domain = kind == "domain"
	return proof, nil
}
func (p KernelLimits) Verify(memoryMiB uint64, cpus uint32, pids uint64) error {
	if (p.SwapMode != "" && p.SwapMode != "host-no-swap") || !p.Domain || p.CPUPeriod == 0 || p.CPUPeriod > 1000000000 || p.CPUQuota != p.CPUPeriod*uint64(cpus) || p.MemoryBytes != memoryMiB<<20 || p.SwapBytes != 0 || p.PIDs != pids || p.RunnerProcesses != 0 {
		return errors.New("local_checks_actual_kernel_limits_differ")
	}
	return nil
}

// No configured host swap is a distinct observed runtime condition, never a
// fabricated cgroup limit. Both independent kernel views must agree. Readiness
// rechecks this condition before every subsequent general dispatch.
func verifyHostNoSwap(proc string) error {
	invalid := errors.New("local_checks_host_no_swap_unproven")
	read := func(name string) ([]byte, error) {
		f, err := os.Open(filepath.Join(proc, name))
		if err != nil {
			return nil, err
		}
		defer f.Close()
		b, err := io.ReadAll(io.LimitReader(f, 16385))
		if err != nil || len(b) > 16384 {
			return nil, invalid
		}
		return b, nil
	}
	swaps, err := read("swaps")
	if err != nil {
		return invalid
	}
	rows := strings.Split(strings.TrimSpace(string(swaps)), "\n")
	if len(rows) != 1 || strings.Join(strings.Fields(rows[0]), " ") != "Filename Type Size Used Priority" {
		return invalid
	}
	memory, err := read("meminfo")
	if err != nil {
		return invalid
	}
	count := 0
	for _, line := range strings.Split(string(memory), "\n") {
		if strings.HasPrefix(line, "SwapTotal:") {
			count++
			if strings.Join(strings.Fields(line), " ") != "SwapTotal: 0 kB" {
				return invalid
			}
		}
	}
	if count != 1 {
		return invalid
	}
	return nil
}

// WriteKernelProbe is the packaged static helper's read-only probe mode. The
// root is fixed, and /proc enumeration reads only comm, never process arguments.
func WriteKernelProbe(output io.Writer) error {
	proof, err := readKernelLimits("/sys/fs/cgroup")
	if err != nil {
		return err
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return errors.New("local_checks_process_probe_unavailable")
	}
	count := 0
	for _, entry := range entries {
		if _, err := strconv.ParseUint(entry.Name(), 10, 32); err != nil {
			continue
		}
		count++
		if count > 8192 {
			return errors.New("local_checks_process_probe_limit")
		}
		comm, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "comm"))
		if err == nil && strings.TrimSpace(string(comm)) == "Runner.Listener" {
			proof.RunnerProcesses++
		}
	}
	return json.NewEncoder(output).Encode(proof)
}

type QualificationProof struct {
	Scope             string       `json:"scope"`
	Image             string       `json:"image"`
	ProbeSHA256       string       `json:"probeSHA256"`
	Outer             KernelLimits `json:"outer"`
	Nested            KernelLimits `json:"nested"`
	DiskQuotaEnforced bool         `json:"diskQuotaEnforced"`
}

// Qualify uses only the current packaged static helper and a scratch inner
// image. No registry pull, repository command, credential or GitHub process is
// involved. The native owner must retain its existing charge for this call.
func (d DockerNativeDriver) Qualify(ctx context.Context, id string, s Submission) (proof QualificationProof, result error) {
	bounded, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	observed, err := d.Inspect(bounded, id)
	if err != nil || !observed.Running {
		return proof, errors.New("local_checks_qualification_worker_unavailable")
	}
	executable, err := os.Executable()
	if err != nil {
		return proof, err
	}
	file, err := os.Open(executable)
	if err != nil {
		return proof, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 64<<20 {
		return proof, errors.New("local_checks_probe_binary_invalid")
	}
	binary, err := io.ReadAll(io.LimitReader(file, 64<<20+1))
	if err != nil || len(binary) > 64<<20 {
		return proof, errors.New("local_checks_probe_binary_invalid")
	}
	digest := sha256.Sum256(binary)
	proof = QualificationProof{Scope: "cgroup-isolation-only", Image: d.Image, ProbeSHA256: hex.EncodeToString(digest[:])}
	probePath := filepath.Join(d.DockerRoot, "farm-qualification-probe")
	target, err := os.OpenFile(probePath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0555)
	if err != nil {
		return proof, errors.New("local_checks_probe_stage_refused")
	}
	_, writeErr := target.Write(binary)
	closeErr := target.Close()
	if writeErr != nil || closeErr != nil {
		return proof, errors.New("local_checks_probe_stage_failed")
	}
	defer os.Remove(probePath)
	raw, err := d.command(bounded, "exec", id, "/var/lib/docker/farm-qualification-probe", "--local-checks-probe")
	if err != nil || json.Unmarshal(raw, &proof.Outer) != nil {
		return proof, errors.New("local_checks_outer_probe_failed")
	}
	if err := proof.Outer.Verify(s.MemoryMiB, s.CPUs, 4096); err != nil {
		return proof, err
	}
	image := "farm-local-checks-probe:" + proof.ProbeSHA256
	var archive bytes.Buffer
	writer := tar.NewWriter(&archive)
	for _, item := range []struct {
		name string
		mode int64
		data []byte
	}{{"Dockerfile", 0600, []byte("FROM scratch\nCOPY probe /probe\nENTRYPOINT [\"/probe\",\"--local-checks-probe\"]\n")}, {"probe", 0555, binary}} {
		if err := writer.WriteHeader(&tar.Header{Name: item.name, Mode: item.mode, Size: int64(len(item.data)), Typeflag: tar.TypeReg}); err != nil {
			return proof, err
		}
		if _, err := writer.Write(item.data); err != nil {
			return proof, err
		}
	}
	if err := writer.Close(); err != nil {
		return proof, err
	}
	if err := d.qualificationBuild(bounded, bytes.NewReader(archive.Bytes()), id, image); err != nil {
		return proof, err
	}
	raw, err = d.command(bounded, "exec", "--env", "DOCKER_HOST=unix:///var/run/docker.sock", id, "docker", "run", "--rm", "--pull", "never", "--network", "none", "--cgroupns", "private", "--cpus", "1", "--memory", "64m", "--memory-swap", "64m", "--pids-limit", "64", "--read-only", "--user", "65534:65534", image)
	if err != nil || json.Unmarshal(raw, &proof.Nested) != nil {
		return proof, errors.New("local_checks_nested_probe_failed")
	}
	if err := proof.Nested.Verify(64, 1, 64); err != nil {
		return proof, err
	}
	final, err := d.Inspect(bounded, id)
	if err != nil || !final.Running || final.CPUs != s.CPUs || final.MemoryMiB != s.MemoryMiB || final.RequestID != s.RequestID || final.SourceDigest != s.BundleSHA256 {
		return proof, errors.New("local_checks_qualification_worker_changed")
	}
	return proof, nil
}
func (d DockerNativeDriver) qualificationBuild(ctx context.Context, input io.Reader, id, image string) error {
	command := exec.CommandContext(ctx, "docker", "exec", "--interactive", "--env", "DOCKER_HOST=unix:///var/run/docker.sock", id, "docker", "build", "--network", "none", "--tag", image, "-")
	command.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent", "DOCKER_HOST=unix:///var/run/docker.sock"}
	command.Stdin = input
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return errors.New("local_checks_nested_probe_image_failed")
	}
	return nil
}

func (w *nativeWorker) Qualify(ctx context.Context, s Submission) (NativeReceipt, error) {
	if err := validateQualificationSubmission(s); err != nil {
		return NativeReceipt{}, err
	}
	bounded, cancel := context.WithTimeout(ctx, time.Duration(s.TimeoutSeconds)*time.Second)
	defer cancel()
	ctx = bounded

	qualifier, ok := w.driver.(interface {
		Qualify(context.Context, string, Submission) (QualificationProof, error)
		Stop(context.Context, string) error
	})
	if !ok {
		return NativeReceipt{}, errors.New("local_checks_qualification_driver_required")
	}
	r, err := w.CreateAndAdmit(ctx, s)
	if err != nil {
		return r, err
	}
	owner := &nativeExecutionOwner{worker: w, receipt: r, host: "qualification"}
	reservation := Reservation{Host: "qualification", RequestID: s.RequestID, Commit: s.Commit, Base: s.Base, BundleSHA256: s.BundleSHA256, Handle: r.Fence, CPUs: s.CPUs, MemoryMiB: s.MemoryMiB, ScratchMiB: s.ScratchMiB, TimeoutSeconds: s.TimeoutSeconds}
	err = owner.WithExecution(ctx, reservation, func(held context.Context, _ OwnerVerifier, _ []string) error {
		proof, err := qualifier.Qualify(held, r.ContainerID, s)
		if err != nil {
			return err
		}
		if proof.Scope != "cgroup-isolation-only" || proof.Image != r.Worker.Image || !bundleID.MatchString(proof.ProbeSHA256) || proof.DiskQuotaEnforced {
			return errors.New("local_checks_qualification_proof_invalid")
		}
		if err := proof.Outer.Verify(s.MemoryMiB, s.CPUs, 4096); err != nil {
			return err
		}
		if err := proof.Nested.Verify(64, 1, 64); err != nil {
			return err
		}
		r.Qualification = &proof
		return w.save(r)
	})
	final, loadErr := w.load(s.RequestID)
	return final, errors.Join(err, loadErr)
}

func validateQualificationSubmission(s Submission) error {
	if err := s.Validate(); err != nil {
		return err
	}
	if s.CPUs > 2 || s.MemoryMiB < 256 || s.MemoryMiB > 12288 || s.TimeoutSeconds < 30 || s.TimeoutSeconds > 180 || s.ScratchMiB < 1024 || s.ScratchMiB > 8192 {
		return errors.New("local_checks_qualification_budget_invalid")
	}
	return nil
}
func availableScratch(root string, requiredMiB uint64) error {
	if requiredMiB == 0 || requiredMiB > 1048576 {
		return errors.New("local_checks_scratch_budget_invalid")
	}
	var stats unix.Statfs_t
	if err := unix.Statfs(root, &stats); err != nil || stats.Bsize <= 0 {
		return errors.New("local_checks_scratch_availability_unavailable")
	}
	block := uint64(stats.Bsize)
	required := (requiredMiB << 20) + block - 1
	if stats.Bavail < required/block {
		return errors.New("local_checks_scratch_capacity_unavailable")
	}
	return nil
}
