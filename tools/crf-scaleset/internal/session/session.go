package session

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"slices"
	"strings"
	"sync"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/journal"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/supervisor"
)

var ErrAmbiguousAcquire = errors.New("ambiguous_acquisition_session_reset")

const (
	maxJSONSafeInteger      int64 = 1<<53 - 1
	acquirableLookupTimeout       = 2 * time.Second
)

type Config struct {
	API               crfgithub.ScaleSetAPI
	Store             journal.Store
	ConfigRevision    string
	OwnershipRevision string
	ConsumedHandles   map[string]bool
}

type fastLaneState struct {
	capacity      int
	reservedSlots int
	holdUntil     time.Time
	holdDuration  time.Duration
	longThreshold time.Duration
	borrowPending bool
}

type Poller struct {
	cfg                Config
	mu                 sync.Mutex
	journalMu          sync.Mutex
	sessions           map[int64]crfgithub.Session
	rejectedSessions   map[int64]crfgithub.Session
	assigned           map[int64]int
	advertised         map[int64]int
	pending            map[int64][]int64
	replay             map[journal.Key]journal.Entry
	consumed           map[string]bool
	poolMu             map[int64]*sync.Mutex
	pollCancels        map[int64]context.CancelFunc
	pollActive         map[int64]int
	runtimes           map[runtimeDigest]runtimeEstimate
	lastRuntimePersist time.Time
	runtimePersistMu   sync.Mutex
	runtimeDirty       bool
	runtimeGeneration  uint64
	acquirableHealth   map[int64]string
	demand             map[int64]int
	fastLanes          map[int64]fastLaneState
	fastLaneTunings    map[int64]fastLanePolicy
	fastLanePersistMu  sync.Mutex
}

type sessionCloser interface {
	CloseMessageSession(context.Context, crfgithub.Session) error
}

func New(cfg Config) (*Poller, error) {
	if cfg.API == nil || cfg.Store.Path == "" || len(cfg.ConfigRevision) != 64 ||
		len(cfg.OwnershipRevision) != 64 {
		return nil, errors.New("invalid_session_config")
	}
	replayed, err := cfg.Store.Replay()
	if err != nil {
		return nil, err
	}
	runtimes := loadRuntimeHints(cfg.Store)
	fastLanes := loadFastLaneHints(cfg.Store)
	p := &Poller{cfg: cfg, sessions: map[int64]crfgithub.Session{}, rejectedSessions: map[int64]crfgithub.Session{}, assigned: map[int64]int{},
		advertised: map[int64]int{},
		pending:    map[int64][]int64{}, replay: replayed, consumed: map[string]bool{},
		poolMu: map[int64]*sync.Mutex{}, pollCancels: map[int64]context.CancelFunc{}, pollActive: map[int64]int{}, runtimes: runtimes,
		acquirableHealth: map[int64]string{}, demand: map[int64]int{},
		fastLanes: fastLanes, fastLaneTunings: map[int64]fastLanePolicy{}}
	for key, consumed := range cfg.ConsumedHandles {
		if consumed {
			p.consumed[key] = true
		}
	}
	latestAcked := map[int64]int64{}
	for _, entry := range replayed {
		switch entry.Phase {
		case "committed", "ack_pending", "acked":
			p.appendPending(entry.ScaleSetID, entry.AcquiredHandles...)
		}
		if entry.Phase == "acked" && entry.MessageID >= latestAcked[entry.ScaleSetID] {
			latestAcked[entry.ScaleSetID] = entry.MessageID
			p.assigned[entry.ScaleSetID] = entry.AssignedCount
		}
	}
	for scaleSetID, assigned := range p.assigned {
		if assigned == 0 {
			delete(p.pending, scaleSetID)
		}
	}
	return p, nil
}

func handleKey(scaleSetID, handle int64) string {
	return fmt.Sprintf("%d:%d", scaleSetID, handle)
}

func (p *Poller) appendPending(scaleSetID int64, handles ...int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, handle := range handles {
		if !p.consumed[handleKey(scaleSetID, handle)] {
			p.pending[scaleSetID] = appendUnique(p.pending[scaleSetID], handle)
		}
	}
}

func (p *Poller) poolLock(scaleSetID int64) *sync.Mutex {
	p.mu.Lock()
	defer p.mu.Unlock()
	lock := p.poolMu[scaleSetID]
	if lock == nil {
		lock = &sync.Mutex{}
		p.poolMu[scaleSetID] = lock
	}
	return lock
}

func (p *Poller) pendingSnapshot(scaleSetID int64) []int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Clone(p.pending[scaleSetID])
}

func (p *Poller) removePending(scaleSetID int64, handles ...int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, handle := range handles {
		if idx := slices.Index(p.pending[scaleSetID], handle); idx >= 0 {
			p.pending[scaleSetID] = slices.Delete(p.pending[scaleSetID], idx, idx+1)
		}
	}
}

func (p *Poller) clearPending(scaleSetID int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.pending, scaleSetID)
}

func (p *Poller) ensureCapacityHandles(scaleSetID int64, sessionID string, capacity int) error {
	if capacity < 0 || capacity > 64 {
		return errors.New("invalid_advertised_capacity")
	}
	// Synthetic handles exist so an idle pool can still be handed capacity and
	// pick work up. Fabricating them up to the full advertised capacity, though,
	// lets a pool with nothing queued consume every node slot and starve a pool
	// that has real jobs waiting -- the node's concurrency is shared across all
	// pools. Cap them at the work GitHub actually reports for this scale set.
	// Until a statistics-bearing batch has been observed the demand is unknown,
	// and the original full-capacity behaviour is kept rather than guessing zero.
	target := capacity
	if observed, known := p.demandCount(scaleSetID); known && observed < target {
		target = observed
	}
	current := p.pendingSnapshot(scaleSetID)
	if len(current) >= target {
		return nil
	}
	handles := slices.Clone(current)
	for len(handles) < target {
		var encoded [8]byte
		if _, err := rand.Read(encoded[:]); err != nil {
			return err
		}
		handle := int64(binary.BigEndian.Uint64(encoded[:]) & uint64(maxJSONSafeInteger))
		if handle == 0 || slices.Contains(handles, handle) {
			continue
		}
		p.mu.Lock()
		consumed := p.consumed[handleKey(scaleSetID, handle)]
		p.mu.Unlock()
		if consumed {
			continue
		}
		handles = append(handles, handle)
	}
	entry := journal.Entry{ScaleSetID: scaleSetID, SessionID: sessionID, MessageID: 0,
		Phase: "acked", AssignedCount: p.assignedCount(scaleSetID),
		AcquiredHandles: handles, ConfigRevision: p.cfg.ConfigRevision,
		OwnershipRevision: p.cfg.OwnershipRevision}
	if err := p.append(entry); err != nil {
		return err
	}
	p.appendPending(scaleSetID, handles...)
	return nil
}

func (p *Poller) fastLaneStatus(scaleSetID int64, capacity int) (string, int64, int64, int, int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if capacity < 2 {
		return "inactive", 0, 0, 0, 0
	}
	policy := p.fastLaneTunings[scaleSetID]
	if policy.longThreshold <= 0 || policy.holdDuration <= 0 || policy.reserveSlots <= 0 {
		policy = defaultFastLanePolicy()
	}
	lane, active := p.fastLanes[scaleSetID]
	if !active {
		reservedSlots := min(policy.reserveSlots, min(fastLaneMaxReservedSlots, capacity-1))
		return "inactive", policy.longThreshold.Milliseconds(), policy.holdDuration.Milliseconds(), reservedSlots, 0
	}
	longThreshold := lane.longThreshold
	if longThreshold <= 0 {
		longThreshold = policy.longThreshold
	}
	holdDuration := lane.holdDuration
	if holdDuration <= 0 {
		holdDuration = policy.holdDuration
	}
	state := "holding"
	if lane.borrowPending {
		state = "borrow_pending"
	}
	reservedSlots := lane.reservedSlots
	if reservedSlots <= 0 {
		reservedSlots = 1
	}
	return state, longThreshold.Milliseconds(), holdDuration.Milliseconds(), reservedSlots, lane.holdUntil.UnixMilli()
}

func (p *Poller) result(scaleSetID int64, sessionID string, capacity int,
	messageID int64) (supervisor.PollResult, error) {
	if err := p.ensureCapacityHandles(scaleSetID, sessionID, capacity); err != nil {
		return supervisor.PollResult{}, err
	}
	state, thresholdMS, holdDurationMS, reservedSlots, holdUntilMS := p.fastLaneStatus(scaleSetID, capacity)
	return supervisor.PollResult{AssignedJobs: p.assignedCount(scaleSetID),
		MessageID: messageID, AcquiredHandles: p.pendingSnapshot(scaleSetID),
		FastLaneState: state, FastLaneLongThresholdMillis: thresholdMS,
		FastLaneHoldDurationMillis: holdDurationMS, FastLaneReservedSlots: reservedSlots,
		FastLaneHoldUntilMillis: holdUntilMS}, nil
}

func (p *Poller) assignedCount(scaleSetID int64) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.assigned[scaleSetID]
}

func (p *Poller) setAssigned(scaleSetID int64, count int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.assigned[scaleSetID] = count
}

// demandCount reports the last observed real work for a scale set: jobs GitHub
// has queued for it plus jobs already assigned to it. The bool is false until a
// statistics-bearing batch has been seen, so callers can tell "no demand" apart
// from "not measured yet".
func (p *Poller) demandCount(scaleSetID int64) (int, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	value, ok := p.demand[scaleSetID]
	return value, ok
}

func (p *Poller) setDemand(scaleSetID int64, count int) {
	if count < 0 {
		count = 0
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.demand == nil {
		p.demand = map[int64]int{}
	}
	p.demand[scaleSetID] = count
}

func (p *Poller) setAdvertised(scaleSetID int64, capacity int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.advertised[scaleSetID] = capacity
}

func (p *Poller) advertisedState(scaleSetID int64, capacity int) (bool, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	previous, known := p.advertised[scaleSetID]
	return known, known && previous != capacity
}

func appendUnique(existing []int64, ids ...int64) []int64 {
	for _, id := range ids {
		if id > 0 && !slices.Contains(existing, id) {
			existing = append(existing, id)
		}
	}
	return existing
}

func (p *Poller) session(ctx context.Context, scaleSetID int64) (crfgithub.Session, bool, error) {
	p.mu.Lock()
	if existing, ok := p.sessions[scaleSetID]; ok {
		p.mu.Unlock()
		return existing, false, nil
	}
	p.mu.Unlock()
	created, err := p.cfg.API.CreateMessageSession(ctx, scaleSetID)
	if err != nil {
		return crfgithub.Session{}, false, err
	}
	if created.ScaleSetID != scaleSetID || created.ID == "" {
		return crfgithub.Session{}, false, errors.New("invalid_message_session")
	}
	return created, true, nil
}

func (p *Poller) commitSession(created crfgithub.Session, isNew bool) {
	if !isNew {
		return
	}
	p.mu.Lock()
	p.sessions[created.ScaleSetID] = created
	p.mu.Unlock()
}

func (p *Poller) rejectSession(ctx context.Context, created crfgithub.Session, isNew bool, cause error) error {
	if !isNew {
		return cause
	}
	closer, ok := p.cfg.API.(sessionCloser)
	if !ok {
		p.retainRejectedSession(created)
		return errors.Join(cause, errors.New("close_rejected_message_session_unsupported"))
	}
	if err := closer.CloseMessageSession(ctx, created); err != nil {
		p.retainRejectedSession(created)
		return errors.Join(cause, fmt.Errorf("close_rejected_message_session: %w", err))
	}
	return cause
}

func (p *Poller) retainRejectedSession(session crfgithub.Session) {
	p.mu.Lock()
	if p.rejectedSessions == nil {
		p.rejectedSessions = map[int64]crfgithub.Session{}
	}
	p.rejectedSessions[session.ScaleSetID] = session
	p.mu.Unlock()
}

func (p *Poller) retryRejectedSession(ctx context.Context, scaleSetID int64) error {
	p.mu.Lock()
	rejected, exists := p.rejectedSessions[scaleSetID]
	p.mu.Unlock()
	if !exists {
		return nil
	}
	closer, ok := p.cfg.API.(sessionCloser)
	if !ok {
		return errors.New("close_rejected_message_session_unsupported")
	}
	if err := closer.CloseMessageSession(ctx, rejected); err != nil {
		return fmt.Errorf("close_rejected_message_session: %w", err)
	}
	p.mu.Lock()
	if p.rejectedSessions[scaleSetID] == rejected {
		delete(p.rejectedSessions, scaleSetID)
	}
	p.mu.Unlock()
	return nil
}

func (p *Poller) resetAmbiguousAcquire(ctx context.Context, scaleSetID int64,
	key journal.Key) error {
	closer, ok := p.cfg.API.(sessionCloser)
	if !ok {
		return errors.New("ambiguous_acquisition_session_reset_unsupported")
	}
	p.mu.Lock()
	active, exists := p.sessions[scaleSetID]
	p.mu.Unlock()
	if !exists {
		return errors.New("ambiguous_acquisition_session_missing")
	}
	// GitHub redelivers an unacknowledged message unchanged. Therefore an
	// Available entry cannot prove that the prior AcquireJobs request failed.
	// Delete the entire message session as the bounded requeue boundary before
	// removing the ambiguous local replay intent.
	if err := closer.CloseMessageSession(ctx, active); err != nil {
		return fmt.Errorf("close_ambiguous_acquisition_session: %w", err)
	}
	p.journalMu.Lock()
	defer p.journalMu.Unlock()
	p.mu.Lock()
	delete(p.sessions, scaleSetID)
	keep := make(map[journal.Key]journal.Entry, len(p.replay))
	for replayKey, entry := range p.replay {
		if replayKey != key {
			keep[replayKey] = entry
		}
	}
	entries := make([]journal.Entry, 0, len(keep))
	for _, entry := range keep {
		entries = append(entries, entry)
	}
	p.mu.Unlock()
	if err := p.cfg.Store.Rewrite(entries); err != nil {
		return fmt.Errorf("compact_ambiguous_acquisition_session: %w", err)
	}
	p.mu.Lock()
	p.replay = keep
	p.mu.Unlock()
	return ErrAmbiguousAcquire
}

func (p *Poller) append(entry journal.Entry) error {
	// REVIEW(crf-v3q.13.13): Preserve journal ordering with a dedicated writer
	// lock, but never hold the shared poller-state lock across filesystem I/O
	// or fsync. Independent pool polls can continue updating in-memory state.
	p.journalMu.Lock()
	defer p.journalMu.Unlock()
	p.mu.Lock()
	entry.AcquiredHandles = slices.DeleteFunc(slices.Clone(entry.AcquiredHandles), func(handle int64) bool {
		return p.consumed[handleKey(entry.ScaleSetID, handle)]
	})
	p.mu.Unlock()
	size, err := p.cfg.Store.Size()
	if err != nil {
		return err
	}
	if size > journal.MaxJournalBytes-journal.MaxEntryBytes {
		if err := p.compactJournalLocked(); err != nil {
			return err
		}
		size, err = p.cfg.Store.Size()
		if err != nil {
			return err
		}
		if size > journal.MaxJournalBytes-journal.MaxEntryBytes {
			return errors.New("journal_capacity_exhausted")
		}
	}
	if err := p.cfg.Store.Append(entry); err != nil {
		return err
	}
	p.mu.Lock()
	p.replay[entry.Key()] = entry
	p.mu.Unlock()
	size, err = p.cfg.Store.Size()
	if err != nil {
		return err
	}
	if size > journal.MaxJournalBytes {
		return p.compactJournalLocked()
	}
	return nil
}

// compactJournalLocked requires journalMu and performs no filesystem I/O while
// holding mu. Consumed handles are removed from retained ACK records so their
// external tombstones can be safely retired after this rewrite succeeds.
func (p *Poller) compactJournalLocked() error {
	highestAcked := map[int64]journal.Key{}
	keep := map[journal.Key]journal.Entry{}
	p.mu.Lock()
	for key, entry := range p.replay {
		if entry.Phase != "acked" {
			keep[key] = entry
			continue
		}
		filtered := make([]int64, 0, len(entry.AcquiredHandles))
		for _, handle := range entry.AcquiredHandles {
			if !p.consumed[handleKey(entry.ScaleSetID, handle)] {
				filtered = append(filtered, handle)
			}
		}
		if len(filtered) > 0 {
			entry.AcquiredHandles = filtered
			keep[key] = entry
		}
		highest, ok := highestAcked[entry.ScaleSetID]
		if !ok || key.MessageID > highest.MessageID {
			highestAcked[entry.ScaleSetID] = key
		}
	}
	for _, key := range highestAcked {
		entry := p.replay[key]
		entry.AcquiredHandles = slices.DeleteFunc(slices.Clone(entry.AcquiredHandles), func(handle int64) bool {
			return p.consumed[handleKey(entry.ScaleSetID, handle)]
		})
		keep[key] = entry
	}
	p.mu.Unlock()
	entries := make([]journal.Entry, 0, len(keep))
	for _, entry := range keep {
		entries = append(entries, entry)
	}
	if err := p.cfg.Store.Rewrite(entries); err != nil {
		return err
	}
	p.mu.Lock()
	p.replay = keep
	p.mu.Unlock()
	return nil
}

func (p *Poller) acquisitionBatch(ctx context.Context, pool supervisor.Pool, batch crfgithub.MessageBatch) crfgithub.MessageBatch {
	if batch.Statistics == nil {
		return batch
	}
	visibleCount := max(len(batch.Available), len(batch.AvailableJobs))
	if batch.Statistics.TotalAvailableJobs <= visibleCount {
		return batch
	}
	lookupCtx, cancel := context.WithTimeout(ctx, acquirableLookupTimeout)
	jobs, err := p.cfg.API.GetAcquirableJobs(lookupCtx, pool.ScaleSetID)
	cancel()
	if err != nil {
		state := "error"
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(lookupCtx.Err(), context.DeadlineExceeded) {
			state = "timeout"
		}
		p.recordAcquirableHealth(pool.ScaleSetID, state, err)
		return batch
	}
	if len(jobs) == 0 {
		p.recordAcquirableHealth(pool.ScaleSetID, "empty", nil)
		return batch
	}
	p.recordAcquirableHealth(pool.ScaleSetID, "healthy", nil)
	merged := slices.Clone(batch.AvailableJobs)
	seen := make(map[int64]bool, len(merged)+len(jobs))
	for _, job := range merged {
		if job.RequestID > 0 {
			seen[job.RequestID] = true
		}
	}
	for _, job := range jobs {
		if job.RequestID <= 0 || seen[job.RequestID] {
			continue
		}
		seen[job.RequestID] = true
		merged = append(merged, job)
	}
	if len(merged) == 0 {
		return batch
	}
	batch.AvailableJobs = merged
	return batch
}

func (p *Poller) recordAcquirableHealth(scaleSetID int64, state string, err error) {
	p.mu.Lock()
	if p.acquirableHealth == nil {
		p.acquirableHealth = map[int64]string{}
	}
	previous := p.acquirableHealth[scaleSetID]
	if previous == state {
		p.mu.Unlock()
		return
	}
	p.acquirableHealth[scaleSetID] = state
	p.mu.Unlock()
	if state == "healthy" {
		if previous != "" && previous != "healthy" {
			log.Printf("acquirable lookup recovered scale_set_id=%d previous=%s", scaleSetID, previous)
		}
		return
	}
	log.Printf("acquirable lookup degraded scale_set_id=%d state=%s err=%v", scaleSetID, state, err)
}

func (p *Poller) clearFastLane(scaleSetID int64) {
	p.mu.Lock()
	_, existed := p.fastLanes[scaleSetID]
	delete(p.fastLanes, scaleSetID)
	p.mu.Unlock()
	if existed {
		p.persistFastLanes()
	}
}

func (p *Poller) startFastLane(scaleSetID int64, capacity int, now time.Time) {
	p.startFastLaneWithPolicy(scaleSetID, capacity, now, defaultFastLanePolicy())
}

func (p *Poller) startFastLaneWithPolicy(scaleSetID int64, capacity int, now time.Time, policy fastLanePolicy) {
	if capacity < 2 {
		p.clearFastLane(scaleSetID)
		return
	}
	if policy.longThreshold <= 0 || policy.holdDuration <= 0 {
		policy = defaultFastLanePolicy()
	}
	if policy.reserveSlots <= 0 {
		policy.reserveSlots = 1
	}
	policy.reserveSlots = min(policy.reserveSlots, min(fastLaneMaxReservedSlots, capacity-1))
	policy.longThreshold = clampFastLaneDuration(
		policy.longThreshold, fastLaneMinLongThreshold, fastLaneMaxLongThreshold)
	policy.holdDuration = clampFastLaneDuration(
		policy.holdDuration, fastLaneMinHoldDuration, fastLaneMaxHoldDuration)
	p.mu.Lock()
	if p.fastLanes == nil {
		p.fastLanes = map[int64]fastLaneState{}
	}
	p.fastLanes[scaleSetID] = fastLaneState{capacity: capacity, reservedSlots: policy.reserveSlots,
		holdUntil: now.Add(policy.holdDuration), holdDuration: policy.holdDuration,
		longThreshold: policy.longThreshold}
	p.mu.Unlock()
	p.persistFastLanes()
}

func (p *Poller) markFastLaneBorrowPending(scaleSetID int64, expected fastLaneState) bool {
	p.mu.Lock()
	current, exists := p.fastLanes[scaleSetID]
	if !exists || current.capacity != expected.capacity || current.reservedSlots != expected.reservedSlots ||
		!current.holdUntil.Equal(expected.holdUntil) || current.holdDuration != expected.holdDuration ||
		current.longThreshold != expected.longThreshold {
		p.mu.Unlock()
		return false
	}
	if current.borrowPending {
		p.mu.Unlock()
		return true
	}
	current.borrowPending = true
	p.fastLanes[scaleSetID] = current
	p.mu.Unlock()
	p.persistFastLanes()
	return true
}

func (p *Poller) fastLanePreflight(ctx context.Context, pool supervisor.Pool, capacity int,
	now time.Time) (hold bool, borrow bool) {
	p.mu.Lock()
	state, active := p.fastLanes[pool.ScaleSetID]
	p.mu.Unlock()
	if !active {
		return false, false
	}
	if capacity < 2 || state.capacity != capacity {
		p.clearFastLane(pool.ScaleSetID)
		return false, false
	}
	if state.borrowPending {
		return false, true
	}
	if !now.Before(state.holdUntil) {
		if p.markFastLaneBorrowPending(pool.ScaleSetID, state) {
			return false, true
		}
		return false, false
	}
	lookupCtx, cancel := context.WithTimeout(ctx, acquirableLookupTimeout)
	jobs, err := p.cfg.API.GetAcquirableJobs(lookupCtx, pool.ScaleSetID)
	cancel()
	if err != nil {
		stateName := "error"
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(lookupCtx.Err(), context.DeadlineExceeded) {
			stateName = "timeout"
		}
		p.recordAcquirableHealth(pool.ScaleSetID, stateName, err)
		if p.markFastLaneBorrowPending(pool.ScaleSetID, state) {
			return false, true
		}
		return false, false
	}
	if len(jobs) == 0 {
		p.recordAcquirableHealth(pool.ScaleSetID, "empty", nil)
		p.clearFastLane(pool.ScaleSetID)
		return false, false
	}
	p.recordAcquirableHealth(pool.ScaleSetID, "healthy", nil)
	best := topCandidates(pool.ID, jobs, p.runtimeSnapshot(), now, 1)
	if len(best) == 0 || fastLaneEligible(best[0], state.longThreshold) {
		p.clearFastLane(pool.ScaleSetID)
		return false, false
	}
	return true, false
}

func (p *Poller) finishFastLane(scaleSetID int64, capacity int, decision admissionDecision, now time.Time) {
	switch {
	case decision.reserveFastLane:
		p.startFastLaneWithPolicy(scaleSetID, capacity, now, decision.policy)
	case decision.borrowFastLane:
		p.clearFastLane(scaleSetID)
	}
}

func exactAcquiredIDs(requested, acquired []int64) bool {
	if len(requested) == 0 || len(requested) != len(acquired) {
		return false
	}
	remaining := make(map[int64]struct{}, len(requested))
	for _, id := range requested {
		if id <= 0 {
			return false
		}
		remaining[id] = struct{}{}
	}
	if len(remaining) != len(requested) {
		return false
	}
	for _, id := range acquired {
		if _, ok := remaining[id]; !ok {
			return false
		}
		delete(remaining, id)
	}
	return len(remaining) == 0
}

func (p *Poller) acquire(ctx context.Context, scaleSetID int64, session crfgithub.Session,
	key journal.Key, selected []int64) error {
	result, err := p.cfg.API.AcquireJobs(ctx, session,
		crfgithub.AcquireRequest{RequestIDs: selected})
	if err != nil {
		return err
	}
	if !exactAcquiredIDs(selected, result.AcquiredIDs) {
		return p.resetAmbiguousAcquire(ctx, scaleSetID, key)
	}
	return nil
}

func (p *Poller) stabilizeFastLaneTuning(scaleSetID int64, target fastLanePolicy) fastLanePolicy {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.fastLaneTunings == nil {
		p.fastLaneTunings = map[int64]fastLanePolicy{}
	}
	current := p.fastLaneTunings[scaleSetID]
	tuned := stabilizeFastLanePolicy(current, target)
	p.fastLaneTunings[scaleSetID] = tuned
	return tuned
}

func (p *Poller) selectForAcquire(ctx context.Context, pool supervisor.Pool, batch crfgithub.MessageBatch,
	capacity int, borrowFastLane bool) admissionDecision {
	if capacity <= 0 || (batch.Statistics != nil && batch.Statistics.TotalAssignedJobs >= capacity) {
		return admissionDecision{borrowFastLane: borrowFastLane, policy: defaultFastLanePolicy()}
	}
	candidateBatch := p.acquisitionBatch(ctx, pool, batch)
	now := time.Now().UTC()
	runtimes := p.runtimeSnapshot()
	totalAvailable := len(candidateBatch.AvailableJobs)
	if candidateBatch.Statistics != nil && candidateBatch.Statistics.TotalAvailableJobs > totalAvailable {
		totalAvailable = candidateBatch.Statistics.TotalAvailableJobs
	}
	target := deriveFastLanePolicy(pool.ID, candidateBatch.AvailableJobs, runtimes, totalAvailable, capacity, now)
	policy := p.stabilizeFastLaneTuning(pool.ScaleSetID, target)
	return p.admissionSelectionWithRuntimes(candidateBatch, pool.ID, capacity, now,
		borrowFastLane, policy, runtimes)
}

func (p *Poller) Poll(ctx context.Context, pool supervisor.Pool, capacity int) (supervisor.PollResult, error) {
	lock := p.poolLock(pool.ScaleSetID)
	lock.Lock()
	defer lock.Unlock()
	pollCtx, cancel := context.WithCancel(ctx)
	p.mu.Lock()
	if p.pollCancels == nil {
		p.pollCancels = map[int64]context.CancelFunc{}
	}
	if p.pollActive == nil {
		p.pollActive = map[int64]int{}
	}
	p.pollCancels[pool.ScaleSetID] = cancel
	p.pollActive[pool.ScaleSetID]++
	p.mu.Unlock()
	defer func() {
		cancel()
		p.mu.Lock()
		delete(p.pollCancels, pool.ScaleSetID)
		p.pollActive[pool.ScaleSetID]--
		if p.pollActive[pool.ScaleSetID] == 0 {
			delete(p.pollActive, pool.ScaleSetID)
			prefix := fmt.Sprintf("%d:", pool.ScaleSetID)
			for key := range p.consumed {
				if strings.HasPrefix(key, prefix) {
					delete(p.consumed, key)
				}
			}
		}
		p.mu.Unlock()
	}()
	ctx = pollCtx
	if err := p.retryRejectedSession(ctx, pool.ScaleSetID); err != nil {
		return supervisor.PollResult{}, err
	}
	session, sessionIsNew, err := p.session(ctx, pool.ScaleSetID)
	if err != nil {
		return supervisor.PollResult{}, err
	}
	last := int64(0)
	p.mu.Lock()
	for key, entry := range p.replay {
		if key.ScaleSetID == pool.ScaleSetID && key.MessageID > last && entry.Phase == "acked" {
			last = key.MessageID
		}
	}
	p.mu.Unlock()
	advertisedKnown, advertisedChanged := p.advertisedState(pool.ScaleSetID, capacity)
	if advertisedChanged {
		p.clearFastLane(pool.ScaleSetID)
		p.commitSession(session, sessionIsNew)
		p.setAdvertised(pool.ScaleSetID, capacity)
		return p.result(pool.ScaleSetID, session.ID, capacity, last)
	}
	holdFastLane, borrowFastLane := p.fastLanePreflight(ctx, pool, capacity, time.Now().UTC())
	if holdFastLane {
		p.commitSession(session, sessionIsNew)
		if !advertisedKnown {
			p.setAdvertised(pool.ScaleSetID, capacity)
		}
		return p.result(pool.ScaleSetID, session.ID, capacity, last)
	}
	// Keep GitHub capacity honest. actions/scaleset defines X-ScaleSetMaxCapacity
	// as the scale set capacity the backend may rely on for assignment. Hidden
	// backlog is inspected through the separate admin acquirable-jobs endpoint;
	// never inflate this capacity header merely to manufacture lookahead.
	batch, err := p.cfg.API.GetMessage(ctx, session, last, capacity)
	if err != nil {
		p.commitSession(session, sessionIsNew)
		if !advertisedKnown {
			p.setAdvertised(pool.ScaleSetID, capacity)
		}
		return supervisor.PollResult{}, err
	}
	if batch.MessageID == 0 {
		p.commitSession(session, sessionIsNew)
		if !advertisedKnown {
			p.setAdvertised(pool.ScaleSetID, capacity)
		}
		return p.result(pool.ScaleSetID, session.ID, capacity, last)
	}
	if batch.Statistics == nil {
		return supervisor.PollResult{}, p.rejectSession(ctx, session, sessionIsNew,
			errors.New("message_statistics_required"))
	}
	if err := crfgithub.ValidateStatistics(batch.Statistics); err != nil {
		return supervisor.PollResult{}, p.rejectSession(ctx, session, sessionIsNew, err)
	}
	p.commitSession(session, sessionIsNew)
	if !advertisedKnown {
		p.setAdvertised(pool.ScaleSetID, capacity)
	}
	p.setAssigned(pool.ScaleSetID, batch.Statistics.TotalAssignedJobs)
	p.setDemand(pool.ScaleSetID,
		batch.Statistics.TotalAvailableJobs+batch.Statistics.TotalAssignedJobs)
	p.removePending(pool.ScaleSetID, batch.ReleasedHandles...)
	if p.assignedCount(pool.ScaleSetID) == 0 {
		p.clearPending(pool.ScaleSetID)
	}
	base := journal.Entry{ScaleSetID: pool.ScaleSetID, SessionID: session.ID,
		MessageID: batch.MessageID, AssignedCount: p.assignedCount(pool.ScaleSetID),
		AcquiredHandles: slices.Clone(batch.AssignedHandles),
		ConfigRevision:  p.cfg.ConfigRevision, OwnershipRevision: p.cfg.OwnershipRevision}
	p.mu.Lock()
	previous, ok := p.replay[journal.Key{ScaleSetID: pool.ScaleSetID, MessageID: batch.MessageID}]
	p.mu.Unlock()
	if ok {
		decision := admissionDecision{}
		if len(previous.AcquiredHandles) > 0 {
			base.AcquiredHandles = slices.Clone(previous.AcquiredHandles)
		}
		if previous.Phase == "acquire_started" && len(batch.AssignedHandles) == 0 {
			return supervisor.PollResult{}, p.resetAmbiguousAcquire(
				ctx, pool.ScaleSetID, previous.Key())
		}
		switch previous.Phase {
		case "received":
			base.Phase = "validated"
			if err := p.append(base); err != nil {
				return supervisor.PollResult{}, err
			}
			fallthrough
		case "validated":
			decision = p.selectForAcquire(ctx, pool, batch, capacity, borrowFastLane)
			selected := decision.requestIDs
			if len(selected) > 0 {
				base.Phase = "acquire_started"
				if err := p.append(base); err != nil {
					return supervisor.PollResult{}, err
				}
				if err := p.acquire(ctx, pool.ScaleSetID, session, base.Key(), selected); err != nil {
					return supervisor.PollResult{}, err
				}
				base.Phase = "acquire_observed"
				if err := p.append(base); err != nil {
					return supervisor.PollResult{}, err
				}
			}
			base.Phase = "committed"
			if err := p.append(base); err != nil {
				return supervisor.PollResult{}, err
			}
			p.appendPending(pool.ScaleSetID, base.AcquiredHandles...)
			fallthrough
		case "acquire_started":
			if previous.Phase == "acquire_started" {
				base.Phase = "acquire_observed"
				if err := p.append(base); err != nil {
					return supervisor.PollResult{}, err
				}
				base.Phase = "committed"
				if err := p.append(base); err != nil {
					return supervisor.PollResult{}, err
				}
				p.appendPending(pool.ScaleSetID, base.AcquiredHandles...)
			}
			fallthrough
		case "acquire_observed":
			if previous.Phase == "acquire_observed" {
				base.Phase = "committed"
				if err := p.append(base); err != nil {
					return supervisor.PollResult{}, err
				}
				p.appendPending(pool.ScaleSetID, base.AcquiredHandles...)
			}
			fallthrough
		case "committed", "ack_pending":
			if err := p.cfg.API.AcknowledgeMessage(ctx, session, batch.MessageID); err != nil {
				return supervisor.PollResult{}, err
			}
			// Runtime hints are optional optimization state. Learn only after GitHub
			// accepted the message acknowledgement so retries, ambiguous acquisition
			// resets, and redelivery cannot count one completion more than once.
			base.Phase = "acked"
			if err := p.append(base); err != nil {
				return supervisor.PollResult{}, err
			}
			p.observeCompleted(pool.ID, batch.CompletedJobs)
			p.finishFastLane(pool.ScaleSetID, capacity, decision, time.Now().UTC())
		case "acked":
		default:
			return supervisor.PollResult{}, ErrAmbiguousAcquire
		}
		p.appendPending(pool.ScaleSetID, base.AcquiredHandles...)
		return p.result(pool.ScaleSetID, session.ID, capacity, batch.MessageID)
	}
	base.Phase = "validated"
	if err := p.append(base); err != nil {
		return supervisor.PollResult{}, err
	}
	decision := p.selectForAcquire(ctx, pool, batch, capacity, borrowFastLane)
	selected := decision.requestIDs
	if len(selected) > 0 {
		base.Phase = "acquire_started"
		if err := p.append(base); err != nil {
			return supervisor.PollResult{}, err
		}
		if err := p.acquire(ctx, pool.ScaleSetID, session, base.Key(), selected); err != nil {
			return supervisor.PollResult{}, err
		}
		base.Phase = "acquire_observed"
		if err := p.append(base); err != nil {
			return supervisor.PollResult{}, err
		}
	}
	base.Phase = "committed"
	if err := p.append(base); err != nil {
		return supervisor.PollResult{}, err
	}
	p.appendPending(pool.ScaleSetID, base.AcquiredHandles...)
	if err := p.cfg.API.AcknowledgeMessage(ctx, session, batch.MessageID); err != nil {
		return supervisor.PollResult{}, err
	}
	base.Phase = "acked"
	if err := p.append(base); err != nil {
		return supervisor.PollResult{}, err
	}
	p.observeCompleted(pool.ID, batch.CompletedJobs)
	p.finishFastLane(pool.ScaleSetID, capacity, decision, time.Now().UTC())
	return p.result(pool.ScaleSetID, session.ID, capacity, batch.MessageID)
}

func (p *Poller) HasHandle(scaleSetID, handle int64) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Contains(p.pending[scaleSetID], handle)
}

func (p *Poller) ConsumeHandle(scaleSetID, handle int64) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	handles := p.pending[scaleSetID]
	idx := slices.Index(handles, handle)
	if idx < 0 {
		return false
	}
	p.pending[scaleSetID] = slices.Delete(handles, idx, idx+1)
	p.consumed[handleKey(scaleSetID, handle)] = true
	return true
}

// RetireHandle durably removes a terminal JIT handle from replay state before
// callers discard their issued-handle tombstone.
func (p *Poller) RetireHandle(scaleSetID, handle int64) error {
	// A GitHub message long-poll owns this pool's serialization lock. Cancel it
	// before waiting so terminal cleanup cannot stall admission for the entire
	// long-poll deadline.
	p.mu.Lock()
	cancel := p.pollCancels[scaleSetID]
	p.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	key := handleKey(scaleSetID, handle)
	p.mu.Lock()
	p.consumed[key] = true
	if idx := slices.Index(p.pending[scaleSetID], handle); idx >= 0 {
		p.pending[scaleSetID] = slices.Delete(p.pending[scaleSetID], idx, idx+1)
	}
	p.mu.Unlock()

	p.journalMu.Lock()
	if err := p.compactJournalLocked(); err != nil {
		p.journalMu.Unlock()
		return err
	}
	p.journalMu.Unlock()
	p.mu.Lock()
	if p.pollActive[scaleSetID] == 0 {
		delete(p.consumed, key)
	}
	p.mu.Unlock()
	return nil
}

func (p *Poller) Close(ctx context.Context) error {
	var first error
	if err := p.persistRuntimeHints(true); err != nil {
		first = err
	}
	p.mu.Lock()
	closer, ok := p.cfg.API.(sessionCloser)
	if !ok {
		p.mu.Unlock()
		return first
	}
	sessions := make(map[int64]crfgithub.Session, len(p.sessions)+len(p.rejectedSessions))
	for scaleSetID, active := range p.sessions {
		sessions[scaleSetID] = active
	}
	for scaleSetID, rejected := range p.rejectedSessions {
		if _, active := sessions[scaleSetID]; !active {
			sessions[scaleSetID] = rejected
		}
	}
	p.mu.Unlock()
	for scaleSetID, active := range sessions {
		if err := closer.CloseMessageSession(ctx, active); err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		p.mu.Lock()
		if p.sessions[scaleSetID] == active {
			delete(p.sessions, scaleSetID)
		}
		if p.rejectedSessions[scaleSetID] == active {
			delete(p.rejectedSessions, scaleSetID)
		}
		p.mu.Unlock()
	}
	return first
}
