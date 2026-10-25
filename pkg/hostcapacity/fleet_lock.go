package hostcapacity

import (
	"errors"
	"os"
	"syscall"
)

// VerifyInheritedFleetLock reuses the native owner's exact FD8/open-file custody.
// Fstat avoids creating an os.File finalizer that could close the inherited FD.
func VerifyInheritedFleetLock() error {
	var actual syscall.Stat_t
	if err := syscall.Fstat(8, &actual); err != nil {
		return errors.New("native Farm fleet lock is required")
	}
	wanted, err := os.Lstat("/var/local/emhttp/ci-runner-farm/fleet.lock")
	if err != nil {
		return err
	}
	target, ok := wanted.Sys().(*syscall.Stat_t)
	if !ok || actual.Mode&syscall.S_IFMT != syscall.S_IFREG || !wanted.Mode().IsRegular() || actual.Dev != target.Dev || actual.Ino != target.Ino {
		return errors.New("inherited native Farm lock differs")
	}
	if err := syscall.Flock(8, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("native Farm lifecycle is busy")
	}
	return nil
}
