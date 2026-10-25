package localchecks

import (
	"context"
	"errors"
	"math"
	"slices"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// ChargedSandbox is the existing worker sandbox's lifecycle and resource owner.
// GrantIdentity resolves its protected receipt while its execution lease is held.
// It must verify kernel-enforced aggregate limits and exclusive source custody;
// a returned broker fence alone is never sufficient for execution.
type ChargedSandbox interface {
	ExecutionOwner
	GrantIdentity(context.Context, Reservation) (id, fence string, err error)
}

// FarmExecutionOwner pins Farm's existing declared consumer/epoch for the whole
// workload, and checks the sandbox's existing charge in that same authoritative
// ledger. It never creates a policy, initializes a ledger, admits new capacity,
// copies budgets into consumer settings, or independently releases a grant.
// The sandbox keeps its original terminal/stopped proof and release protocol.
type FarmExecutionOwner struct {
	Binding      hostcapacity.Binding
	Pool         string
	Worker       ChargedSandbox
	withConsumer func(context.Context, hostcapacity.Binding, func(context.Context, hostcapacity.View) error) error
}

func (o FarmExecutionOwner) WithExecution(ctx context.Context, r Reservation, fn func(context.Context, OwnerVerifier, []string) error) error {
	if err := o.Binding.Validate(); err != nil {
		return errors.New("local_checks_farm_binding_invalid")
	}
	if o.Worker == nil || fn == nil || !identifier.MatchString(o.Pool) {
		return errors.New("local_checks_farm_worker_unavailable")
	}
	lease := o.withConsumer
	if lease == nil {
		lease = hostcapacity.WithConsumer
	}
	return lease(ctx, o.Binding, func(pinned context.Context, view hostcapacity.View) error {
		if view.Epoch != o.Binding.Epoch || !slices.Contains(view.Pools, o.Pool) {
			return errors.New("local_checks_farm_consumer_not_authorized")
		}
		return o.Worker.WithExecution(pinned, r, func(held context.Context, kernelProof OwnerVerifier, environment []string) error {
			if kernelProof == nil {
				return errors.New("local_checks_worker_proof_required")
			}
			id, fence, err := o.Worker.GrantIdentity(held, r)
			if err != nil || id != r.RequestID || fence == "" {
				return errors.New("local_checks_farm_grant_unavailable")
			}
			proof := farmGrantProof{worker: kernelProof, view: view, pool: o.Pool, id: id, fence: fence}
			if err := proof.Verify(held, r); err != nil {
				return err
			}
			return fn(held, proof, environment)
		})
	})
}

type farmGrantProof struct {
	worker          OwnerVerifier
	view            hostcapacity.View
	pool, id, fence string
}

func (p farmGrantProof) Verify(ctx context.Context, r Reservation) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := p.worker.Verify(ctx, r); err != nil {
		return errors.New("local_checks_sandbox_verification_failed")
	}
	if r.MemoryMiB > math.MaxUint64-p.view.OverheadMiB {
		return errors.New("local_checks_farm_grant_mismatch")
	}
	broker := sharedcapacity.Broker{Path: p.view.LedgerPath}
	snapshot, err := broker.Status(&p.view.Policy)
	if err != nil {
		return errors.New("local_checks_farm_ledger_unavailable")
	}
	grant, ok := snapshot.Grants[p.id]
	if !ok || grant.Fence != p.fence || grant.Pool != p.pool || grant.Cost.VCPUs != r.CPUs || grant.Cost.MemoryMiB != r.MemoryMiB+p.view.OverheadMiB {
		return errors.New("local_checks_farm_grant_mismatch")
	}
	return ctx.Err()
}
