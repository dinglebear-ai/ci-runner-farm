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
}

type Supervisor struct {
	cfg      Config
	poller   Poller
	leaseMu  sync.Mutex
	leases   map[string]int
	changed  chan struct{}
	snapshot atomic.Pointer[protocol.Snapshot]
	sequence atomic.Uint64
}

func New(cfg Config, poller Poller) (*Supervisor, error) {
	if len(cfg.Pools) == 0 || len(cfg.Pools) > 8 || cfg.Heartbeat <= 0 || cfg.Heartbeat > 10*time.Second {
		return nil, errors.New("invalid_supervisor_config")
	}
	s := &Supervisor{cfg: cfg, poller: poller, leases: map[string]int{}, changed: make(chan struct{})}
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
	close(s.changed)
	s.changed = make(chan struct{})
}

func (s *Supervisor) leaseForPool(pool string) (int, <-chan struct{}) {
	s.leaseMu.Lock()
	defer s.leaseMu.Unlock()
	return s.leases[pool], s.changed
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
				capacity, changed := s.leaseForPool(pool.ID)
				pollCtx, cancelPoll := context.WithCancel(ctx)
				pollDone := make(chan struct{})
				go func() {
					select {
					case <-changed:
						cancelPoll()
					case <-ctx.Done():
						cancelPoll()
					case <-pollDone:
					}
				}()
				poll, err := s.poller.Poll(pollCtx, pool, capacity)
				close(pollDone)
				cancelPoll()
				leaseUpdated := false
				select {
				case <-changed:
					leaseUpdated = true
				default:
				}
				if ctx.Err() != nil {
					return
				}
				// The lease generation changed while this request was in
				// flight. Discard its result regardless of how the HTTP stack
				// wrapped cancellation; publishing it would transiently mark
				// every untouched pool unhealthy and block fair admission.
				if leaseUpdated {
					continue
				}
				if err != nil && !errors.Is(err, context.Canceled) {
					// The supervisor log lives in the root-only state tree.
					// Keep the actual API failure available to operators while
					// the public status snapshot exposes only healthy/unhealthy.
					log.Printf("pool %s message poll failed: %v", pool.ID, err)
				}
				result := protocol.PoolSnapshot{PoolID: pool.ID, ScaleSetID: pool.ScaleSetID,
					AssignedJobs: poll.AssignedJobs, AdvertisedCapacity: capacity, LastMessageID: poll.MessageID,
					SessionHealthy: err == nil, AcquiredHandles: poll.AcquiredHandles}
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
			current[result.PoolID] = result
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
