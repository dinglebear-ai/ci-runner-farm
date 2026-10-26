package localchecks

import (
	"context"
	"errors"
	"os"
	"testing"
)

type creatingFixture struct {
	*nativeFixtureDriver
	worker *nativeWorker
	calls  int
	fail   bool
}

func (d *creatingFixture) Create(_ context.Context, s Submission) (string, error) {
	d.calls++
	r, err := d.worker.load(s.RequestID)
	if err != nil || r.State != "creating" || r.ContainerID != "" {
		return "", errors.New("durable creation intent missing")
	}
	if d.fail {
		return "", ErrNativeCreateUncertain
	}
	return d.container.ID, nil
}
func TestNativeCreationJournalsBeforeEffectAndRefusesUncertainReplay(t *testing.T) {
	for _, fail := range []bool{false, true} {
		t.Run(map[bool]string{false: "success", true: "uncertain"}[fail], func(t *testing.T) {
			w, d, s := nativeFixture(t)
			creator := &creatingFixture{nativeFixtureDriver: d, worker: w, fail: fail}
			w.driver = creator
			r, err := w.CreateAndAdmit(context.Background(), s)
			if fail {
				if !errors.Is(err, ErrNativeCreateUncertain) || r.State != "creating" || r.CreationFailure != "operation_failed" {
					t.Fatal(r, err)
				}
			} else if err != nil || r.State != "running" {
				t.Fatal(r, err)
			}
			if _, err = w.CreateAndAdmit(context.Background(), s); err == nil || creator.calls != 1 {
				t.Fatal("creation replayed", err)
			}
			if fail {
				if err = w.Complete(context.Background(), s.RequestID); err == nil {
					t.Fatal("uncertain creation discarded")
				}
				if _, err = os.Stat(w.root + "/" + s.RequestID + ".json"); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
