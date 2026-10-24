package nativebackend

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// initializeAdmission only creates a fresh standalone owner. Existing policy,
// consumers, ledger and epoch require the original explicit handoff workflow.
func (s *Service) initializeAdmission(ctx context.Context, values map[string]string) (string, error) {
	e, ok := s.engine.(*Engine)
	if !ok {
		return "", errors.New("admission_requires_native_engine")
	}
	path := hostcapacity.ConfigPath
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		return "", errors.New("existing_admission_requires_explicit_handoff")
	}
	memory, err := strconv.ParseUint(values["memoryMiB"], 10, 64)
	if err != nil || memory < 1024 {
		return "", errors.New("invalid_memory_budget")
	}
	cpus, err := strconv.ParseUint(values["vcpus"], 10, 32)
	if err != nil || cpus == 0 {
		return "", errors.New("invalid_cpu_budget")
	}
	if cpus > uint64(runtime.NumCPU()) {
		return "", errors.New("cpu_budget_exceeds_host")
	}
	meminfo, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return "", errors.New("host_memory_unavailable")
	}
	var total uint64
	for _, line := range strings.Split(string(meminfo), "\n") {
		if strings.HasPrefix(line, "MemTotal:") {
			_, err = fmt.Sscanf(line, "MemTotal: %d kB", &total)
			if err != nil {
				return "", err
			}
			total /= 1024
			break
		}
	}
	if total <= 8192 || memory > total-8192 {
		return "", errors.New("memory_budget_must_preserve_8192_MiB_host_reserve")
	}
	out, err := s.engine.Run(ctx, "native-config-json", nil, "")
	if err != nil {
		return "", err
	}
	var config map[string]string
	if json.Unmarshal([]byte(out), &config) != nil {
		return "", errors.New("config_unavailable")
	}
	cache := config["CACHE_ROOT"]
	if !filepath.IsAbs(cache) || filepath.Clean(cache) != cache || cache == "/" {
		return "", errors.New("bound_cache_required")
	}
	root := filepath.Join(cache, "native-capacity")
	if err = os.MkdirAll(root, 0700); err != nil {
		return "", err
	}
	if err = CheckDirectory(root, 0); err != nil {
		return "", err
	}
	for _, name := range []string{"ledger.db", "receipts"} {
		if _, err = os.Lstat(filepath.Join(root, name)); !errors.Is(err, os.ErrNotExist) {
			return "", errors.New("existing_capacity_state_requires_explicit_recovery")
		}
	}
	epoch := make([]byte, 16)
	if _, err = rand.Read(epoch); err != nil {
		return "", err
	}
	host, err := os.Hostname()
	if err != nil {
		return "", err
	}
	limits, err := e.Run(ctx, "native-build-limits", nil, "")
	if err != nil {
		return "", err
	}
	var floor, maximum, defaultCPUs uint32
	var defaultMemory uint64
	if _, err = fmt.Sscanf(strings.TrimSpace(limits), "%d|%d|%d|%d", &floor, &maximum, &defaultMemory, &defaultCPUs); err != nil || floor == 0 || maximum < floor || defaultMemory < 12288 || defaultMemory > 16384 {
		return "", errors.New("native_build_limits_incompatible_with_controller")
	}
	owner := hostcapacity.Config{Schema: 1, Host: host, Epoch: hex.EncodeToString(epoch), Organization: config["GH_OWNER"], LedgerPath: filepath.Join(root, "ledger.db"), ReceiptRoot: filepath.Join(root, "receipts"), TokenPath: filepath.Join(s.config, "token"), LockPath: filepath.Join(e.CapacityRoot, "owner.lock"), Mode: "closed", Policy: sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: memory, VCPUs: uint32(cpus)}, AgingSeconds: 300, Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: defaultMemory, VCPUs: defaultCPUs}, MaxCost: sharedcapacity.Resources{MemoryMiB: memory, VCPUs: uint32(cpus)}, Minimum: floor, Maximum: maximum, Priority: 3}}}}
	if err = owner.Validate(host); err != nil {
		return "", err
	}
	bytes, err := json.Marshal(owner)
	if err != nil {
		return "", err
	}
	if err = os.MkdirAll(e.CapacityRoot, 0700); err != nil {
		return "", err
	}
	if err = CheckDirectory(e.CapacityRoot, 0); err != nil {
		return "", err
	}
	// O_EXCL prevents replacement of concurrent or existing durable ownership.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return "", err
	}
	_, err = f.Write(bytes)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return "", err
	}
	if closeErr != nil {
		return "", closeErr
	}
	if err = syncParent(path); err != nil {
		return "", err
	}
	if err = atomicWrite(filepath.Join(e.CapacityRoot, "shared-capacity.closed"), []byte("closed for standalone initialization\n"), 0600); err != nil {
		return "", err
	}
	log, err := e.Run(ctx, "native-initialize", nil, "")
	if err != nil {
		return log, fmt.Errorf("standalone initialization incomplete; preserve closed owner and retry through explicit recovery: %w", err)
	}
	// Existing controller initialization sets mode active; opening starts is the
	// final explicit commit after its empty-inventory and ledger checks succeed.
	if err = os.Remove(filepath.Join(e.CapacityRoot, "shared-capacity.closed")); err != nil {
		return "", err
	}
	if err = syncParent(path); err != nil {
		return "", err
	}
	return "Standalone Farm admission initialized using the existing controller.", nil
}
