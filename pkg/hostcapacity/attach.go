// Package hostcapacity keeps QA attachment inside Farm's original owner.
package hostcapacity

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"slices"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// QAAttachment is one reviewed transition from an empty standalone Farm owner.
// Previous binds every owner identity; final publication remains closed for QA adoption.
type QAAttachment struct {
	Schema              string                `json:"schema"`
	ExpectedOwnerDigest string                `json:"expectedOwnerDigest"`
	Previous            Config                `json:"previous"`
	RevisedPolicy       sharedcapacity.Policy `json:"revisedPolicy"`
	Consumers           map[string]Consumer   `json:"consumers"`
}

// Validate permits only the existing build owner plus one explicit QA consumer.
func (a *QAAttachment) Validate() error {
	if a == nil || a.Schema != "farm-qa-attachment/v1" || a.Previous.QAAttachment != nil || a.Previous.PoolExpansion != nil || a.Previous.Mode != "active" || len(a.Previous.Consumers) != 0 || len(a.Previous.Policy.Pools) != 1 {
		return errors.New("QA attachment requires the original standalone owner")
	}
	if err := a.Previous.Validate(a.Previous.Host); err != nil {
		return err
	}
	data, err := json.Marshal(a.Previous)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	if a.ExpectedOwnerDigest != hex.EncodeToString(sum[:]) {
		return errors.New("QA attachment original owner digest differs")
	}
	if err := a.RevisedPolicy.Validate(); err != nil {
		return err
	}
	unchanged := a.RevisedPolicy
	unchanged.Budget = a.Previous.Policy.Budget
	unchanged.Pools = a.Previous.Policy.Pools
	if !reflect.DeepEqual(unchanged, a.Previous.Policy) || a.RevisedPolicy.SoftCPU() {
		return errors.New("QA attachment cannot change the original admission protocol")
	}
	oldBuild := a.Previous.Policy.Pools["build"]
	build := a.RevisedPolicy.Pools["build"]
	normalized := build
	normalized.Minimum, normalized.Maximum = oldBuild.Minimum, oldBuild.Maximum
	if !reflect.DeepEqual(normalized, oldBuild) || build.Minimum == 0 || build.Minimum < oldBuild.Minimum || build.Maximum < oldBuild.Maximum || build.Maximum > 8 {
		return errors.New("QA attachment changed original build settings or removed its floor")
	}
	qa, ok := a.Consumers["qa"]
	expected := []string{"qa-runner", "qa-guest"}
	if _, present := a.RevisedPolicy.Pools["qa-service"]; present {
		expected = append(expected, "qa-service")
	}
	if !ok || len(a.Consumers) != 1 || !slices.Equal(qa.Pools, expected) || len(a.RevisedPolicy.Pools) != len(expected)+1 || qa.OverheadMiB != 1024 {
		return errors.New("QA attachment requires exactly its declared QA classes and overhead")
	}
	runner, rok := a.RevisedPolicy.Pools["qa-runner"]
	guest, gok := a.RevisedPolicy.Pools["qa-guest"]
	if !rok || !gok || runner.Minimum == 0 || runner.Maximum > guest.Maximum || guest.Maximum < 2 || guest.Minimum != 0 || guest.Cost.MemoryMiB <= qa.OverheadMiB || runner.Priority <= build.Priority || guest.Priority <= runner.Priority {
		return errors.New("QA attachment classes or positive CI floors are invalid")
	}
	if len(runner.MinimumRequestIDs) != 0 || len(guest.MinimumRequestIDs) != 0 || runner.MaxCost != (sharedcapacity.Resources{}) || guest.MaxCost != (sharedcapacity.Resources{}) {
		return errors.New("QA attachment consumer envelopes must remain fixed")
	}
	if service, present := a.RevisedPolicy.Pools["qa-service"]; present {
		if service.Cost != (sharedcapacity.Resources{MemoryMiB: 256, VCPUs: 1}) || service.MaxCost != (sharedcapacity.Resources{}) || service.Minimum != 0 || service.Maximum != 1 || service.Priority != guest.Priority || len(service.MinimumRequestIDs) != 0 {
			return errors.New("QA service requires its bounded unguaranteed class")
		}
	}
	pending := a.pendingOwner()
	for _, candidate := range []Config{pending, a.destination()} {
		data, err := json.Marshal(candidate)
		if err != nil {
			return err
		}
		// publishConfig's JSON encoder also writes a trailing newline.
		if len(data)+1 > 64*1024 {
			return errors.New("QA attachment publication exceeds the protected owner file bound")
		}
	}
	return nil
}

func (a *QAAttachment) pendingOwner() Config {
	closed := a.Previous
	closed.Mode = "closed"
	closed.QAAttachment = a
	return closed
}

func (a QAAttachment) destination() Config {
	next := a.Previous
	next.Mode = "closed"
	next.Policy = a.RevisedPolicy
	next.Consumers = a.Consumers
	next.QAAttachment = nil
	return next
}

func (a *QAAttachment) validatePending(current *Config) error {
	if err := a.Validate(); err != nil {
		return err
	}
	expected := a.pendingOwner()
	if !reflect.DeepEqual(*current, expected) {
		return errors.New("QA attachment pending owner changed")
	}
	return nil
}

// AttachQA retains the original ledger under its exclusive owner lease. The
// native caller retains fleet/operation ownership and repeats real empty-native
// inventory and both durable closure checks through attest. No QA effects occur
// here: the final owner stays closed until QA's complete adoption and acceptance.
func (l *Lease) AttachQA(request QAAttachment, physical sharedcapacity.Resources, attest func() error) error {
	data, err := json.Marshal(request)
	if err != nil {
		return err
	}
	var normalized QAAttachment
	if err := json.Unmarshal(data, &normalized); err != nil {
		return err
	}
	request = normalized
	if err := request.Validate(); err != nil {
		return err
	}
	if physical.MemoryMiB <= 16384 || physical.VCPUs <= 4 || request.RevisedPolicy.Budget.MemoryMiB > physical.MemoryMiB-16384 || request.RevisedPolicy.Budget.VCPUs > physical.VCPUs-4 {
		return errors.New("QA attachment exceeds physical resources after 16 GiB and four CPU reserves")
	}
	if attest == nil {
		return errors.New("QA attachment requires native owner attestation")
	}
	if err := l.checkExpansionPublication(); err != nil {
		return err
	}
	destination := request.destination()
	broker := sharedcapacity.Broker{Path: l.Config.LedgerPath}
	check := func() error {
		if err := l.checkExpansionPublication(); err != nil {
			return err
		}
		if err := attest(); err != nil {
			return err
		}
		if err := l.checkExpansionPublication(); err != nil {
			return err
		}
		return emptyAttachmentLedger(&broker, &request)
	}
	if reflect.DeepEqual(*l.Config, destination) {
		return check()
	}
	if l.Config.QAAttachment != nil {
		if !reflect.DeepEqual(*l.Config.QAAttachment, request) {
			return errors.New("another QA attachment owns recovery")
		}
	} else {
		if !reflect.DeepEqual(*l.Config, request.Previous) {
			return errors.New("QA attachment original owner CAS changed")
		}
		if err := check(); err != nil {
			return err
		}
		if err := broker.CheckPolicyChange(&request.Previous.Policy, &request.RevisedPolicy); err != nil {
			return err
		}
		closed := request.pendingOwner()
		if err := publishConfig(l.path, &closed); err != nil {
			return err
		}
		l.Config = &closed
	}
	if err := check(); err != nil {
		return err
	}
	if err := broker.ReconcilePolicy(&request.Previous.Policy, &request.RevisedPolicy); err != nil {
		return err
	}
	if err := check(); err != nil {
		return err
	}
	if err := publishConfig(l.path, &destination); err != nil {
		return err
	}
	l.Config = &destination
	return check()
}

func emptyAttachmentLedger(broker *sharedcapacity.Broker, request *QAAttachment) error {
	snapshot, err := broker.Status(&request.Previous.Policy)
	if errors.Is(err, sharedcapacity.ErrPolicyChanged) {
		snapshot, err = broker.Status(&request.RevisedPolicy)
	}
	if err != nil {
		return err
	}
	if len(snapshot.Grants) != 0 || len(snapshot.Pending) != 0 {
		return errors.New("QA attachment requires no native grants or pending demand")
	}
	return nil
}
