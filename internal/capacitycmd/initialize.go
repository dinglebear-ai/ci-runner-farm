// Package capacitycmd composes Farm's native controller without a QA runtime.
package capacitycmd

import (
	"context"
	"errors"
	"io"
	"os"
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
