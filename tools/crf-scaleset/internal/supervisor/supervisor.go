package supervisor

import (
	"context"
	"errors"
	"log"
	"maps"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

type Pool struct {
	ID         string
	ScaleSetID int64
}
type PollResult struct {
	AssignedJobs    int
	MessageID       int64
	AcquiredHandles []int64
}
type Poller interface {
	Poll(context.Context, Pool, int) (PollResult, error)
}
type Config struct {
	ControllerInstanceID string
	ConfigRevision       string
	OwnershipRevision    string
	Pools                []Pool
	Heartbeat            time.Duration
	DemandTTL            time.Duration
}

type Supervisor struct {
	cfg      Config
	poller   Poller
	leaseMu  sync.Mutex
	leases   map[string]int
	snapshot atomic.Pointer[protocol.Snapshot]
	sequence atomic.Uint64
}

func New(cfg Config, poller Poller) (*Supervisor, error) {
	if cfg.DemandTTL == 0 {
		cfg.DemandTTL = 90 * time.Second
	}
	if len(cfg.Pools) == 0 || len(cfg.Pools) > 8 || cfg.Heartbeat <= 0 || cfg.Heartbeat > 10*time.Second ||
		cfg.DemandTTL < 2*cfg.Heartbeat || cfg.DemandTTL > 2*time.Minute {
		return nil, errors.New("invalid_supervisor_config")
	}
	s := &Supervisor{cfg: cfg, poller: poller, leases: map[string]int{}}
	return s, nil
}

func (s *Supervisor) SetLeases(leases map[string]int) {
	copy := make(map[string]int, len(leases))
	for pool, capacity := range leases {
		if capacity < 0 {
			capacity = 0
		}
		copy[pool] = capacity
	}
	s.leaseMu.Lock()
	defer s.leaseMu.Unlock()
	if maps.Equal(s.leases, copy) {
		return
	}
	s.leases = copy
}

func (s *Supervisor) leaseForPool(pool string) int {
	s.leaseMu.Lock()
	defer s.leaseMu.Unlock()
	return s.leases[pool]
}

func (s *Supervisor) Snapshot() protocol.Snapshot {
	if p := s.snapshot.Load(); p != nil {
		return *p
	}
	return protocol.Snapshot{}
}

func (s *Supervisor) Run(ctx context.Context) error {
	var wg sync.WaitGroup
	results := make(chan protocol.PoolSnapshot, len(s.cfg.Pools))
	for _, pool := range s.cfg.Pools {
		pool := pool
		wg.Add(1)
		go func() {
			defer wg.Done()
			ticker := time.NewTicker(s.cfg.Heartbeat)
			defer ticker.Stop()
			for {
				capacity := s.leaseForPool(pool.ID)
				poll, err := s.poller.Poll(ctx, pool, capacity)
				if ctx.Err() != nil {
					return
				}
				if err != nil && !errors.Is(err, context.Canceled) {
					// The supervisor log lives in the root-only state tree.
					// Keep the actual API failure available to operators while
					// the public status snapshot exposes only healthy/unhealthy.
					log.Printf("pool %s message poll failed: %v", pool.ID, err)
				}
				now := time.Now().UTC()
				result := protocol.PoolSnapshot{PoolID: pool.ID, ScaleSetID: pool.ScaleSetID,
					AssignedJobs: poll.AssignedJobs, AdvertisedCapacity: capacity, LastMessageID: poll.MessageID,
					SessionHealthy: err == nil, AcquiredHandles: poll.AcquiredHandles}
				if err == nil {
					result.ObservedAt = now
					result.ValidUntil = now.Add(s.cfg.DemandTTL)
				}
				select {
				case results <- result:
				case <-ctx.Done():
					return
				}
				// A capacity change cannot cancel an in-flight long poll: the
				// remote may already have accepted its old max-capacity header.
				// Publish/reconcile that definitive result while the old lease
				// remains charged, then immediately issue the successor poll
				// with the newest capacity instead of waiting a heartbeat.
				if s.leaseForPool(pool.ID) != capacity {
					continue
				}
				select {
				case <-ticker.C:
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	defer wg.Wait()
	current := map[string]protocol.PoolSnapshot{}
	for _, pool := range s.cfg.Pools {
		current[pool.ID] = protocol.PoolSnapshot{PoolID: pool.ID, ScaleSetID: pool.ScaleSetID}
	}
	publish := func() {
		pools := make([]protocol.PoolSnapshot, 0, len(s.cfg.Pools))
		for _, pool := range s.cfg.Pools {
			pools = append(pools, current[pool.ID])
		}
		now := time.Now().UTC()
		snap := protocol.Snapshot{SchemaVersion: 1, ControllerInstanceID: s.cfg.ControllerInstanceID,
			ConfigRevision: s.cfg.ConfigRevision, OwnershipRevision: s.cfg.OwnershipRevision,
			Sequence: s.sequence.Add(1), ObservedAt: now, ValidUntil: now.Add(2 * s.cfg.Heartbeat), Pools: pools}
		s.snapshot.Store(&snap)
	}
	heartbeat := time.NewTicker(s.cfg.Heartbeat)
	defer heartbeat.Stop()
	publish()
	for {
		select {
		case result := <-results:
			if result.SessionHealthy {
				current[result.PoolID] = result
			} else {
				// REVIEW(crf-v3q.13.6, MUST-CHECK): A failed or wedged poll
				// must not turn old demand into fresh zero. Preserve the last
				// authoritative counts/timestamps and only downgrade health.
				previous := current[result.PoolID]
				previous.SessionHealthy = false
				current[result.PoolID] = previous
			}
			publish()
		case <-heartbeat.C:
			// GitHub's message API is a long poll. Keep publishing the last
			// complete observation while workers wait so Fleet and the
			// scheduler do not mistake an active poll for a dead session.
			publish()
		case <-ctx.Done():
			return nil
		}
	}
}
