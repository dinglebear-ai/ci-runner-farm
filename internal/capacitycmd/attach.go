// Package capacitycmd keeps empty-owner attachment on the original Farm CLI.
package capacitycmd

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"golang.org/x/sys/unix"
)

func attachQA(ctx context.Context, lease *hostcapacity.Lease, epoch, path string, controller *farmcapacity.Controller) error {
	request, err := readQAAttachment(path, 0)
	if err != nil {
		return err
	}
	if epoch != lease.Config.Epoch || epoch != request.Previous.Epoch {
		return errors.New("QA attachment ownership epoch changed")
	}
	closures, err := openAttachmentClosures([]string{filepath.Join(filepath.Dir(hostcapacity.ConfigPath), "shared-capacity.closed"), "/boot/config/plugins/qa-vm-service/admission.closed"}, 0)
	if err != nil {
		return err
	}
	defer func() {
		for _, c := range closures {
			c.file.Close()
		}
	}()
	physical, err := attachmentPhysicalResources()
	if err != nil {
		return err
	}
	attest := func() error {
		for _, closure := range closures {
			if err := closure.verify(); err != nil {
				return err
			}
		}
		current, err := attachmentPhysicalResources()
		if err != nil {
			return err
		}
		if current != physical {
			return errors.New("physical resources changed during attachment")
		}
		return verifyAttachmentInventory(ctx, controller)
	}
	return lease.AttachQA(request, physical, attest)
}

func readQAAttachment(path string, owner uint32) (hostcapacity.QAAttachment, error) {
	var request hostcapacity.QAAttachment
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return request, errors.New("QA attachment request must have a canonical absolute path")
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return request, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return request, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != owner || stat.Nlink != 1 || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() > 64*1024 {
		return request, errors.New("QA attachment request must be a bounded private original owner file")
	}
	decoder := json.NewDecoder(io.LimitReader(file, 64*1024+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return request, err
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		return request, errors.New("QA attachment request has trailing data")
	}
	return request, request.Validate()
}

type attachmentClosure struct {
	path   string
	file   *os.File
	digest [32]byte
	owner  uint32
}

func openAttachmentClosures(paths []string, owner uint32) (result []attachmentClosure, err error) {
	defer func() {
		if err != nil {
			for _, c := range result {
				c.file.Close()
			}
		}
	}()
	for _, path := range paths {
		fd, openErr := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
		if openErr != nil {
			return result, openErr
		}
		c := attachmentClosure{path: path, file: os.NewFile(uintptr(fd), path), owner: owner}
		result = append(result, c)
		digest, readErr := c.readDigest()
		if readErr != nil {
			return result, readErr
		}
		result[len(result)-1].digest = digest
	}
	return result, nil
}

func (c attachmentClosure) readDigest() ([32]byte, error) {
	var empty [32]byte
	info, err := c.file.Stat()
	if err != nil {
		return empty, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	target, err := os.Lstat(c.path)
	if err != nil || !ok || stat.Uid != c.owner || stat.Nlink != 1 || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() > 64*1024 || !target.Mode().IsRegular() || !os.SameFile(info, target) {
		return empty, errors.New("both original private admission closures must remain present")
	}
	if _, err := c.file.Seek(0, io.SeekStart); err != nil {
		return empty, err
	}
	data, err := io.ReadAll(io.LimitReader(c.file, 64*1024+1))
	if err != nil {
		return empty, err
	}
	if len(data) > 64*1024 {
		return empty, errors.New("admission closure exceeds its bound")
	}
	return sha256.Sum256(data), nil
}
func (c attachmentClosure) verify() error {
	digest, err := c.readDigest()
	if err != nil {
		return err
	}
	if digest != c.digest {
		return errors.New("original admission closure changed during attachment")
	}
	return nil
}

func attachmentPhysicalResources() (sharedcapacity.Resources, error) {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return sharedcapacity.Resources{}, err
	}
	return parseAttachmentPhysicalResources(string(data), runtime.NumCPU())
}
func parseAttachmentPhysicalResources(meminfo string, cpus int) (sharedcapacity.Resources, error) {
	var memory uint64
	for _, line := range strings.Split(meminfo, "\n") {
		if strings.HasPrefix(line, "MemTotal:") {
			if _, err := fmt.Sscanf(line, "MemTotal: %d kB", &memory); err != nil {
				return sharedcapacity.Resources{}, err
			}
			break
		}
	}
	if memory == 0 || cpus <= 0 || uint64(cpus) > uint64(^uint32(0)) {
		return sharedcapacity.Resources{}, errors.New("physical host resources are unavailable")
	}
	return sharedcapacity.Resources{MemoryMiB: memory / 1024, VCPUs: uint32(cpus)}, nil
}

func verifyAttachmentInventory(ctx context.Context, controller *farmcapacity.Controller) error {
	native, err := controller.Inventory(ctx)
	if err != nil {
		return err
	}
	if len(native) != 0 {
		return errors.New("QA attachment requires an empty native Farm inventory")
	}
	sidecars, err := exec.CommandContext(ctx, "docker", "ps", "-a", "--no-trunc", "--filter", "label=net.unraid.ci-runner-farm.sidecar=true", "--format", "{{.ID}}").Output()
	if err != nil || strings.TrimSpace(string(sidecars)) != "" {
		return errors.New("QA attachment native sidecar inventory is occupied or unavailable")
	}
	return nil
}
