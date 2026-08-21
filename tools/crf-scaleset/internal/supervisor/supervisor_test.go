package supervisor

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

type barrierPoller struct {
	started chan Pool
	mu      sync.Mutex
	active  map[string]int
}

func (p *barrierPoller) Poll(ctx context.Context, pool Pool, capacity int) (PollResult, error) {
	p.mu.Lock()
	p.active[pool.ID]++
	active := p.active[pool.ID]
	p.mu.Unlock()
	if active != 1 {
		return PollResult{}, errors.New("duplicate concurrent poll")
	}
	p.started <- pool
	<-ctx.Done()
	p.mu.Lock()
	p.active[pool.ID]--
	p.mu.Unlock()
	return PollResult{AssignedJobs: capacity, MessageID: 1}, ctx.Err()
}

func TestSupervisorRejectsConcurrentRun(t *testing.T) {
	p := &barrierPoller{started: make(chan Pool, 1), active: map[string]int{}}
	cfg := validSupervisorConfig()
	s, err := New(cfg, p)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	select {
	case <-p.started:
	case <-time.After(time.Second):
		cancel()
		t.Fatal("first supervisor run did not start")
	}
	if err := s.Run(context.Background()); err == nil || err.Error() != "supervisor_already_running" {
		cancel()
		t.Fatalf("concurrent run was not rejected: %v", err)
	}
	if err := s.Run(nil); err == nil || err.Error() != "supervisor_context_required" {
		cancel()
		t.Fatalf("nil context was not rejected: %v", err)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestOneLongPollPerPool(t *testing.T) {
	p := &barrierPoller{started: make(chan Pool, 8), active: map[string]int{}}
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
	if err := s.SetLeases(leases); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	seen := map[string]bool{}
	for range cfg.Pools {
		select {
		case pool := <-p.started:
			if seen[pool.ID] {
				cancel()
				t.Fatalf("pool %s started more than one concurrent poll", pool.ID)
			}
			seen[pool.ID] = true
		case <-time.After(time.Second):
			cancel()
			t.Fatal("not every pool started its long poll")
		}
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	snapshot := s.Snapshot()
	if len(seen) != len(cfg.Pools) || snapshot.Sequence == 0 {
		t.Fatalf("incomplete supervisor startup: seen=%d snapshot=%#v", len(seen), s.Snapshot())
	}
	for _, pool := range snapshot.Pools {
		if pool.AcquiredHandles == nil {
			t.Fatalf("initial acquired handles must serialize as an empty array: %#v", pool)
		}
	}
}

type staticPoller struct{ result PollResult }

func (p *staticPoller) Poll(context.Context, Pool, int) (PollResult, error) { return p.result, nil }

type blockingPoller struct{}

func (p *blockingPoller) Poll(ctx context.Context, _ Pool, _ int) (PollResult, error) {
	<-ctx.Done()
	return PollResult{}, ctx.Err()
}

func TestInitialSnapshotIsFreshButUnhealthyWhileFirstPollWaits(t *testing.T) {
	cfg := validSupervisorConfig()
	cfg.Heartbeat = 5 * time.Millisecond
	cfg.DemandTTL = 40 * time.Millisecond
	s, err := New(cfg, &blockingPoller{})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	deadline := time.Now().Add(time.Second)
	var snapshot protocol.Snapshot
	for snapshot.Sequence == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
		snapshot = s.Snapshot()
	}
	if snapshot.Sequence == 0 || len(snapshot.Pools) != 1 {
		cancel()
		t.Fatalf("initial snapshot was not published: %#v", snapshot)
	}
	pool := snapshot.Pools[0]
	if pool.SessionHealthy || pool.ObservedAt.IsZero() || !pool.ValidUntil.After(time.Now().UTC()) {
		cancel()
		t.Fatalf("initial pool must be fresh but unhealthy: %#v", pool)
	}
	if got := pool.ValidUntil.Sub(pool.ObservedAt); got != cfg.DemandTTL {
		cancel()
		t.Fatalf("initial pool validity drifted: got=%s want=%s", got, cfg.DemandTTL)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func validSupervisorConfig() Config {
	return Config{ControllerInstanceID: "controller", ConfigRevision: strings.Repeat("a", 64),
		OwnershipRevision: strings.Repeat("b", 64), Heartbeat: time.Second,
		Pools: []Pool{{ID: "rust", ScaleSetID: 1}}}
}

func TestSupervisorDefaultDemandTTLCoversGitHubLongPoll(t *testing.T) {
	s, err := New(validSupervisorConfig(), &staticPoller{})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := s.cfg.DemandTTL, 90*time.Second; got != want {
		t.Fatalf("default demand TTL = %s, want %s", got, want)
	}
}

func TestSupervisorRejectsInvalidIdentityPoolsAndLeases(t *testing.T) {
	valid := validSupervisorConfig()
	tests := []struct {
		name   string
		cfg    Config
		poller Poller
	}{
		{"nil poller", valid, nil},
		{"bad controller", func() Config { c := valid; c.ControllerInstanceID = "../bad"; return c }(), &staticPoller{}},
		{"bad revision", func() Config { c := valid; c.ConfigRevision = "bad"; return c }(), &staticPoller{}},
		{"invalid pool", func() Config { c := valid; c.Pools = []Pool{{ID: "Rust", ScaleSetID: 1}}; return c }(), &staticPoller{}},
		{"zero scale set", func() Config { c := valid; c.Pools = []Pool{{ID: "rust", ScaleSetID: 0}}; return c }(), &staticPoller{}},
		{"duplicate pool", func() Config {
			c := valid
			c.Pools = []Pool{{ID: "rust", ScaleSetID: 1}, {ID: "rust", ScaleSetID: 2}}
			return c
		}(), &staticPoller{}},
		{"duplicate scale set", func() Config {
			c := valid
			c.Pools = []Pool{{ID: "rust", ScaleSetID: 1}, {ID: "python", ScaleSetID: 1}}
			return c
		}(), &staticPoller{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := New(tt.cfg, tt.poller); err == nil {
				t.Fatalf("accepted invalid config: %#v", tt.cfg)
			}
		})
	}
	s, err := New(valid, &staticPoller{})
	if err != nil {
		t.Fatal(err)
	}
	for _, leases := range []map[string]int{{"foreign": 1}, {"rust": -1}, {"rust": 65}} {
		if err := s.SetLeases(leases); err == nil {
			t.Fatalf("accepted invalid leases: %#v", leases)
		}
	}
	if err := s.SetLeases(map[string]int{"rust": 7}); err != nil || s.leaseForPool("rust") != 7 {
		t.Fatalf("valid lease rejected or not stored: err=%v lease=%d", err, s.leaseForPool("rust"))
	}
}

func TestSupervisorClonesConfigurationPollResultsAndSnapshots(t *testing.T) {
	cfg := validSupervisorConfig()
	s, err := New(cfg, &staticPoller{})
	if err != nil {
		t.Fatal(err)
	}
	cfg.Pools[0].ID = "mutated"
	if s.cfg.Pools[0].ID != "rust" {
		t.Fatal("supervisor retained caller-owned pool configuration")
	}
	original := &protocol.Snapshot{Pools: []protocol.PoolSnapshot{{PoolID: "rust", AcquiredHandles: []int64{41}}}}
	s.snapshot.Store(original)
	first := s.Snapshot()
	first.Pools[0].PoolID = "mutated"
	first.Pools[0].AcquiredHandles[0] = 99
	second := s.Snapshot()
	if second.Pools[0].PoolID != "rust" || second.Pools[0].AcquiredHandles[0] != 41 {
		t.Fatalf("snapshot exposed mutable internal state: %#v", second)
	}
	if !validPollResult(PollResult{AssignedJobs: 1, MessageID: 1, AcquiredHandles: []int64{7}}) {
		t.Fatal("valid poll result rejected")
	}
	for _, result := range []PollResult{
		{AssignedJobs: -1}, {MessageID: -1}, {AcquiredHandles: []int64{0}},
		{AcquiredHandles: []int64{7, 7}}, {AcquiredHandles: make([]int64, 65)},
	} {
		if validPollResult(result) {
			t.Fatalf("accepted invalid poll result: %#v", result)
		}
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
		if pool.AcquiredHandles == nil {
			t.Fatalf("healthy empty poll serialized null acquired handles: %#v", pool)
		}
	}
	for _, pool := range first.Pools {
		if !pool.SessionHealthy {
			cancel()
			t.Fatalf("pool %s never became healthy", pool.PoolID)
		}
	}
	heartbeatDeadline := time.Now().Add(time.Second)
	second := first
	for second.Sequence <= first.Sequence && time.Now().Before(heartbeatDeadline) {
		time.Sleep(time.Millisecond)
		second = s.Snapshot()
	}
	if second.Sequence <= first.Sequence {
		cancel()
		t.Fatalf("snapshot heartbeat stalled during long polls: first=%d second=%d", first.Sequence, second.Sequence)
	}
	if got := second.ValidUntil.Sub(second.ObservedAt); got != 2*cfg.Heartbeat {
		cancel()
		t.Fatalf("snapshot validity drifted: got=%s want=%s", got, 2*cfg.Heartbeat)
	}
	var expiresAt time.Time
	for i, pool := range second.Pools {
		if got := pool.ValidUntil.Sub(pool.ObservedAt); got != cfg.DemandTTL {
			cancel()
			t.Fatalf("pool %s validity drifted: got=%s want=%s", pool.PoolID, got, cfg.DemandTTL)
		}
		if !pool.ObservedAt.Equal(first.Pools[i].ObservedAt) {
			cancel()
			t.Fatalf("pool %s heartbeat fabricated a completed observation", pool.PoolID)
		}
		if expiresAt.IsZero() || pool.ValidUntil.Before(expiresAt) {
			expiresAt = pool.ValidUntil
		}
	}
	if wait := time.Until(expiresAt) + cfg.Heartbeat; wait > 0 {
		timer := time.NewTimer(wait)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
		}
	}
	third := s.Snapshot()
	now := time.Now().UTC()
	for _, pool := range third.Pools {
		if pool.ValidUntil.After(now) {
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
