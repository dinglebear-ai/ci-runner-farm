package session

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"slices"
	"sync"

	crfgithub "github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/journal"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/supervisor"
)

var ErrAmbiguousAcquire = errors.New("ambiguous_acquisition_requires_replay")

const maxJSONSafeInteger int64 = 1<<53 - 1

type Config struct {
	API               crfgithub.ScaleSetAPI
	Store             journal.Store
	ConfigRevision    string
	OwnershipRevision string
	ConsumedHandles   map[string]bool
}

type Poller struct {
	cfg        Config
	mu         sync.Mutex
	sessions   map[int64]crfgithub.Session
	assigned   map[int64]int
	advertised map[int64]int
	pending    map[int64][]int64
	replay     map[journal.Key]journal.Entry
	consumed   map[string]bool
	poolMu     map[int64]*sync.Mutex
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
	p := &Poller{cfg: cfg, sessions: map[int64]crfgithub.Session{}, assigned: map[int64]int{},
		advertised: map[int64]int{},
		pending:    map[int64][]int64{}, replay: replayed, consumed: map[string]bool{},
		poolMu: map[int64]*sync.Mutex{}}
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
	current := p.pendingSnapshot(scaleSetID)
	if len(current) >= capacity {
		return nil
	}
	handles := slices.Clone(current)
	for len(handles) < capacity {
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

func (p *Poller) result(scaleSetID int64, sessionID string, capacity int,
	messageID int64) (supervisor.PollResult, error) {
	if err := p.ensureCapacityHandles(scaleSetID, sessionID, capacity); err != nil {
		return supervisor.PollResult{}, err
	}
	return supervisor.PollResult{AssignedJobs: p.assignedCount(scaleSetID),
		MessageID: messageID, AcquiredHandles: p.pendingSnapshot(scaleSetID)}, nil
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

func (p *Poller) setAdvertised(scaleSetID int64, capacity int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.advertised[scaleSetID] = capacity
}

func (p *Poller) advertisedChanged(scaleSetID int64, capacity int) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	previous, known := p.advertised[scaleSetID]
	p.advertised[scaleSetID] = capacity
	return known && previous != capacity
}

func appendUnique(existing []int64, ids ...int64) []int64 {
	for _, id := range ids {
		if id > 0 && !slices.Contains(existing, id) {
			existing = append(existing, id)
		}
	}
	return existing
}

func (p *Poller) session(ctx context.Context, scaleSetID int64) (crfgithub.Session, error) {
	p.mu.Lock()
	if existing, ok := p.sessions[scaleSetID]; ok {
		p.mu.Unlock()
		return existing, nil
	}
	p.mu.Unlock()
	created, err := p.cfg.API.CreateMessageSession(ctx, scaleSetID)
	if err != nil {
		return crfgithub.Session{}, err
	}
	if created.ScaleSetID != scaleSetID || created.ID == "" {
		return crfgithub.Session{}, errors.New("invalid_message_session")
	}
	p.mu.Lock()
	p.sessions[scaleSetID] = created
	p.mu.Unlock()
	return created, nil
}

func (p *Poller) append(entry journal.Entry) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	size, err := p.cfg.Store.Size()
	if err != nil {
		return err
	}
	if size > journal.MaxJournalBytes-journal.MaxEntryBytes {
		if err := p.compactLocked(); err != nil {
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
	p.replay[entry.Key()] = entry
	size, err = p.cfg.Store.Size()
	if err != nil {
		return err
	}
	if size > journal.MaxJournalBytes {
		return p.compactLocked()
	}
	return nil
}

func (p *Poller) compactLocked() error {
	highestAcked := map[int64]journal.Key{}
	keep := map[journal.Key]journal.Entry{}
	for key, entry := range p.replay {
		if entry.Phase != "acked" {
			keep[key] = entry
			continue
		}
		for _, handle := range entry.AcquiredHandles {
			if !p.consumed[handleKey(entry.ScaleSetID, handle)] {
				keep[key] = entry
				break
			}
		}
		highest, ok := highestAcked[entry.ScaleSetID]
		if !ok || key.MessageID > highest.MessageID {
			highestAcked[entry.ScaleSetID] = key
		}
	}
	for _, key := range highestAcked {
		keep[key] = p.replay[key]
	}
	entries := make([]journal.Entry, 0, len(keep))
	for _, entry := range keep {
		entries = append(entries, entry)
	}
	if err := p.cfg.Store.Rewrite(entries); err != nil {
		return err
	}
	p.replay = keep
	return nil
}

func (p *Poller) Poll(ctx context.Context, pool supervisor.Pool, capacity int) (supervisor.PollResult, error) {
	lock := p.poolLock(pool.ScaleSetID)
	lock.Lock()
	defer lock.Unlock()
	session, err := p.session(ctx, pool.ScaleSetID)
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
	if p.advertisedChanged(pool.ScaleSetID, capacity) {
		return p.result(pool.ScaleSetID, session.ID, capacity, last)
	}
	batch, err := p.cfg.API.GetMessage(ctx, session, last, capacity)
	if err != nil {
		return supervisor.PollResult{}, err
	}
	if batch.MessageID == 0 {
		return p.result(pool.ScaleSetID, session.ID, capacity, last)
	}
	if batch.Statistics != nil {
		p.setAssigned(pool.ScaleSetID, batch.Statistics.TotalAssignedJobs)
	}
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
		if len(previous.AcquiredHandles) > 0 {
			base.AcquiredHandles = slices.Clone(previous.AcquiredHandles)
		}
		switch previous.Phase {
		case "received":
			base.Phase = "validated"
			if err := p.append(base); err != nil {
				return supervisor.PollResult{}, err
			}
			fallthrough
		case "validated":
			if len(batch.Available) > 0 {
				base.Phase = "acquire_started"
				if err := p.append(base); err != nil {
					return supervisor.PollResult{}, err
				}
				if _, err := p.cfg.API.AcquireJobs(ctx, session,
					crfgithub.AcquireRequest{RequestIDs: batch.Available}); err != nil {
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
			// Older builds incorrectly put direct JobAssigned notifications
			// into acquire_started. Once the adapter distinguishes message
			// kinds, an empty Available set proves no acquisition needs to be
			// repeated, so the durable assignment handles can be committed.
			if previous.Phase == "acquire_started" {
				if len(batch.Available) > 0 {
					return supervisor.PollResult{}, ErrAmbiguousAcquire
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
			base.Phase = "ack_pending"
			if err := p.append(base); err != nil {
				return supervisor.PollResult{}, err
			}
			if err := p.cfg.API.AcknowledgeMessage(ctx, session, batch.MessageID); err != nil {
				return supervisor.PollResult{}, err
			}
			base.Phase = "acked"
			if err := p.append(base); err != nil {
				return supervisor.PollResult{}, err
			}
		case "acked":
		default:
			return supervisor.PollResult{}, ErrAmbiguousAcquire
		}
		p.appendPending(pool.ScaleSetID, base.AcquiredHandles...)
		return p.result(pool.ScaleSetID, session.ID, capacity, batch.MessageID)
	}
	base.Phase = "received"
	if err := p.append(base); err != nil {
		return supervisor.PollResult{}, err
	}
	base.Phase = "validated"
	if err := p.append(base); err != nil {
		return supervisor.PollResult{}, err
	}
	if len(batch.Available) > 0 {
		base.Phase = "acquire_started"
		if err := p.append(base); err != nil {
			return supervisor.PollResult{}, err
		}
		if _, err := p.cfg.API.AcquireJobs(ctx, session,
			crfgithub.AcquireRequest{RequestIDs: batch.Available}); err != nil {
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
	base.Phase = "ack_pending"
	if err := p.append(base); err != nil {
		return supervisor.PollResult{}, err
	}
	if err := p.cfg.API.AcknowledgeMessage(ctx, session, batch.MessageID); err != nil {
		return supervisor.PollResult{}, err
	}
	base.Phase = "acked"
	if err := p.append(base); err != nil {
		return supervisor.PollResult{}, err
	}
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

func (p *Poller) Close(ctx context.Context) error {
	p.mu.Lock()
	closer, ok := p.cfg.API.(sessionCloser)
	if !ok {
		p.mu.Unlock()
		return nil
	}
	sessions := make([]crfgithub.Session, 0, len(p.sessions))
	for scaleSetID, active := range p.sessions {
		sessions = append(sessions, active)
		delete(p.sessions, scaleSetID)
	}
	p.mu.Unlock()
	var first error
	for _, active := range sessions {
		if err := closer.CloseMessageSession(ctx, active); err != nil && first == nil {
			first = err
		}
	}
	return first
}
