package journal

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"time"

	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/durable"
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
	f, err := os.OpenFile(s.Path, os.O_RDWR, 0)
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	data, err := io.ReadAll(io.LimitReader(f, MaxJournalBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > MaxJournalBytes {
		return nil, errors.New("journal_capacity_exhausted")
	}
	completeEnd := len(data)
	if len(data) > 0 && data[len(data)-1] != '\n' {
		completeEnd = bytes.LastIndexByte(data, '\n') + 1
	}
	lines := bytes.Split(data[:completeEnd], []byte{'\n'})
	for index, line := range lines {
		if len(line) == 0 && index == len(lines)-1 {
			continue
		}
		var e Entry
		if err := json.Unmarshal(line, &e); err != nil {
			return nil, fmt.Errorf("journal corruption at line %d: %w", index+1, err)
		}
		if err := e.Validate(); err != nil {
			return nil, err
		}
		out[e.Key()] = e
	}
	if completeEnd < len(data) {
		var final Entry
		if err := json.Unmarshal(data[completeEnd:], &final); err == nil {
			if err := final.Validate(); err != nil {
				return nil, err
			}
			out[final.Key()] = final
		} else {
			if err := f.Truncate(int64(completeEnd)); err != nil {
				return nil, err
			}
			if err := f.Sync(); err != nil {
				return nil, err
			}
		}
	}
	return out, nil
}

// Rewrite atomically compacts the journal to one durable entry per replay key.
// Callers decide which entries remain necessary for replay safety.
func (s Store) Rewrite(entries []Entry) error {
	ordered := slices.Clone(entries)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].ScaleSetID != ordered[j].ScaleSetID {
			return ordered[i].ScaleSetID < ordered[j].ScaleSetID
		}
		return ordered[i].MessageID < ordered[j].MessageID
	})
	err := durable.Replace(s.Path, ".journal.*", 0o600, MaxJournalBytes, func(w io.Writer) error {
		encoder := json.NewEncoder(w)
		for _, entry := range ordered {
			if err := entry.Validate(); err != nil {
				return err
			}
			entry.UpdatedAt = time.Now().UTC()
			if err := encoder.Encode(entry); err != nil {
				return err
			}
		}
		return nil
	})
	if errors.Is(err, durable.ErrCapacityExceeded) {
		return errors.New("journal_capacity_exhausted")
	}
	return err
}
