package localchecks

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

var ErrNativeContainerMissing = errors.New("local_checks_container_absent")
var ErrNativeQueued = errors.New("local_checks_native_queued_with_retained_intent")
var immutableContainerID = regexp.MustCompile(`\A[0-9a-f]{64}\z`)

// NativeContainer is the attested dedicated local-checks role, never a GitHub
// runner. Its driver must inspect immutable Docker identity, labels and actual
// hard resource/network/mount configuration before returning these properties.
type NativeContainer struct {
	ID, Role, RequestID, SourceDigest                                       string
	CPUs                                                                    uint32
	MemoryMiB                                                               uint64
	Managed, PrivateCgroup, InnerDocker, HostDockerSocket, Running, Stopped bool
}
type NativeDriver interface {
	Inspect(context.Context, string) (NativeContainer, error)
	Start(context.Context, string) error
	Remove(context.Context, string) error
}
type NativeReceipt struct {
	Worker          WorkerBinding                    `json:"worker"`
	Version         int                              `json:"version"`
	Epoch           string                           `json:"epoch"`
	Request         Submission                       `json:"request"`
	ContainerID     string                           `json:"containerID"`
	Start           *sharedcapacity.StartReservation `json:"start,omitempty"`
	Fence           string                           `json:"fence,omitempty"`
	State           string                           `json:"state"`
	CreationFailure string                           `json:"creationFailure,omitempty"`
	Qualification   *QualificationProof              `json:"qualification,omitempty"`
	CreationAbsent  bool                             `json:"creationAbsent,omitempty"`
}
type NativeJob interface {
	Cancel(context.Context, string) error
	Qualify(context.Context, Submission) (NativeReceipt, error)
	AdmitStart(context.Context, Submission, string) (NativeReceipt, error)
	CreateAndAdmit(context.Context, Submission) (NativeReceipt, error)
	ExecuteChecks(context.Context, string, string, string, []string) (Result, error)
	Complete(context.Context, string) error
}
type nativeWorker struct {
	epoch  string
	broker sharedcapacity.Broker
	policy sharedcapacity.Policy
	root   string
	driver NativeDriver
}

// WithNativeWorker is the real Farm-owned role entrypoint. It reuses inherited
// fleet FD8, pins the existing policy/epoch, and charges the existing build pool.
// It does not introduce a consumer pool or change any configured budget.
func WithNativeWorker(ctx context.Context, configPath, epoch string, driver NativeDriver, operation func(NativeJob) error) error {
	if driver == nil || operation == nil {
		return errors.New("local_checks_native_driver_required")
	}
	bound, ok := driver.(interface{ Binding() WorkerBinding })
	if !ok || bound.Binding().Validate() != nil {
		return errors.New("local_checks_native_bound_driver_required")
	}
	if err := hostcapacity.VerifyInheritedFleetLock(); err != nil {
		return err
	}
	lease, err := hostcapacity.Acquire(ctx, configPath, false)
	if err != nil {
		return err
	}
	defer lease.Close()
	if lease.Config.Mode != "active" || lease.Config.Epoch != epoch {
		return errors.New("local_checks_native_owner_changed")
	}
	worker := &nativeWorker{epoch: epoch, broker: sharedcapacity.Broker{Path: lease.Config.LedgerPath}, policy: lease.Config.Policy, root: filepath.Join(lease.Config.ReceiptRoot, "local-checks"), driver: driver}
	return operation(worker)
}
func (w *nativeWorker) AdmitStart(ctx context.Context, s Submission, id string) (receipt NativeReceipt, result error) {
	if err := s.Validate(); err != nil {
		return receipt, err
	}
	if !immutableContainerID.MatchString(id) {
		return receipt, errors.New("local_checks_container_identity_invalid")
	}
	container, err := w.driver.Inspect(ctx, id)
	if err != nil {
		return receipt, err
	}
	if err = w.verify(container, s, id); err != nil {
		return receipt, err
	}
	receipt = NativeReceipt{Version: 1, Epoch: w.epoch, Request: s, ContainerID: id, State: "intent"}
	if bound, ok := w.driver.(interface{ Binding() WorkerBinding }); ok {
		receipt.Worker = bound.Binding()
	}
	if previous, err := w.load(s.RequestID); err == nil {
		if previous.Request != s || previous.ContainerID != id || (previous.State != "queued" && previous.State != "created") {
			return previous, errors.New("local_checks_native_recovery_required")
		}
		receipt = previous
	} else if !errors.Is(err, os.ErrNotExist) {
		return receipt, err
	}
	if err = w.save(receipt); err != nil {
		return receipt, err
	}
	decision, err := w.broker.Admit(&w.policy, w.request(s))
	if err != nil {
		receipt.State = "uncertain"
		_ = w.save(receipt)
		return receipt, err
	}
	if !decision.Admitted {
		receipt.State = "queued"
		err = w.save(receipt)
		if err != nil {
			return receipt, err
		}
		return receipt, ErrNativeQueued
	}
	if decision.Grant == nil {
		return receipt, errors.New("local_checks_native_grant_missing")
	}
	receipt.Fence = decision.Grant.Fence
	if w.policy.SharedMemoryHeadroom {
		start, err := w.broker.ReserveStart(&w.policy, w.request(s).ID, receipt.Fence)
		if err != nil {
			receipt.State = "queued"
			if saveErr := w.save(receipt); saveErr != nil {
				return receipt, errors.Join(err, saveErr)
			}
			if errors.Is(err, sharedcapacity.ErrMemoryHeadroom) {
				return receipt, ErrNativeQueued
			}
			return receipt, err
		}
		receipt.Start = &start
	}
	receipt.State = "starting"
	if err = w.save(receipt); err != nil {
		return receipt, err
	}
	if err = w.driver.Start(ctx, id); err != nil {
		receipt.State = "uncertain"
		_ = w.save(receipt)
		return receipt, errors.New("local_checks_native_start_uncertain")
	}
	observed, err := w.driver.Inspect(ctx, id)
	if err != nil || !observed.Running || observed.ID != id {
		receipt.State = "uncertain"
		_ = w.save(receipt)
		return receipt, errors.New("local_checks_native_start_uncertain")
	}
	receipt.State = "running"
	if err := w.save(receipt); err != nil {
		return receipt, err
	}
	if w.policy.SharedMemoryHeadroom {
		err := w.broker.ConfirmStarted(&w.policy, w.request(s).ID, *receipt.Start, func(grant sharedcapacity.Grant) error {
			saved, err := w.load(s.RequestID)
			if err != nil {
				return err
			}
			if saved.State != "running" || saved.Fence != grant.Fence || saved.ContainerID != id || saved.Request != s || saved.Start == nil || *saved.Start != *receipt.Start {
				return errors.New("local_checks_native_start_receipt_mismatch")
			}
			current, err := w.driver.Inspect(ctx, id)
			if err != nil {
				return err
			}
			if !current.Running || current.Stopped || !w.matches(current, s, id) {
				return errors.New("local_checks_native_start_owner_mismatch")
			}
			return ctx.Err()
		})
		if err != nil {
			receipt.State = "uncertain"
			return receipt, errors.Join(err, w.save(receipt))
		}
	}
	return receipt, nil
}
func (w *nativeWorker) request(s Submission) sharedcapacity.Request {
	return sharedcapacity.Request{ID: "local-checks:" + s.RequestID, Pool: "build", Resources: sharedcapacity.Resources{MemoryMiB: s.MemoryMiB, VCPUs: s.CPUs}}
}
func (w *nativeWorker) verify(c NativeContainer, s Submission, id string) error {
	if !w.matches(c, s, id) || c.Running || !c.Stopped {
		return errors.New("local_checks_native_container_not_admissible")
	}
	return nil
}
func (w *nativeWorker) matches(c NativeContainer, s Submission, id string) bool {
	return c.Managed && c.ID == id && c.Role == "local-checks" && c.RequestID == s.RequestID && c.SourceDigest == s.BundleSHA256 && c.CPUs == s.CPUs && c.MemoryMiB == s.MemoryMiB && c.PrivateCgroup && c.InnerDocker && !c.HostDockerSocket
}
func (w *nativeWorker) Complete(ctx context.Context, requestID string) error {
	r, err := w.load(requestID)
	if err != nil {
		return err
	}
	if r.State == "released" {
		return nil
	}
	if r.State == "creating" {
		return errors.New("local_checks_native_creation_recovery_required")
	}
	wasReleasing := r.State == "releasing"
	snapshot, err := w.broker.Status(&w.policy)
	if err != nil {
		return err
	}
	if r.Fence != "" {
		if grant, present := snapshot.Grants[w.request(r.Request).ID]; !present && !wasReleasing {
			return errors.New("local_checks_native_grant_disappeared")
		} else if present && grant.Fence != r.Fence {
			return sharedcapacity.ErrFenceMismatch
		}
	}
	observed, err := w.driver.Inspect(ctx, r.ContainerID)
	if err != nil && !errors.Is(err, ErrNativeContainerMissing) {
		return err
	}
	if err == nil && (observed.ID != r.ContainerID || observed.Running || !observed.Stopped) {
		return errors.New("local_checks_native_worker_not_stopped")
	}
	r.State = "releasing"
	if err = w.save(r); err != nil {
		return err
	}
	if err == nil && observed.ID != "" {
		if err = w.driver.Remove(ctx, r.ContainerID); err != nil {
			return err
		}
	}
	prove := func(sharedcapacity.Grant) error {
		_, err := w.driver.Inspect(ctx, r.ContainerID)
		if !errors.Is(err, ErrNativeContainerMissing) {
			return errors.New("local_checks_native_absence_unproven")
		}
		return nil
	}
	if r.Fence == "" {
		if _, ok := snapshot.Grants[w.request(r.Request).ID]; ok {
			return errors.New("local_checks_native_grant_recovery_required")
		}
		if err = w.broker.Cancel(&w.policy, w.request(r.Request)); err != nil {
			return err
		}
	} else if grant, ok := snapshot.Grants[w.request(r.Request).ID]; ok {
		if grant.Fence != r.Fence {
			return sharedcapacity.ErrFenceMismatch
		}
		if err = w.broker.Release(&w.policy, grant.ID, r.Fence, prove); err != nil {
			return err
		}
	} else {
		if !wasReleasing {
			return errors.New("local_checks_native_grant_disappeared")
		}
		if err = prove(sharedcapacity.Grant{}); err != nil {
			return err
		}
	}
	r.State = "released"
	return w.save(r)
}
func (w *nativeWorker) load(id string) (NativeReceipt, error) {
	var result NativeReceipt
	if !identifier.MatchString(id) {
		return result, errors.New("local_checks_request_invalid")
	}
	path := filepath.Join(w.root, id+".json")
	info, err := os.Lstat(path)
	if err != nil {
		return result, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 16384 {
		return result, errors.New("local_checks_native_receipt_invalid")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return result, err
	}
	if err = json.Unmarshal(data, &result); err != nil || result.Version != 1 || result.Epoch != w.epoch || result.Request.Validate() != nil || result.Request.RequestID != id || (!immutableContainerID.MatchString(result.ContainerID) && !((result.State == "creating" || result.State == "released" && result.CreationAbsent) && result.ContainerID == "")) {
		return result, errors.New("local_checks_native_receipt_invalid")
	}
	if result.CreationAbsent && (result.State != "released" || result.ContainerID != "" || result.Fence != "") {
		return result, errors.New("local_checks_native_receipt_invalid")
	}
	switch result.State {
	case "creating", "created", "intent", "queued", "starting", "running", "uncertain", "releasing", "released":
	default:
		return result, errors.New("local_checks_native_receipt_invalid")
	}
	return result, nil
}
func (w *nativeWorker) save(r NativeReceipt) error {
	if err := os.MkdirAll(w.root, 0700); err != nil {
		return err
	}
	canonical, err := filepath.EvalSymlinks(w.root)
	if err != nil || canonical != w.root {
		return errors.New("local_checks_native_receipt_root_invalid")
	}
	info, err := os.Stat(w.root)
	if err != nil || info.Mode().Perm()&0077 != 0 {
		return errors.New("local_checks_native_receipt_root_invalid")
	}
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	pending, err := os.CreateTemp(w.root, ".receipt-*.pending")
	if err != nil {
		return err
	}
	name := pending.Name()
	defer os.Remove(name)
	if _, err = pending.Write(data); err == nil {
		err = pending.Sync()
	}
	err = errors.Join(err, pending.Close())
	if err == nil {
		err = os.Rename(name, filepath.Join(w.root, r.Request.RequestID+".json"))
	}
	if err != nil {
		return err
	}
	directory, err := os.Open(w.root)
	if err != nil {
		return err
	}
	return errors.Join(directory.Sync(), directory.Close())
}

// CreateAndAdmit journals before the only Docker creation attempt. Even an
// uncertain inert creation retains durable evidence and cannot be replayed.
func (w *nativeWorker) CreateAndAdmit(ctx context.Context, s Submission) (NativeReceipt, error) {
	var r NativeReceipt
	if err := s.Validate(); err != nil {
		return r, err
	}
	creator, ok := w.driver.(interface {
		Create(context.Context, Submission) (string, error)
		Binding() WorkerBinding
	})
	if !ok || creator.Binding().Validate() != nil {
		return r, errors.New("local_checks_native_creator_required")
	}
	if prior, err := w.load(s.RequestID); err == nil {
		return prior, errors.New("local_checks_native_recovery_required")
	} else if !errors.Is(err, os.ErrNotExist) {
		return r, err
	}
	r = NativeReceipt{Version: 1, Epoch: w.epoch, Request: s, Worker: creator.Binding(), State: "creating"}
	if err := w.save(r); err != nil {
		return r, err
	}
	id, err := creator.Create(ctx, s)
	if err != nil {
		var failure dockerOperationFailure
		if errors.As(err, &failure) {
			r.CreationFailure = failure.code
		} else {
			r.CreationFailure = "operation_failed"
		}
		return r, errors.Join(err, w.save(r))
	}
	if !immutableContainerID.MatchString(id) {
		return r, ErrNativeCreateUncertain
	}
	r.ContainerID = id
	r.State = "created"
	if err = w.save(r); err != nil {
		return r, err
	}
	return w.AdmitStart(ctx, s, id)
}

// Cancel is the closed owner recovery path after a terminal qualification or
// execution attempt. It never enables new checks or creates another identity.
func (w *nativeWorker) Cancel(ctx context.Context, requestID string) error {
	r, err := w.load(requestID)
	if err != nil {
		return err
	}
	if r.State == "released" {
		return nil
	}
	if r.State == "creating" {
		return w.recoverAbsentCreation(ctx, r)
	}
	stopper, ok := w.driver.(interface {
		Stop(context.Context, string) error
	})
	if !ok {
		return errors.New("local_checks_native_stop_required")
	}
	bounded, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	_, err = w.driver.Inspect(bounded, r.ContainerID)
	if err != nil && !errors.Is(err, ErrNativeContainerMissing) {
		return err
	}
	if err == nil {
		if err = stopper.Stop(bounded, r.ContainerID); err != nil {
			return err
		}
	}
	return w.Complete(bounded, requestID)
}

// recoverAbsentCreation settles only an original creation with no Docker object
// and no capacity effect. It never adopts, removes, starts or recreates a worker.
// The protected entrypoint holds both fleet and policy locks throughout.
func (w *nativeWorker) recoverAbsentCreation(ctx context.Context, r NativeReceipt) error {
	driver, ok := w.driver.(interface {
		Binding() WorkerBinding
		ProveCreationAbsent(context.Context, Submission) error
	})
	if !ok || r.ContainerID != "" || r.Fence != "" || driver.Binding() != r.Worker {
		return errors.New("local_checks_native_creation_recovery_required")
	}
	snapshot, err := w.broker.Status(&w.policy)
	if err != nil {
		return err
	}
	id := w.request(r.Request).ID
	if _, present := snapshot.Grants[id]; present {
		return errors.New("local_checks_native_creation_capacity_present")
	}
	if _, present := snapshot.Pending[id]; present {
		return errors.New("local_checks_native_creation_capacity_present")
	}
	if err = driver.ProveCreationAbsent(ctx, r.Request); err != nil {
		return err
	}
	r.State = "released"
	r.CreationAbsent = true
	return w.save(r)
}
