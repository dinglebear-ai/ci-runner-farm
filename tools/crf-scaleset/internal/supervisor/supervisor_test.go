package supervisor

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type fakePoller struct{ active, peak atomic.Int32 }

func (f *fakePoller) Poll(_ context.Context, _ Pool, capacity int) (int, int64, error) {
	n := f.active.Add(1)
	for n > f.peak.Load() && !f.peak.CompareAndSwap(f.peak.Load(), n) {
	}
	time.Sleep(time.Millisecond)
	f.active.Add(-1)
	return capacity, 1, nil
}
func TestOneWorkerPerPoolAndBoundedLimiter(t *testing.T) {
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
	if p.peak.Load() > 4 {
		t.Fatalf("limiter exceeded: %d", p.peak.Load())
	}
	if s.Snapshot().Sequence == 0 {
		t.Fatal("no snapshot")
	}
}
