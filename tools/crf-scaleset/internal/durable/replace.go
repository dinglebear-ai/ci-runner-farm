package durable

import (
	"errors"
	"io"
	"os"
	"path/filepath"
)

var ErrCapacityExceeded = errors.New("atomic_replace_capacity_exhausted")

// Replace writes a same-directory temporary file, syncs it, atomically replaces
// path, and syncs the parent directory so the rename survives a crash.
func Replace(path, pattern string, mode os.FileMode, maxBytes int64, write func(io.Writer) error) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	fail := func(err error) error {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		return fail(err)
	}
	if err := write(tmp); err != nil {
		return fail(err)
	}
	info, err := tmp.Stat()
	if err != nil {
		return fail(err)
	}
	if maxBytes > 0 && info.Size() > maxBytes {
		return fail(ErrCapacityExceeded)
	}
	if err := tmp.Sync(); err != nil {
		return fail(err)
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	directory, err := os.Open(dir)
	if err != nil {
		return err
	}
	if err := directory.Sync(); err != nil {
		_ = directory.Close()
		return err
	}
	return directory.Close()
}
