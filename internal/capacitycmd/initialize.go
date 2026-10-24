// Package capacitycmd composes Farm's native controller without a QA runtime.
package capacitycmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
)

func initializeStandalone(ctx context.Context, config *hostcapacity.Config, controller *farmcapacity.Controller) error {
	return initializeStandaloneOwner(ctx, config, controller, false)
}

// Recovery only re-proves an existing epoch while starts remain closed. The
// controller's adoption is idempotent and retains grants, fences and receipts.
func recoverStandalone(ctx context.Context, config *hostcapacity.Config, controller *farmcapacity.Controller, epoch, identity string) error {
	current, err := hostcapacity.StandaloneInitializationIdentity(config)
	if err != nil || current != identity || epoch != config.Epoch || config.PoolExpansion != nil {
		return errors.New("standalone recovery ownership changed")
	}
	if config.Mode == "active" {
		// Activation proves an initialized ledger already existed. Recovery may
		// repair receipts, but must never turn missing/corrupt state into a new
		// ledger (and new release fences).
		state, err := controller.Broker.Diagnose(&controller.Policy)
		if err != nil {
			return errors.Join(errors.New("activated owner ledger unavailable; preserve state for operator recovery"), err)
		}
		if !state.PolicyMatches {
			return errors.New("activated owner ledger policy changed")
		}
	} else if _, err := os.Lstat(config.LedgerPath); errors.Is(err, os.ErrNotExist) {
		file, openErr := os.OpenFile(config.ReceiptRoot, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if openErr == nil {
			names, readErr := file.Readdirnames(1)
			closeErr := file.Close()
			if len(names) != 0 {
				return errors.New("existing receipts require original initialization ledger")
			}
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				return readErr
			}
			if closeErr != nil {
				return closeErr
			}
		} else if !errors.Is(openErr, os.ErrNotExist) {
			return openErr
		}
	} else if err != nil {
		return err
	}
	if err := validateInitializationClosure(filepath.Join(filepath.Dir(hostcapacity.ConfigPath), "shared-capacity.closed"), epoch, identity); err != nil {
		return err
	}
	return initializeStandaloneOwner(ctx, config, controller, true)
}

func initializeStandaloneOwner(ctx context.Context, config *hostcapacity.Config, controller *farmcapacity.Controller, recovery bool) error {
	if (config.Mode != "closed" && !(recovery && config.Mode == "active")) || len(config.Consumers) != 0 || len(config.Policy.Pools) != 1 {
		return errors.New("standalone initialization requires closed build-only ownership")
	}
	path := "/boot/config/plugins/ci-runner-farm/shared-capacity.closed"
	info, err := os.Lstat(path)
	if err != nil {
		return errors.New("standalone initialization requires native starts to be closed")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0o022 != 0 {
		return errors.New("native start closure is not a protected root-owned regular file")
	}
	return controller.InitializeStandalone(ctx)
}

// Verification does not adopt workloads or initialize a ledger. It only proves
// the completed owner under the existing lease and fleet lock.
func verifyCompletedStandalone(config *hostcapacity.Config, controller *farmcapacity.Controller, epoch, identity string) error {
	current, err := hostcapacity.StandaloneInitializationIdentity(config)
	if err != nil || current != identity || config.Epoch != epoch || config.Mode != "active" {
		return errors.New("completed initialization ownership changed")
	}
	state, err := controller.Broker.Diagnose(&controller.Policy)
	if err != nil {
		return errors.Join(errors.New("completed initialization ledger unavailable"), err)
	}
	if !state.PolicyMatches {
		return errors.New("completed initialization ledger policy changed")
	}
	return nil
}

func validateInitializationClosure(path, epoch, identity string) error {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 256 {
		return errors.New("unsafe initialization closure")
	}
	data, err := io.ReadAll(io.LimitReader(f, 257))
	if err != nil {
		return err
	}
	if !bytes.Equal(data, hostcapacity.StandaloneInitializationClosure(epoch, identity)) {
		return errors.New("initialization closure belongs to another workflow")
	}
	return nil
}

// Caller retains the real fleet lock and host owner lease through cleanup.
func retireInitialization(config *hostcapacity.Config, epoch, identity string, removeClosure bool) error {
	return retireInitializationAt(filepath.Dir(hostcapacity.ConfigPath), epoch, identity, removeClosure)
}
func retireInitializationAt(root, epoch, identity string, removeClosure bool) error {
	closure := filepath.Join(root, "shared-capacity.closed")
	if removeClosure {
		if err := validateInitializationClosure(closure, epoch, identity); err != nil {
			return err
		}
		if err := os.Remove(closure); err != nil {
			return err
		}
		if err := syncInitializationDirectory(root); err != nil {
			return err
		}
	} else if _, err := os.Lstat(closure); !errors.Is(err, os.ErrNotExist) {
		return errors.New("another workflow closed admission; completed initialization cannot reopen it")
	}
	// Removing the completed journal prevents a later fence from being mistaken
	// for initialization. A crash before this step is resolved by read-only verify.
	if err := os.Remove(filepath.Join(root, "native-admission-init.json")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return syncInitializationDirectory(root)
}
func syncInitializationDirectory(root string) error {
	f, err := os.Open(root)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
