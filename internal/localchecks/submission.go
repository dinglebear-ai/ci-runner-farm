// Package localchecks defines the checks-only client/coordinator boundary.
// It owns no queue, transport, credentials, Docker effects, or host ledger.
package localchecks

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"regexp"
	"sort"
	"time"
)

var (
	ErrBusy       = errors.New("local_checks_host_busy") // Positive refusal with no effects.
	ErrNoCapacity = errors.New("local_checks_no_eligible_capacity")
	identifier    = regexp.MustCompile(`\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z`)
	commitID      = regexp.MustCompile(`\A[0-9a-f]{40}\z`)
	bundleID      = regexp.MustCompile(`\A[0-9a-f]{64}\z`)
)

// Submission describes one complete committed Core checks workload. No command,
// mutable ref, filesystem path, shell fragment or secret is accepted from clients.
type Submission struct {
	Version        int    `json:"version"`
	Repository     string `json:"repository"`
	Commit         string `json:"commit"`
	Base           string `json:"base"`
	BundleSHA256   string `json:"bundleSHA256"`
	RequestID      string `json:"requestID"`
	CPUs           uint32 `json:"cpus"`
	MemoryMiB      uint64 `json:"memoryMiB"`
	TimeoutSeconds uint32 `json:"timeoutSeconds"`
	ScratchMiB     uint64 `json:"scratchMiB"`
}

func (s Submission) Validate() error {
	if s.Version != 1 || s.Repository != "unraid/core" || !commitID.MatchString(s.Commit) || !commitID.MatchString(s.Base) || !bundleID.MatchString(s.BundleSHA256) || !identifier.MatchString(s.RequestID) || s.CPUs < 1 || s.CPUs > 128 || s.MemoryMiB < 1 || s.MemoryMiB > 1048576 || s.TimeoutSeconds < 1 || s.TimeoutSeconds > 86400 || s.ScratchMiB == 0 || s.ScratchMiB > 1048576 {
		return errors.New("invalid_local_checks_submission")
	}
	return nil
}

func DecodeSubmission(input io.Reader) (Submission, error) {
	var s Submission
	data, err := io.ReadAll(io.LimitReader(input, 8193))
	if err != nil || len(data) > 8192 {
		return s, errors.New("invalid_local_checks_submission")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(&s); err != nil {
		return s, errors.New("invalid_local_checks_submission")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return s, errors.New("invalid_local_checks_submission")
	}
	return s, s.Validate()
}

// Worker is a bounded observation from a configured, authenticated worker.
// Capacity is measured after its host/engine reserves and existing allocations.
// A warm cache never makes an incompatible or stale worker eligible.
type Worker struct {
	Host                string
	Architecture        string
	ObservedAt          time.Time
	CPUUsedPercent      float64
	AvailableCPUs       uint32
	AvailableMemoryMiB  uint64
	AvailableScratchMiB uint64
	LinuxDocker         bool
	ChecksContainer     bool
}

// Reservation is the selected owner's durable receipt. Its Handle is opaque;
// only the owner may interpret, cancel or release it after terminal proof.
type Reservation struct {
	Host, RequestID, Commit, Base, BundleSHA256, Handle string
	CPUs                                                uint32
	MemoryMiB                                           uint64
	ScratchMiB                                          uint64
	TimeoutSeconds                                      uint32
}

// Reserver bridges the existing coordinator/worker admission implementation.
// ErrBusy MUST mean a terminal refusal with no reservation/effects. Every other
// error may have effects and stops placement: it must be reconciled by its owner.
// A successful call holds a real reservation before transfer or execution.
type Reserver interface {
	Reserve(context.Context, string, Submission) (Reservation, error)
}

// Place ranks a configured inventory and reserves once before returning it.
// This is advisory selection plus a real admission callback, not a new scheduler.
func Place(ctx context.Context, s Submission, inventory []Worker, now time.Time, owner Reserver) (Reservation, error) {
	if err := s.Validate(); err != nil {
		return Reservation{}, err
	}
	if owner == nil || len(inventory) > 64 {
		return Reservation{}, errors.New("invalid_local_checks_inventory")
	}
	// Selection and admission are bounded independently of the workload timeout.
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	seen := map[string]bool{}
	candidates := make([]Worker, 0, len(inventory))
	for _, w := range inventory {
		if !identifier.MatchString(w.Host) || seen[w.Host] {
			return Reservation{}, errors.New("invalid_local_checks_inventory")
		}
		seen[w.Host] = true
		age := now.Sub(w.ObservedAt)
		if age < -2*time.Second || age > 15*time.Second || math.IsNaN(w.CPUUsedPercent) || math.IsInf(w.CPUUsedPercent, 0) || w.CPUUsedPercent < 0 || w.CPUUsedPercent > 100 || !w.LinuxDocker || !w.ChecksContainer || (w.Architecture != "amd64" && w.Architecture != "arm64") || w.AvailableCPUs < s.CPUs || w.AvailableMemoryMiB < s.MemoryMiB || w.AvailableScratchMiB < s.ScratchMiB {
			continue
		}
		candidates = append(candidates, w)
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].CPUUsedPercent != candidates[j].CPUUsedPercent {
			return candidates[i].CPUUsedPercent < candidates[j].CPUUsedPercent
		}
		return candidates[i].Host < candidates[j].Host
	})
	for _, w := range candidates {
		if err := ctx.Err(); err != nil {
			return Reservation{}, err
		}
		r, err := owner.Reserve(ctx, w.Host, s)
		if cancelled := ctx.Err(); cancelled != nil {
			return r, cancelled
		}
		if errors.Is(err, ErrBusy) && r == (Reservation{}) {
			continue
		}
		if err != nil {
			return r, fmt.Errorf("local_checks_reservation_uncertain: %w", err)
		}
		if r.Host != w.Host || !r.matches(s) {
			return r, errors.New("local_checks_reservation_receipt_mismatch")
		}
		return r, nil
	}
	if err := ctx.Err(); err != nil {
		return Reservation{}, err
	}
	return Reservation{}, ErrNoCapacity
}
