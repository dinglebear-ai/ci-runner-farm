package localchecks

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"golang.org/x/sys/unix"
)

// ProtectedBinding is an operator-reviewed qualification of one immutable
// worker image and private root. Network requests cannot supply or override it.
// Qualification-only bindings cannot authorize ordinary checks before acceptance.
type ProtectedBinding struct {
	Version          int    `json:"version"`
	Epoch            string `json:"epoch"`
	Host             string `json:"host"`
	Image            string `json:"image"`
	Root             string `json:"root"`
	RuntimeQualified bool   `json:"runtimeQualified"`
}

func LoadProtectedBinding(path string) (ProtectedBinding, error) {
	return loadProtectedBinding(path, 0)
}
func loadProtectedBinding(path string, owner uint32, qualificationOnly ...bool) (ProtectedBinding, error) {
	var b ProtectedBinding
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil || !filepath.IsAbs(path) || canonical != path {
		return b, errors.New("local_checks_protected_binding_unavailable")
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return b, errors.New("local_checks_protected_binding_unavailable")
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return b, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != owner || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 8192 {
		return b, errors.New("local_checks_protected_binding_invalid")
	}
	decoder := json.NewDecoder(io.LimitReader(f, 8193))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&b) != nil || decoder.Decode(new(any)) != io.EOF {
		return b, errors.New("local_checks_protected_binding_invalid")
	}
	if b.Version != 1 || !nativeEpoch.MatchString(b.Epoch) || !identifier.MatchString(b.Host) || !filepath.IsAbs(b.Root) || filepath.Clean(b.Root) != b.Root || b.Root == "/" || (!b.RuntimeQualified && !(len(qualificationOnly) == 1 && qualificationOnly[0])) {
		return b, errors.New("local_checks_runtime_not_qualified")
	}
	if err := (WorkerBinding{Image: b.Image, SourceRoot: filepath.Join(b.Root, "source"), DockerRoot: filepath.Join(b.Root, "docker")}).Validate(); err != nil {
		return b, err
	}
	return b, nil
}

// RunProtected is the typed native-helper entrypoint. Fixed private paths derive
// only from the protected binding and validated request identity. Host policy,
// epoch, FD8, ledger, creation intent and immutable Docker proof remain mandatory.
func RunProtected(ctx context.Context, bindingPath string, input io.Reader, output io.Writer) error {
	if os.Geteuid() != 0 {
		return errors.New("local_checks_native_root_required")
	}
	command, dependency, err := DecodeNativeEnvelope(input)
	if err != nil {
		return err
	}
	binding, err := loadProtectedBinding(bindingPath, 0, command.Action == "qualify" || command.Action == "complete" || command.Action == "cancel")
	if err != nil {
		return err
	}
	if binding.Epoch != command.Epoch {
		return errors.New("local_checks_native_owner_changed")
	}
	requestID := command.RequestID
	if command.Submission != nil {
		requestID = command.Submission.RequestID
	}
	root := filepath.Join(binding.Root, requestID)
	configuration := NativeConfiguration{ConfigPath: hostcapacity.ConfigPath, Epoch: binding.Epoch, Image: binding.Image, Host: binding.Host, SnapshotRoot: root, DockerRoot: filepath.Join(root, "docker"), EvidenceRoot: filepath.Join(root, "evidence")}
	if dependency != "" {
		configuration.SecretEnvironment = []string{"EX_STANDARDS_TOKEN=" + dependency}
	}

	if err := privateOwnedDirectory(binding.Root, 0); err != nil {
		return err
	}
	if err := privateOwnedDirectory(root, 0); err != nil {
		return err
	}
	receipt, err := HandleNativeCommand(ctx, configuration, command)
	if encodeErr := json.NewEncoder(output).Encode(receipt); encodeErr != nil {
		return errors.Join(err, encodeErr)
	}
	return err
}

func privateOwnedDirectory(path string, owner uint32) error {
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil || canonical != path {
		return errors.New("local_checks_private_worker_directory_required")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return errors.New("local_checks_private_worker_directory_required")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != owner || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("local_checks_private_worker_directory_required")
	}
	return nil
}
func preparePrivateDockerRoot(root, path string, owner uint32) error {
	if filepath.Dir(path) != root || filepath.Base(path) != "docker" {
		return errors.New("local_checks_private_worker_directory_required")
	}
	if err := privateOwnedDirectory(root, owner); err != nil {
		return err
	}
	if err := os.Mkdir(path, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return errors.New("local_checks_private_worker_directory_required")
	}
	return privateOwnedDirectory(path, owner)
}
