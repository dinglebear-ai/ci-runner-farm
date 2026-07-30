package supervisor

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

type Pool struct {
	ID         string
	ScaleSetID int64
}
type Poller interface {
	Poll(context.Context, Pool, int) (assigned int, messageID int64, err error)
}
type Config struct {
	ControllerInstanceID string
	ConfigRevision       string
	OwnershipRevision    string
	Pools                []Pool
	Heartbeat            time.Duration
}

type Supervisor struct {
	cfg      Config
	poller   Poller
	leases   atomic.Pointer[map[string]int]
	snapshot atomic.Pointer[protocol.Snapshot]
	sequence atomic.Uint64
	limiter  chan struct{}
}

func New(cfg Config, poller Poller) (*Supervisor, error) {
	if len(cfg.Pools) == 0 || len(cfg.Pools) > 8 || cfg.Heartbeat <= 0 || cfg.Heartbeat > 10*time.Second {
		return nil, errors.New("invalid_supervisor_config")
	}
	s := &Supervisor{cfg: cfg, poller: poller, limiter: make(chan struct{}, 4)}
	empty := map[string]int{}
	s.leases.Store(&empty)
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
	s.leases.Store(&copy)
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
				leases := *s.leases.Load()
				capacity := leases[pool.ID]
				s.limiter <- struct{}{}
				assigned, messageID, err := s.poller.Poll(ctx, pool, capacity)
				<-s.limiter
				result := protocol.PoolSnapshot{PoolID: pool.ID, ScaleSetID: pool.ScaleSetID,
					AssignedJobs: assigned, AdvertisedCapacity: capacity, LastMessageID: messageID,
					SessionHealthy: err == nil}
				select {
				case results <- result:
				case <-ctx.Done():
					return
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
	for {
		select {
		case result := <-results:
			current[result.PoolID] = result
			pools := make([]protocol.PoolSnapshot, 0, len(s.cfg.Pools))
			for _, pool := range s.cfg.Pools {
				pools = append(pools, current[pool.ID])
			}
			now := time.Now().UTC()
			snap := protocol.Snapshot{SchemaVersion: 1, ControllerInstanceID: s.cfg.ControllerInstanceID,
				ConfigRevision: s.cfg.ConfigRevision, OwnershipRevision: s.cfg.OwnershipRevision,
				Sequence: s.sequence.Add(1), ObservedAt: now, ValidUntil: now.Add(2 * s.cfg.Heartbeat), Pools: pools}
			s.snapshot.Store(&snap)
		case <-ctx.Done():
			return nil
		}
	}
}
