package nativebackend

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"golang.org/x/sys/unix"
)

// initializeAdmission only creates a fresh standalone owner. Existing policy,
// consumers, ledger and epoch require the original explicit handoff workflow.
func (s *Service) initializeAdmission(ctx context.Context, values map[string]string) (string, error) {
	e, ok := s.engine.(*Engine)
	if !ok {
		return "", errors.New("admission_requires_native_engine")
	}
	path := hostcapacity.ConfigPath
	if _, err := os.Lstat(filepath.Join(s.config, "native-admission-init.json")); err == nil {
		return "", errors.New("native_initialization_exists_use_recovery")
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		return "", errors.New("existing_admission_requires_explicit_handoff")
	}
	if _, err := e.Run(ctx, "native-standalone-preflight", nil, ""); err != nil {
		return "", errors.New("existing_shared_owner_requires_fenced_handoff")
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
	if e.BoundCache == "" || cache != e.BoundCache {
		return "", errors.New("admission_cache_must_match_core_binding")
	}
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
	if err = bindRegistrationSettings(&owner, config); err != nil {
		return "", err
	}
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
	journal := admissionJournal{Schema: 1, Owner: owner, RegistrationScope: owner.EffectiveRegistrationScope(), RegistrationRepositories: owner.RegistrationRepositories}
	journalBytes, err := json.Marshal(journal)
	if err != nil {
		return "", err
	}
	if err = publishExclusive(filepath.Join(s.config, "native-admission-init.json"), journalBytes); err != nil {
		return "", fmt.Errorf("initialization journal exists or cannot be committed; use explicit recovery: %w", err)
	}
	if err = publishExclusive(path, bytes); err != nil {
		return "", err
	}
	return s.finishAdmission(ctx, e, e.CapacityRoot, owner)
}

type admissionJournal struct {
	RegistrationScope        string              `json:"registrationScope,omitempty"`
	RegistrationRepositories []string            `json:"registrationRepositories,omitempty"`
	Schema                   int                 `json:"schema"`
	Owner                    hostcapacity.Config `json:"owner"`
}

// Recover only replays the exact native-owned initialization journal. It never
// creates another epoch, relocates state or replaces an existing policy.
func (s *Service) recoverAdmission(ctx context.Context) (string, error) {
	e, ok := s.engine.(*Engine)
	if !ok {
		return "", errors.New("admission_requires_native_engine")
	}
	journal, err := readAdmissionJournal(filepath.Join(s.config, "native-admission-init.json"), 0)
	if err != nil {
		return "", err
	}
	host, err := os.Hostname()
	if err != nil {
		return "", err
	}
	if journal.Schema != 1 || journal.Owner.Mode != "closed" || journal.Owner.Validate(host) != nil || len(journal.Owner.Consumers) != 0 || len(journal.Owner.Policy.Pools) != 1 || journal.Owner.PoolExpansion != nil {
		return "", errors.New("invalid_native_initialization_journal")
	}
	if journal.Owner.TokenPath != filepath.Join(s.config, "token") || journal.Owner.LockPath != filepath.Join(e.CapacityRoot, "owner.lock") {
		return "", errors.New("initialization_storage_binding_changed")
	}
	out, err := e.Run(ctx, "native-config-json", nil, "")
	if err != nil {
		return "", err
	}
	var config map[string]string
	if json.Unmarshal([]byte(out), &config) != nil || e.BoundCache == "" || config["CACHE_ROOT"] != e.BoundCache || journal.Owner.LedgerPath != filepath.Join(config["CACHE_ROOT"], "native-capacity", "ledger.db") || journal.Owner.ReceiptRoot != filepath.Join(config["CACHE_ROOT"], "native-capacity", "receipts") || journal.Owner.Organization != config["GH_OWNER"] {
		return "", errors.New("initialization_settings_changed_restore_original_binding")
	}
	expectedScope := journal.Owner
	plannedScope := journal.RegistrationScope
	if plannedScope == "" {
		plannedScope = "org"
	}
	if bindRegistrationSettings(&expectedScope, config) != nil || expectedScope.EffectiveRegistrationScope() != plannedScope || !reflect.DeepEqual(expectedScope.RegistrationRepositories, journal.RegistrationRepositories) {
		return "", errors.New("initialization_registration_scope_changed")
	}
	if _, err = os.Lstat(hostcapacity.ConfigPath); errors.Is(err, os.ErrNotExist) {
		bytes, encodeErr := json.Marshal(journal.Owner)
		if encodeErr != nil {
			return "", encodeErr
		}
		if err = publishExclusive(hostcapacity.ConfigPath, bytes); err != nil {
			return "", err
		}
	} else if err != nil {
		return "", err
	}
	current, err := hostcapacity.Load(hostcapacity.ConfigPath)
	if err != nil {
		return "", err
	}
	journal.Owner.RegistrationScope = expectedScope.RegistrationScope
	journal.Owner.RegistrationRepositories = expectedScope.RegistrationRepositories
	return s.resumeAdmission(ctx, e, e.CapacityRoot, journal.Owner, current)
}

// The daemon's completed shortcut must use the read-only controller verifier;
// it never substitutes an old journal for evidence that the ledger still exists.
func (s *Service) resumeAdmission(ctx context.Context, engine Runner, capacityRoot string, owner hostcapacity.Config, current *hostcapacity.Config) (string, error) {
	if err := validateRecoveryOwner(&owner, current); err != nil {
		return "", err
	}
	closure := filepath.Join(capacityRoot, "shared-capacity.closed")
	if _, err := os.Lstat(closure); errors.Is(err, os.ErrNotExist) && current.Mode == "active" {
		identity, err := hostcapacity.StandaloneInitializationIdentity(&owner)
		if err != nil {
			return "", err
		}
		log, err := engine.Run(ctx, "native-verify-initialize", []string{owner.Epoch, identity}, "")
		if err != nil {
			return log, err
		}
		if err := s.finishRegistrationInitialization(ctx, owner); err != nil {
			return "", err
		}
		return "Existing initialization verified; completed journal retired.", nil
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	return s.finishAdmission(ctx, engine, capacityRoot, owner)
}

func validateRecoveryOwner(planned, current *hostcapacity.Config) error {
	copy := *current
	plannedCopy := *planned
	plannedCopy.RegistrationScope = ""
	plannedCopy.RegistrationRepositories = nil
	copy.RegistrationScope = ""
	copy.RegistrationRepositories = nil
	copy.Mode = "closed"
	if (current.Mode != "closed" && current.Mode != "active") || !reflect.DeepEqual(&plannedCopy, &copy) {
		return errors.New("initialization_owner_changed_recovery_refused")
	}
	return nil
}

func (s *Service) finishAdmission(ctx context.Context, engine Runner, capacityRoot string, owner hostcapacity.Config) (string, error) {
	closure := filepath.Join(capacityRoot, "shared-capacity.closed")
	identity, err := hostcapacity.StandaloneInitializationIdentity(&owner)
	if err != nil {
		return "", err
	}
	marker := hostcapacity.StandaloneInitializationClosure(owner.Epoch, identity)
	if err = publishExclusive(closure, marker); err != nil {
		data, readErr := readProtectedInitializationClosure(closure)
		if readErr != nil || string(data) != string(marker) {
			return "", errors.New("initialization_closure_owned_by_another_workflow")
		}
	}
	action := "native-recover-initialize"
	args := []string{owner.Epoch, identity}
	log, err := engine.Run(ctx, action, args, "")
	if err != nil {
		return log, fmt.Errorf("initialization completion unconfirmed; original owner preserved; inspect admission and closure state, then use Recover admission: %w", err)
	}
	if err := s.finishRegistrationInitialization(ctx, owner); err != nil {
		return "", err
	}
	return "Standalone Farm admission initialized using the original owner and controller.", nil
}

func readAdmissionJournal(path string, owner uint32) (admissionJournal, error) {
	var journal admissionJournal
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return journal, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return journal, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != owner || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 65536 {
		return journal, errors.New("unsafe_initialization_journal")
	}
	decoder := json.NewDecoder(io.LimitReader(f, 65537))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&journal); err != nil {
		return journal, err
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return journal, errors.New("invalid_initialization_journal")
	}
	return journal, nil
}

// Rename a complete synced private file into place without replacing any existing
// identity. A crash cannot leave a partly written owner or journal at its name.
func publishExclusive(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".native-initialize-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if err = f.Chmod(0600); err != nil {
		return err
	}
	if _, err = f.Write(data); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = unix.Renameat2(unix.AT_FDCWD, f.Name(), unix.AT_FDCWD, path, unix.RENAME_NOREPLACE); err != nil {
		return err
	}
	return syncParent(path)
}

func readProtectedInitializationClosure(path string) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 256 {
		return nil, errors.New("unsafe_initialization_closure")
	}
	return io.ReadAll(io.LimitReader(f, 257))
}

func bindRegistrationSettings(owner *hostcapacity.Config, settings map[string]string) error {
	owner.RegistrationScope = settings["GH_SCOPE"]
	if owner.RegistrationScope == "" {
		owner.RegistrationScope = "org"
	}
	owner.RegistrationRepositories = nil
	if owner.RegistrationScope == "repo" {
		owner.RegistrationRepositories = strings.Fields(settings["GH_REPOS"])
	}
	return owner.ValidateRegistrationPolicy()
}

func (s *Service) finishRegistrationInitialization(ctx context.Context, owner hostcapacity.Config) error {
	if owner.EffectiveRegistrationScope() == "repo" {
		proposal := s.registrationPolicyProposal()
		if !proposal.OK {
			return errors.New("repository_registration_policy_review_required_after_shared_activation")
		}
		var materials map[string]any
		if json.Unmarshal([]byte(proposal.Data.(string)), &materials) != nil {
			return errors.New("repository_registration_policy_proposal_invalid")
		}
		if materials["changed"] == true {
			_, err := s.updateRegistrationPolicy(ctx, map[string]string{"expectedPolicySHA256": materials["expectedPolicySHA256"].(string), "expectedSettingsSHA256": materials["expectedSettingsSHA256"].(string), "expectedRegistrationPolicySHA256": materials["expectedRegistrationPolicySHA256"].(string)})
			if err != nil {
				return err
			}
		}
	}
	return nil
}
