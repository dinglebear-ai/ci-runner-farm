package nativebackend

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
)

const ClassicEngine = "/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
const ClassicBootPlugin = "/boot/config/plugins/ci-runner-farm.plg"

type MigrationStatus struct {
	Schema                string `json:"schema"`
	ClassicInstalled      bool   `json:"classicInstalled"`
	BootReplay            bool   `json:"bootReplay"`
	Workers               int    `json:"workers"`
	RetainedConfiguration bool   `json:"retainedConfiguration"`
	Ready                 bool   `json:"ready"`
	NextStep              string `json:"nextStep"`
}

// InspectClassicMigration reads only presence and exact process argv identities;
// it never executes, stops, removes or copies the classic installation.
func InspectClassicMigration(ctx context.Context) (MigrationStatus, error) {
	return inspectClassicMigration(ctx, ClassicEngine, ClassicBootPlugin, "/proc", "/boot/config/plugins/ci-runner-farm/ci-runner-farm.cfg")
}
func inspectClassicMigration(ctx context.Context, engine, boot, proc, config string) (MigrationStatus, error) {
	result := MigrationStatus{Schema: "native-migration-v1"}
	for path, target := range map[string]*bool{engine: &result.ClassicInstalled, boot: &result.BootReplay, config: &result.RetainedConfiguration} {
		_, err := os.Lstat(path)
		if err == nil {
			*target = true
		} else if !errors.Is(err, os.ErrNotExist) {
			return result, err
		}
	}
	entries, err := os.ReadDir(proc)
	if err != nil {
		return result, err
	}
	if len(entries) > 32768 {
		return result, errors.New("process_inventory_exceeds_bound")
	}
	for _, entry := range entries {
		if err = ctx.Err(); err != nil {
			return result, err
		}
		if _, err = strconv.ParseUint(entry.Name(), 10, 32); err != nil {
			continue
		}
		data, readErr := readBounded(filepath.Join(proc, entry.Name(), "cmdline"), 1<<20)
		if errors.Is(readErr, os.ErrNotExist) {
			continue
		}
		if readErr != nil {
			return result, errors.New("classic_worker_inventory_unavailable")
		}
		args := strings.Split(string(data), "\x00")
		creator := len(args) > 0 && args[0] == engine
		if len(args) > 1 {
			switch filepath.Base(args[0]) {
			case "bash", "sh", "dash":
				for _, arg := range args[1:] {
					if strings.HasPrefix(arg, "-") {
						continue
					}
					creator = arg == engine
					break
				}
			}
		}
		if creator {
			result.Workers++
		}
	}
	result.Ready = !result.ClassicInstalled && !result.BootReplay && result.Workers == 0
	result.NextStep = "Retire the classic plugin through its supported Plugin Manager lifecycle; configuration and credentials are retained. Bind runner-cache to the existing cache directory, then complete migration."
	if result.Ready {
		result.NextStep = "Classic creators are absent. Start the native backend, bind the original cache directory and complete migration before starting runners."
		if !result.RetainedConfiguration {
			result.NextStep = "No classic owner or retained configuration found. Configure a fresh native Farm; no migration is needed."
		}
	}
	return result, nil
}
func requireClassicRetired(ctx context.Context) error {
	checkctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	status, err := InspectClassicMigration(checkctx)
	if err != nil {
		return err
	}
	if !status.Ready {
		return errors.New("classic_owner_requires_supported_retirement")
	}
	return nil
}

type migrationReceipt struct {
	Schema       int    `json:"schema"`
	ConfigSHA256 string `json:"configSha256"`
	CacheRoot    string `json:"cacheRoot"`
	OwnerEpoch   string `json:"ownerEpoch,omitempty"`
	OwnerSHA256  string `json:"ownerSha256,omitempty"`
}

func (s *Service) completeMigration(ctx context.Context, values map[string]string) (message string, result error) {
	e, ok := s.engine.(*Engine)
	if !ok {
		return "", errors.New("migration_requires_native_engine")
	}
	if err := requireClassicRetired(ctx); err != nil {
		return "", err
	}
	configPath := filepath.Join(s.config, "ci-runner-farm.cfg")
	// Read the retained configuration through the original parser and validator.
	if _, err := e.Run(ctx, "native-config-check", nil, ""); err != nil {
		return "", err
	}
	out, err := e.Run(ctx, "native-config-json", nil, "")
	if err != nil {
		return "", err
	}
	var config map[string]string
	if json.Unmarshal([]byte(out), &config) != nil {
		return "", errors.New("retained_config_unavailable")
	}
	if e.BoundCache == "" || values["cachePath"] != e.BoundCache || config["CACHE_ROOT"] != e.BoundCache {
		return "", errors.New("bind_original_cache_directory_before_migration")
	}
	bytes, err := readBounded(configPath, 65536)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(bytes)
	receipt := migrationReceipt{Schema: 1, ConfigSHA256: hex.EncodeToString(sum[:]), CacheRoot: config["CACHE_ROOT"]}
	// An existing shared owner is the SAME durable owner after UI replacement.
	// Pin it exclusively while recording the handoff; never initialize/replace it.
	if _, err = os.Lstat(hostcapacity.ConfigPath); err == nil {
		lockctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		lease, acquireErr := hostcapacity.Acquire(lockctx, hostcapacity.ConfigPath, true)
		if acquireErr != nil {
			return "", acquireErr
		}
		defer func() { result = errors.Join(result, lease.Close()) }()
		data, encodeErr := json.Marshal(lease.Config)
		if encodeErr != nil {
			return "", encodeErr
		}
		ownerSum := sha256.Sum256(data)
		receipt.OwnerEpoch = lease.Config.Epoch
		receipt.OwnerSHA256 = hex.EncodeToString(ownerSum[:])
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	} else if _, err = e.Run(ctx, "native-standalone-preflight", nil, ""); err != nil {
		return "", errors.New("legacy_shared_owner_requires_existing_fenced_handoff")
	}
	if err = requireClassicRetired(ctx); err != nil {
		return "", err
	}
	if err = commitMigrationReceipt(filepath.Join(s.config, "native-migration.json"), configPath, sum, receipt); err != nil {
		return "", err
	}
	return fmt.Sprintf("Native handoff recorded for the existing cache and owner. Configuration, credentials, ledger and receipts were preserved; runners were not started. Shared owner present: %t.", receipt.OwnerEpoch != ""), nil
}

func commitMigrationReceipt(path, configPath string, expected [32]byte, receipt migrationReceipt) error {
	current, err := readBounded(configPath, 65536)
	if err != nil {
		return err
	}
	if sha256.Sum256(current) != expected {
		return errors.New("retained_configuration_changed_during_handoff")
	}
	data, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	return atomicWrite(path, data, 0600)
}
