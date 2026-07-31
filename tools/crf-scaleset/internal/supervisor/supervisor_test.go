package supervisor

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakePoller struct{ active, peak atomic.Int32 }

func (f *fakePoller) Poll(_ context.Context, _ Pool, capacity int) (PollResult, error) {
	n := f.active.Add(1)
	for n > f.peak.Load() && !f.peak.CompareAndSwap(f.peak.Load(), n) {
	}
	time.Sleep(time.Millisecond)
	f.active.Add(-1)
	return PollResult{AssignedJobs: capacity, MessageID: 1}, nil
}
func TestOneLongPollPerPool(t *testing.T) {
	p := &fakePoller{}
	cfg := Config{ControllerInstanceID: "controller", ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64), Heartbeat: 2 * time.Millisecond}
	for i := 0; i < 8; i++ {
		cfg.Pools = append(cfg.Pools, Pool{ID: string(rune('a' + i)), ScaleSetID: int64(i + 1)})
	}
	s, err := New(cfg, p)
	if err != nil {
		t.Fatal(err)
	}
	leases := map[string]int{}
	for _, pool := range cfg.Pools {
		leases[pool.ID] = 1
	}
	s.SetLeases(leases)
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	if err := s.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if p.peak.Load() != int32(len(cfg.Pools)) {
		t.Fatalf("want one concurrent long poll per pool, peak=%d pools=%d", p.peak.Load(), len(cfg.Pools))
	}
	if s.Snapshot().Sequence == 0 {
		t.Fatal("no snapshot")
	}
}

type stickyPoller struct {
	mu    sync.Mutex
	calls map[int64]int
}

func (p *stickyPoller) Poll(ctx context.Context, pool Pool, capacity int) (PollResult, error) {
	p.mu.Lock()
	p.calls[pool.ScaleSetID]++
	call := p.calls[pool.ScaleSetID]
	p.mu.Unlock()
	if call == 1 {
		return PollResult{AssignedJobs: capacity, MessageID: 1}, nil
	}
	<-ctx.Done()
	return PollResult{}, ctx.Err()
}

func TestSnapshotHeartbeatContinuesWhileLongPollsWait(t *testing.T) {
	p := &stickyPoller{calls: map[int64]int{}}
	cfg := Config{ControllerInstanceID: "controller", ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64), Heartbeat: 5 * time.Millisecond,
		DemandTTL: 40 * time.Millisecond}
	for i := 0; i < 7; i++ {
		cfg.Pools = append(cfg.Pools, Pool{ID: string(rune('a' + i)), ScaleSetID: int64(i + 1)})
	}
	s, err := New(cfg, p)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	deadline := time.Now().Add(250 * time.Millisecond)
	for time.Now().Before(deadline) {
		snapshot := s.Snapshot()
		healthy := 0
		for _, pool := range snapshot.Pools {
			if pool.SessionHealthy {
				healthy++
			}
		}
		if healthy == len(cfg.Pools) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	first := s.Snapshot()
	if len(first.Pools) != len(cfg.Pools) {
		cancel()
		t.Fatalf("want %d initialized pools, got %d", len(cfg.Pools), len(first.Pools))
	}
	for _, pool := range first.Pools {
		if !pool.SessionHealthy {
			cancel()
			t.Fatalf("pool %s never became healthy", pool.PoolID)
		}
	}
	time.Sleep(3 * cfg.Heartbeat)
	second := s.Snapshot()
	if second.Sequence <= first.Sequence {
		cancel()
		t.Fatalf("snapshot heartbeat stalled during long polls: first=%d second=%d", first.Sequence, second.Sequence)
	}
	if !second.ValidUntil.After(time.Now().UTC()) {
		cancel()
		t.Fatalf("snapshot expired during healthy long polls: valid_until=%s", second.ValidUntil)
	}
	now := time.Now().UTC()
	for i, pool := range second.Pools {
		if !pool.ValidUntil.After(now) {
			cancel()
			t.Fatalf("pool %s expired inside the bounded long-poll window", pool.PoolID)
		}
		if !pool.ObservedAt.Equal(first.Pools[i].ObservedAt) {
			cancel()
			t.Fatalf("pool %s heartbeat fabricated a completed observation", pool.PoolID)
		}
	}
	time.Sleep(6 * cfg.Heartbeat)
	third := s.Snapshot()
	for _, pool := range third.Pools {
		if pool.ValidUntil.After(time.Now().UTC()) {
			cancel()
			t.Fatalf("pool %s stayed fresh beyond the bounded long-poll window", pool.PoolID)
		}
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

type capacityObservation struct {
	pool     string
	capacity int
}

type leaseAwarePoller struct {
	observed chan capacityObservation
	release  chan PollResult
}

func (p *leaseAwarePoller) Poll(ctx context.Context, pool Pool, capacity int) (PollResult, error) {
	p.observed <- capacityObservation{pool: pool.ID, capacity: capacity}
	select {
	case result := <-p.release:
		return result, nil
	case <-ctx.Done():
		return PollResult{}, ctx.Err()
	}
}

func TestLeaseChangePreservesInflightResultThenImmediatelyRepolls(t *testing.T) {
	p := &leaseAwarePoller{observed: make(chan capacityObservation, 8), release: make(chan PollResult, 8)}
	cfg := Config{ControllerInstanceID: "controller", ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64), Heartbeat: 10 * time.Second}
	cfg.Pools = []Pool{{ID: "rust", ScaleSetID: 1}}
	s, err := New(cfg, p)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	got := <-p.observed
	if got.capacity != 0 {
		cancel()
		t.Fatalf("initial capacity = %d, want 0", got.capacity)
	}
	s.SetLeases(map[string]int{"rust": 2})
	select {
	case got := <-p.observed:
		cancel()
		t.Fatalf("capacity change canceled an in-flight poll: %#v", got)
	case <-time.After(20 * time.Millisecond):
	}
	p.release <- PollResult{AssignedJobs: 1, MessageID: 9, AcquiredHandles: []int64{41}}
	select {
	case got := <-p.observed:
		if got.capacity != 2 {
			cancel()
			t.Fatalf("successor capacity = %d, want 2", got.capacity)
		}
	case <-time.After(100 * time.Millisecond):
		cancel()
		t.Fatal("lease change did not immediately issue a successor poll")
	}
	deadline := time.Now().Add(100 * time.Millisecond)
	for time.Now().Before(deadline) {
		snapshot := s.Snapshot()
		if len(snapshot.Pools) == 1 && snapshot.Pools[0].LastMessageID == 9 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if snapshot := s.Snapshot(); len(snapshot.Pools) != 1 ||
		snapshot.Pools[0].LastMessageID != 9 || snapshot.Pools[0].AdvertisedCapacity != 0 {
		cancel()
		t.Fatalf("old-capacity poll result was discarded: %#v", snapshot)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

type cancellationWrappingPoller struct {
	calls    atomic.Int32
	observed chan int
}

func (p *cancellationWrappingPoller) Poll(ctx context.Context, _ Pool, capacity int) (PollResult, error) {
	call := p.calls.Add(1)
	p.observed <- capacity
	if call == 1 {
		return PollResult{AssignedJobs: 0, MessageID: 1}, nil
	}
	<-ctx.Done()
	return PollResult{}, errors.New("transport discarded the cancellation cause")
}

func TestLeaseChangeDoesNotCancelPollOrDowngradeSessionHealth(t *testing.T) {
	p := &cancellationWrappingPoller{observed: make(chan int, 8)}
	cfg := Config{ControllerInstanceID: "controller", ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64), Heartbeat: time.Millisecond,
		Pools: []Pool{{ID: "rust", ScaleSetID: 1}}}
	s, err := New(cfg, p)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	<-p.observed // initial successful poll
	<-p.observed // second poll waiting with zero capacity
	deadline := time.Now().Add(100 * time.Millisecond)
	for time.Now().Before(deadline) {
		snapshot := s.Snapshot()
		if len(snapshot.Pools) == 1 && snapshot.Pools[0].SessionHealthy {
			break
		}
		time.Sleep(time.Millisecond)
	}
	healthy := s.Snapshot()
	if len(healthy.Pools) != 1 || !healthy.Pools[0].SessionHealthy {
		cancel()
		t.Fatal("initial successful poll did not make the session healthy")
	}
	s.SetLeases(map[string]int{"rust": 1})
	select {
	case capacity := <-p.observed:
		cancel()
		t.Fatalf("lease change canceled an in-flight poll and reissued capacity %d", capacity)
	case <-time.After(20 * time.Millisecond):
	}
	if !s.Snapshot().Pools[0].SessionHealthy {
		cancel()
		t.Fatal("intentional lease cancellation downgraded session health")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
