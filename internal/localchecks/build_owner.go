package localchecks

import (
	"context"
	"errors"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// BuildRoleOwner is constructed only inside the native caller's existing
// protected policy lease/FD8. It routes known local-checks grants by positively
// attesting their protected receipt and immutable worker, not just their prefix.
type BuildRoleOwner struct {
	configuration *hostcapacity.Config
	driver        func(WorkerBinding) NativeDriver
}

func NewBuildRoleOwner(config *hostcapacity.Config) *BuildRoleOwner {
	return &BuildRoleOwner{configuration: config}
}
func (o *BuildRoleOwner) OwnsGrant(g sharedcapacity.Grant) bool {
	return g.Pool == "build" && strings.HasPrefix(g.ID, "local-checks:")
}
func (o *BuildRoleOwner) worker(g sharedcapacity.Grant) (*nativeWorker, NativeReceipt, error) {
	var receipt NativeReceipt
	if o == nil || o.configuration == nil || !o.OwnsGrant(g) {
		return nil, receipt, errors.New("local_checks_role_owner_unavailable")
	}
	id := strings.TrimPrefix(g.ID, "local-checks:")
	w := &nativeWorker{epoch: o.configuration.Epoch, broker: sharedcapacity.Broker{Path: o.configuration.LedgerPath}, policy: o.configuration.Policy, root: filepath.Join(o.configuration.ReceiptRoot, "local-checks")}
	var err error
	receipt, err = w.load(id)
	if err != nil {
		return nil, receipt, err
	}
	if receipt.Fence != g.Fence || g.ID != w.request(receipt.Request).ID || g.Cost.MemoryMiB != receipt.Request.MemoryMiB || g.Cost.VCPUs != receipt.Request.CPUs || receipt.Worker.Validate() != nil {
		return nil, receipt, errors.New("local_checks_role_grant_mismatch")
	}
	if o.driver != nil {
		w.driver = o.driver(receipt.Worker)
	} else {
		w.driver = DockerNativeDriver{Image: receipt.Worker.Image, SourceRoot: receipt.Worker.SourceRoot, DockerRoot: receipt.Worker.DockerRoot}
	}
	return w, receipt, nil
}
func (o *BuildRoleOwner) ValidateGrant(ctx context.Context, g sharedcapacity.Grant) error {
	w, r, err := o.worker(g)
	if err != nil {
		return err
	}
	c, err := w.driver.Inspect(ctx, r.ContainerID)
	if errors.Is(err, ErrNativeContainerMissing) {
		return nil
	}
	if err != nil {
		return err
	}
	if !c.Managed || c.ID != r.ContainerID || c.Role != "local-checks" || c.RequestID != r.Request.RequestID || c.SourceDigest != r.Request.BundleSHA256 || c.CPUs != r.Request.CPUs || c.MemoryMiB != r.Request.MemoryMiB || !c.PrivateCgroup || !c.InnerDocker || c.HostDockerSocket {
		return errors.New("local_checks_role_worker_mismatch")
	}
	return nil
}
func (o *BuildRoleOwner) RetireGrant(ctx context.Context, g sharedcapacity.Grant) error {
	if err := o.ValidateGrant(ctx, g); err != nil {
		return err
	}
	w, r, err := o.worker(g)
	if err != nil {
		return err
	}
	c, err := w.driver.Inspect(ctx, r.ContainerID)
	if err == nil && (c.Running || !c.Stopped) {
		return farmcapacity.ErrQueued
	}
	if err != nil && !errors.Is(err, ErrNativeContainerMissing) {
		return err
	}
	return w.Complete(ctx, r.Request.RequestID)
}

// VerifyReleasedIntents is called only while the existing FD8/policy lease is
// held. Empty broker counts do not retire an uncertain owner intent.
func (o *BuildRoleOwner) VerifyReleasedIntents(ctx context.Context) error {
	root := filepath.Join(o.configuration.ReceiptRoot, "local-checks")
	fd, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	directory := os.NewFile(uintptr(fd), root)
	defer directory.Close()
	info, err := directory.Stat()
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != uint32(os.Geteuid()) || info.Mode().Perm()&0077 != 0 {
		return errors.New("local_checks_private_intent_root_required")
	}
	entries, err := directory.ReadDir(4097)
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	if len(entries) > 4096 {
		return errors.New("local_checks_intent_inventory_bound")
	}
	w := &nativeWorker{epoch: o.configuration.Epoch, root: root}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			return errors.New("local_checks_unknown_owner_intent")
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
		r, err := w.load(id)
		if err != nil {
			return err
		}
		if r.State != "released" || r.Worker.Validate() != nil {
			return errors.New("local_checks_unreleased_owner_intent")
		}
		var driver NativeDriver = DockerNativeDriver{Image: r.Worker.Image, SourceRoot: r.Worker.SourceRoot, DockerRoot: r.Worker.DockerRoot}
		if o.driver != nil {
			driver = o.driver(r.Worker)
		}
		if _, err = driver.Inspect(ctx, r.ContainerID); !errors.Is(err, ErrNativeContainerMissing) {
			return errors.New("local_checks_released_owner_absence_unproved")
		}
	}
	return nil
}
