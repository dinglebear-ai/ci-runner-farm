package localchecks

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"testing"
	"time"
)

func submission() Submission {
	return Submission{Version: 1, Repository: "unraid/core", Commit: strings.Repeat("a", 40), Base: strings.Repeat("b", 40), BundleSHA256: strings.Repeat("c", 64), RequestID: "local-checks-001", CPUs: 2, MemoryMiB: 8192, TimeoutSeconds: 3600, ScratchMiB: 20480}
}

func TestSubmissionClosedContract(t *testing.T) {
	if err := submission().Validate(); err != nil {
		t.Fatal(err)
	}
	for name, edit := range map[string]func(*Submission){
		"other repo":              func(s *Submission) { s.Repository = "other/core" },
		"moving ref":              func(s *Submission) { s.Commit = "main" },
		"missing base":            func(s *Submission) { s.Base = "" },
		"missing bundle identity": func(s *Submission) { s.BundleSHA256 = "" },
		"control in request":      func(s *Submission) { s.RequestID += "\n" },
		"zero memory":             func(s *Submission) { s.MemoryMiB = 0 },
		"zero CPU":                func(s *Submission) { s.CPUs = 0 },
		"unbounded time":          func(s *Submission) { s.TimeoutSeconds = 0 },
		"unknown schema":          func(s *Submission) { s.Version = 2 },
	} {
		t.Run(name, func(t *testing.T) {
			s := submission()
			edit(&s)
			if s.Validate() == nil {
				t.Fatal("accepted invalid submission")
			}
		})
	}
	for _, data := range []string{`{"command":"rm -rf /"}`, `{"token":"secret"}`} {
		if _, err := DecodeSubmission(strings.NewReader(data)); err == nil {
			t.Fatal("accepted open-ended submission")
		}
	}
}

type reservations struct {
	calls   []string
	failure error
}

func (r *reservations) Reserve(_ context.Context, host string, s Submission) (Reservation, error) {
	r.calls = append(r.calls, host)
	if len(r.calls) == 1 && r.failure != nil {
		return Reservation{}, r.failure
	}
	return Reservation{Host: host, RequestID: s.RequestID, Commit: s.Commit, Base: s.Base, BundleSHA256: s.BundleSHA256, CPUs: s.CPUs, MemoryMiB: s.MemoryMiB, ScratchMiB: s.ScratchMiB, TimeoutSeconds: s.TimeoutSeconds, Handle: "opaque-owner-receipt"}, nil
}

func worker(host string, cpu float64, now time.Time) Worker {
	return Worker{Host: host, Architecture: "amd64", ObservedAt: now, CPUUsedPercent: cpu, AvailableCPUs: 4, AvailableMemoryMiB: 16384, AvailableScratchMiB: 40960, LinuxDocker: true, ChecksContainer: true}
}

func TestPlacementReservesBeforeReturningAndSkipsStaleIncompatibleHosts(t *testing.T) {
	now := time.Unix(1000, 0)
	stale := worker("stale", 0, now.Add(-time.Minute))
	incompatible := worker("windows", 0, now)
	incompatible.LinuxDocker = false
	r := &reservations{failure: ErrBusy}
	result, err := Place(context.Background(), submission(), []Worker{worker("busy", 1, now), worker("next", 15, now), worker("loaded", 70, now), stale, incompatible}, now, r)
	if err != nil {
		t.Fatal(err)
	}
	if result.Host != "next" || strings.Join(r.calls, ",") != "busy,next" || result.Handle == "" {
		t.Fatalf("unreserved/wrong placement: %#v %#v", result, r.calls)
	}
}

func TestPlacementDoesNotRetryUnknownReservationOutcome(t *testing.T) {
	now := time.Unix(1000, 0)
	uncertain := errors.New("unknown transport outcome")
	r := &reservations{failure: uncertain}
	if _, err := Place(context.Background(), submission(), []Worker{worker("one", 1, now), worker("two", 2, now)}, now, r); !errors.Is(err, uncertain) {
		t.Fatal(err)
	}
	if len(r.calls) != 1 {
		t.Fatal("reservation with unknown effects retried on another host")
	}
}

func TestPlacementRejectsCancelledAndIneligibleWork(t *testing.T) {
	now := time.Unix(1000, 0)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := &reservations{}
	if _, err := Place(ctx, submission(), []Worker{worker("one", 1, now)}, now, r); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	bad := worker("one", 1, now)
	bad.AvailableMemoryMiB = 1024
	if _, err := Place(context.Background(), submission(), []Worker{bad}, now, r); !errors.Is(err, ErrNoCapacity) {
		t.Fatal(err)
	}
	if len(r.calls) != 0 {
		t.Fatal("reserved ineligible work")
	}
}

func TestDecodeRejectsOversizedOrTrailingInput(t *testing.T) {
	b, err := json.Marshal(submission())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeSubmission(bytes.NewReader(b)); err != nil {
		t.Fatal(err)
	}
	for _, data := range [][]byte{append(append([]byte{}, b...), []byte(` {}`)...), append(append([]byte{}, b...), bytes.Repeat([]byte(" "), 8192)...)} {
		if _, err := DecodeSubmission(bytes.NewReader(data)); err == nil {
			t.Fatal("accepted trailing/oversized input")
		}
	}
}

type receiptOwner struct {
	result Reservation
	err    error
	calls  int
}

func (r *receiptOwner) Reserve(context.Context, string, Submission) (Reservation, error) {
	r.calls++
	return r.result, r.err
}
func TestPlacementRetainsBadReceiptAndNeverRetriesIt(t *testing.T) {
	now := time.Unix(1000, 0)
	for _, cause := range []error{nil, ErrBusy} {
		r := &receiptOwner{result: Reservation{Handle: "retained-owner-handle"}, err: cause}
		out, err := Place(context.Background(), submission(), []Worker{worker("one", 1, now), worker("two", 2, now)}, now, r)
		if err == nil || out.Handle != r.result.Handle || r.calls != 1 {
			t.Fatalf("lost/retried uncertain receipt: %#v %v", out, err)
		}
	}
}

func TestPlacementRefusesInvalidInventoriesBeforeAdmission(t *testing.T) {
	now := time.Unix(1000, 0)
	for _, inventory := range [][]Worker{{worker("same", 1, now), worker("same", 2, now)}, {worker("bad\nname", 1, now)}} {
		r := &reservations{}
		if _, err := Place(context.Background(), submission(), inventory, now, r); err == nil || len(r.calls) != 0 {
			t.Fatal("admitted invalid inventory")
		}
	}
	for name, edit := range map[string]func(*Worker){
		"future":       func(w *Worker) { w.ObservedAt = now.Add(time.Minute) },
		"nan":          func(w *Worker) { w.CPUUsedPercent = math.NaN() },
		"infinity":     func(w *Worker) { w.CPUUsedPercent = math.Inf(1) },
		"cpu":          func(w *Worker) { w.AvailableCPUs = 0 },
		"architecture": func(w *Worker) { w.Architecture = "riscv64" },
		"container":    func(w *Worker) { w.ChecksContainer = false },
	} {
		t.Run(name, func(t *testing.T) {
			r := &reservations{}
			w := worker("host", 0, now)
			edit(&w)
			if _, err := Place(context.Background(), submission(), []Worker{w}, now, r); !errors.Is(err, ErrNoCapacity) || len(r.calls) != 0 {
				t.Fatal("admitted invalid worker", err)
			}
		})
	}
}

type cancellingOwner struct{ cancel context.CancelFunc }

func (r cancellingOwner) Reserve(_ context.Context, host string, s Submission) (Reservation, error) {
	r.cancel()
	return Reservation{Host: host, RequestID: s.RequestID, Commit: s.Commit, Base: s.Base, BundleSHA256: s.BundleSHA256, CPUs: s.CPUs, MemoryMiB: s.MemoryMiB, ScratchMiB: s.ScratchMiB, TimeoutSeconds: s.TimeoutSeconds, Handle: "retained-after-cancel"}, nil
}
func TestCancelledAdmissionRetainsReceiptWithoutPermittingExecution(t *testing.T) {
	now := time.Unix(1000, 0)
	ctx, cancel := context.WithCancel(context.Background())
	out, err := Place(ctx, submission(), []Worker{worker("one", 0, now)}, now, cancellingOwner{cancel})
	if !errors.Is(err, context.Canceled) || out.Handle != "retained-after-cancel" {
		t.Fatal("cancelled grant lost or returned as executable", out, err)
	}
}
