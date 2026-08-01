package journal

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"time"
)

var phases = []string{"received", "validated", "acquire_started", "acquire_observed", "committed", "ack_pending", "acked"}

const (
	MaxJournalBytes int64 = 8 << 20
	MaxEntryBytes         = 64 << 10
)

type Entry struct {
	ScaleSetID        int64     `json:"scale_set_id"`
	SessionID         string    `json:"session_id"`
	MessageID         int64     `json:"message_id"`
	Phase             string    `json:"phase"`
	AssignedCount     int       `json:"assigned_count"`
	AcquiredHandles   []int64   `json:"acquired_handles"`
	ConfigRevision    string    `json:"config_revision"`
	OwnershipRevision string    `json:"ownership_revision"`
	UpdatedAt         time.Time `json:"updated_at"`
}

type Key struct {
	ScaleSetID int64
	MessageID  int64
}

func (e Entry) Key() Key {
	return Key{ScaleSetID: e.ScaleSetID, MessageID: e.MessageID}
}

func (e Entry) Validate() error {
	if e.ScaleSetID <= 0 || e.MessageID < 0 || e.AssignedCount < 0 ||
		e.AssignedCount > 1_000_000 || len(e.SessionID) > 4096 ||
		!slices.Contains(phases, e.Phase) {
		return errors.New("invalid_journal_entry")
	}
	if len(e.AcquiredHandles) > 64 || len(e.ConfigRevision) != 64 || len(e.OwnershipRevision) != 64 {
		return errors.New("invalid_journal_bounds")
	}
	seen := make(map[int64]bool, len(e.AcquiredHandles))
	for _, handle := range e.AcquiredHandles {
		if handle <= 0 || seen[handle] {
			return errors.New("invalid_journal_handle")
		}
		seen[handle] = true
	}
	if data, err := json.Marshal(e); err != nil || len(data) > MaxEntryBytes {
		return errors.New("journal_entry_capacity_exhausted")
	}
	return nil
}

type Store struct{ Path string }

func (s Store) Size() (int64, error) {
	info, err := os.Lstat(s.Path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return 0, errors.New("journal_permissions")
	}
	return info.Size(), nil
}

func (s Store) Append(e Entry) error {
	if err := e.Validate(); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.Path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(s.Path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	if err := f.Chmod(0o600); err != nil {
		return err
	}
	e.UpdatedAt = time.Now().UTC()
	if err := json.NewEncoder(f).Encode(e); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	return f.Close()
}

func (s Store) Replay() (map[Key]Entry, error) {
	out := map[Key]Entry{}
	size, err := s.Size()
	if err != nil {
		return nil, err
	}
	if size > MaxJournalBytes {
		return nil, errors.New("journal_capacity_exhausted")
	}
	f, err := os.Open(s.Path)
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	scan := bufio.NewScanner(f)
	scan.Buffer(make([]byte, 4096), 1<<20)
	for scan.Scan() {
		var e Entry
		if err := json.Unmarshal(scan.Bytes(), &e); err != nil {
			return nil, err
		}
		if err := e.Validate(); err != nil {
			return nil, err
		}
		out[e.Key()] = e
	}
	return out, scan.Err()
}

// Rewrite atomically compacts the journal to one durable entry per replay key.
// Callers decide which entries remain necessary for replay safety.
func (s Store) Rewrite(entries []Entry) error {
	if err := os.MkdirAll(filepath.Dir(s.Path), 0o700); err != nil {
		return err
	}
	ordered := slices.Clone(entries)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].ScaleSetID != ordered[j].ScaleSetID {
			return ordered[i].ScaleSetID < ordered[j].ScaleSetID
		}
		return ordered[i].MessageID < ordered[j].MessageID
	})
	tmp, err := os.CreateTemp(filepath.Dir(s.Path), ".journal.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	encoder := json.NewEncoder(tmp)
	for _, entry := range ordered {
		if err := entry.Validate(); err != nil {
			_ = tmp.Close()
			return err
		}
		entry.UpdatedAt = time.Now().UTC()
		if err := encoder.Encode(entry); err != nil {
			_ = tmp.Close()
			return err
		}
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, s.Path); err != nil {
		return err
	}
	size, err := s.Size()
	if err != nil {
		return err
	}
	if size > MaxJournalBytes {
		return errors.New("journal_capacity_exhausted")
	}
	return nil
}
