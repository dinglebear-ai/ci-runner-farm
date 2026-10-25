package localchecks

import (
	"context"
	"errors"
	"path/filepath"
	"strings"

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
