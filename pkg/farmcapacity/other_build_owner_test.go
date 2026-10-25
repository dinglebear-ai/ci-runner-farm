package farmcapacity

import (
	"context"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"path/filepath"
	"testing"
)

type otherBuildFixture struct {
	validated, retired int
	refuse             bool
}

func (o *otherBuildFixture) OwnsGrant(g sharedcapacity.Grant) bool {
	return g.ID == "local-checks:fixture"
}
func (o *otherBuildFixture) ValidateGrant(context.Context, sharedcapacity.Grant) error {
	o.validated++
	if o.refuse {
		return errors.New("unattested owner")
	}
	return nil
}
func (o *otherBuildFixture) RetireGrant(context.Context, sharedcapacity.Grant) error {
	o.retired++
	return nil
}
func TestOtherBuildOwnerIsAttestedBeforeReconciliationOrRetirement(t *testing.T) {
	policy := sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 32768, VCPUs: 8}, AgingSeconds: 60, Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 8192, VCPUs: 2}, Maximum: 1}}}
	b := sharedcapacity.Broker{Path: filepath.Join(t.TempDir(), "ledger")}
	if err := b.Initialize(&policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Admit(&policy, sharedcapacity.Request{ID: "local-checks:fixture", Pool: "build"}); err != nil {
		t.Fatal(err)
	}
	o := &otherBuildFixture{}
	c := &Controller{Broker: b, Policy: policy, ReceiptRoot: filepath.Join(t.TempDir(), "receipts"), OtherBuildOwner: o}
	if err := c.configurationReconciliationAvailable(context.Background(), "unrelated"); !errors.Is(err, ErrQueued) || o.validated != 1 {
		t.Fatal(err, o)
	}
	if err := c.Retire(context.Background(), func(context.Context, string, string, int64, string) (OwnerBinding, error) {
		return OwnerBinding{}, errors.New("GitHub path must not run")
	}); err != nil || o.retired != 1 {
		t.Fatal(err, o)
	}
	o.refuse = true
	if err := c.Retire(context.Background(), func(context.Context, string, string, int64, string) (OwnerBinding, error) { return OwnerBinding{}, nil }); err == nil || o.retired != 1 {
		t.Fatal("unattested owner was delegated", err)
	}
}
