package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/journal"
)

const (
	fastLaneStateSchemaVersion = 1
	maxFastLaneStateEntries    = 8
	maxFastLaneStateBytes      = 16 << 10
)

type fastLaneStateEntry struct {
	ScaleSetID     int64 `json:"scale_set_id"`
	Capacity       int   `json:"capacity"`
	HoldUntilMilli int64 `json:"hold_until_ms"`
	BorrowPending  bool  `json:"borrow_pending"`
}

type fastLaneStateFile struct {
	SchemaVersion int                  `json:"schema_version"`
	Entries       []fastLaneStateEntry `json:"entries"`
}

func fastLaneStatePath(store journal.Store) string {
	return filepath.Join(filepath.Dir(store.Path), "fast-lanes.json")
}

func loadFastLaneHints(store journal.Store) map[int64]fastLaneState {
	lanes, err := loadFastLaneState(fastLaneStatePath(store), time.Now().UTC())
	if err != nil {
		log.Printf("fast lane state unavailable, starting without reservations: %v", err)
		return map[int64]fastLaneState{}
	}
	return lanes
}

func loadFastLaneState(path string, now time.Time) (map[int64]fastLaneState, error) {
	out := map[int64]fastLaneState{}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return out, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > maxFastLaneStateBytes {
		return out, errors.New("invalid_fast_lane_state_file")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return out, err
	}
	var state fastLaneStateFile
	if err := json.Unmarshal(data, &state); err != nil {
		return out, err
	}
	if state.SchemaVersion != fastLaneStateSchemaVersion || len(state.Entries) > maxFastLaneStateEntries {
		return out, errors.New("invalid_fast_lane_state_schema")
	}
	latestAllowed := now.Add(fastLaneHoldDuration + time.Minute)
	for _, entry := range state.Entries {
		if entry.ScaleSetID <= 0 || entry.Capacity < 2 || entry.Capacity > 64 || entry.HoldUntilMilli <= 0 {
			return map[int64]fastLaneState{}, errors.New("invalid_fast_lane_state_entry")
		}
		if _, duplicate := out[entry.ScaleSetID]; duplicate {
			return map[int64]fastLaneState{}, errors.New("duplicate_fast_lane_state_entry")
		}
		holdUntil := time.UnixMilli(entry.HoldUntilMilli).UTC()
		if holdUntil.After(latestAllowed) {
			return map[int64]fastLaneState{}, errors.New("fast_lane_state_deadline_out_of_range")
		}
		lane := fastLaneState{capacity: entry.Capacity, holdUntil: holdUntil, borrowPending: entry.BorrowPending}
		if !lane.borrowPending && !now.Before(lane.holdUntil) {
			lane.borrowPending = true
		}
		out[entry.ScaleSetID] = lane
	}
	return out, nil
}

func saveFastLaneState(path string, lanes map[int64]fastLaneState) error {
	entries := make([]fastLaneStateEntry, 0, len(lanes))
	for scaleSetID, lane := range lanes {
		if scaleSetID <= 0 || lane.capacity < 2 || lane.capacity > 64 || lane.holdUntil.IsZero() {
			return errors.New("invalid_fast_lane_state_entry")
		}
		entries = append(entries, fastLaneStateEntry{
			ScaleSetID: scaleSetID, Capacity: lane.capacity, HoldUntilMilli: lane.holdUntil.UnixMilli(), BorrowPending: lane.borrowPending,
		})
	}
	if len(entries) > maxFastLaneStateEntries {
		return errors.New("fast_lane_state_capacity_exhausted")
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].ScaleSetID < entries[j].ScaleSetID })
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".fast-lanes.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := json.NewEncoder(tmp).Encode(fastLaneStateFile{SchemaVersion: fastLaneStateSchemaVersion, Entries: entries}); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	info, err := os.Lstat(name)
	if err != nil {
		return err
	}
	if info.Size() > maxFastLaneStateBytes {
		return fmt.Errorf("fast_lane_state_capacity_exhausted: %d", info.Size())
	}
	return os.Rename(name, path)
}

func (p *Poller) persistFastLaneSnapshotLocked() error {
	p.mu.Lock()
	snapshot := make(map[int64]fastLaneState, len(p.fastLanes))
	for scaleSetID, lane := range p.fastLanes {
		snapshot[scaleSetID] = lane
	}
	p.mu.Unlock()
	return saveFastLaneState(fastLaneStatePath(p.cfg.Store), snapshot)
}

func (p *Poller) persistFastLanes() {
	if p.cfg.Store.Path == "" {
		return
	}
	p.fastLanePersistMu.Lock()
	defer p.fastLanePersistMu.Unlock()
	if err := p.persistFastLaneSnapshotLocked(); err != nil {
		log.Printf("fast lane persistence failed: %v", err)
	}
}
