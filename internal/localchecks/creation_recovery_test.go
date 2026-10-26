package localchecks

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type creationRecoveryDriver struct {
	*nativeFixtureDriver
	absentErr    error
	observations int
}

func (d *creationRecoveryDriver) ProveCreationAbsent(context.Context, Submission) error {
	d.observations++
	return d.absentErr
}
func TestCreationRecoveryOnlySettlesProvenAbsentUnchargedOriginal(t *testing.T) {
	for _, mode := range []string{"absent", "present-or-unavailable", "grant", "pending", "wrong-binding"} {
		t.Run(mode, func(t *testing.T) {
			w, d, s := nativeFixture(t)
			recovery := &creationRecoveryDriver{nativeFixtureDriver: d}
			w.driver = recovery
			r := NativeReceipt{Version: 1, Epoch: w.epoch, Request: s, Worker: d.Binding(), State: "creating"}
			if mode == "wrong-binding" {
				r.Worker.Image = "sha256:" + strings.Repeat("a", 64)
			}
			if err := w.save(r); err != nil {
				t.Fatal(err)
			}
			if mode == "present-or-unavailable" {
				recovery.absentErr = errors.New("no absence proof")
			}
			if mode == "grant" {
				if _, err := w.broker.Admit(&w.policy, w.request(s)); err != nil {
					t.Fatal(err)
				}
			}
			if mode == "pending" {
				if _, err := w.broker.Admit(&w.policy, sharedcapacity.Request{ID: "foreign", Pool: "build"}); err != nil {
					t.Fatal(err)
				}
				if _, err := w.broker.Admit(&w.policy, w.request(s)); err != nil {
					t.Fatal(err)
				}
			}
			err := w.Cancel(context.Background(), s.RequestID)
			got, loadErr := w.load(s.RequestID)
			if loadErr != nil {
				t.Fatal(loadErr)
			}
			if mode == "absent" {
				if err != nil || got.State != "released" {
					t.Fatal(got, err)
				}
				if err = w.Cancel(context.Background(), s.RequestID); err != nil || recovery.observations != 1 {
					t.Fatal("recovery replayed", err)
				}
				if _, err = w.CreateAndAdmit(context.Background(), s); err == nil {
					t.Fatal("original recreated")
				}
			} else if err == nil || got.State != "creating" {
				t.Fatal("uncertain creation discarded", got, err)
			}
			if d.starts != 0 || d.removes != 0 {
				t.Fatal("recovery mutated Docker")
			}
		})
	}
}
func TestDockerCreationAbsenceProofRequiresSameLiveDaemonAndExactName(t *testing.T) {
	for _, mode := range []string{"absent", "present", "list-error", "daemon-error", "changed-daemon", "invalid-daemon"} {
		t.Run(mode, func(t *testing.T) {
			d := DockerNativeDriver{Image: "sha256:" + strings.Repeat("e", 64), SourceRoot: "/source", DockerRoot: "/docker"}
			infoCalls := 0
			d.run = func(_ context.Context, args ...string) ([]byte, error) {
				if args[0] == "info" {
					infoCalls++
					if mode == "daemon-error" {
						return nil, errors.New("offline")
					}
					if mode == "invalid-daemon" {
						return []byte(""), nil
					}
					if mode == "changed-daemon" && infoCalls > 1 {
						return []byte("other-daemon"), nil
					}
					return []byte("daemon-id"), nil
				}
				if strings.Join(args, " ") != "container ls --all --quiet --no-trunc --filter name=^/farm-local-checks-"+submission().RequestID+"$" {
					t.Fatal(args)
				}
				if mode == "list-error" {
					return nil, errors.New("denied")
				}
				if mode == "present" {
					return []byte(strings.Repeat("d", 64)), nil
				}
				return nil, nil
			}
			err := d.ProveCreationAbsent(context.Background(), submission())
			if (err == nil) != (mode == "absent") {
				t.Fatal(mode, err)
			}
		})
	}
}
