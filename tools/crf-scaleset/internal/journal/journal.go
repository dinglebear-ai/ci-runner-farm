package journal

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"time"
)

var phases = []string{"received", "validated", "acquire_started", "acquire_observed", "committed", "ack_pending", "acked"}

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

func (e Entry) Validate() error {
	if e.ScaleSetID <= 0 || e.MessageID < 0 || !slices.Contains(phases, e.Phase) {
		return errors.New("invalid_journal_entry")
	}
	if len(e.AcquiredHandles) > 64 || len(e.ConfigRevision) != 64 || len(e.OwnershipRevision) != 64 {
		return errors.New("invalid_journal_bounds")
	}
	return nil
}

type Store struct{ Path string }

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
	defer f.Close()
	if err := f.Chmod(0o600); err != nil {
		return err
	}
	e.UpdatedAt = time.Now().UTC()
	if err := json.NewEncoder(f).Encode(e); err != nil {
		return err
	}
	return f.Sync()
}

func (s Store) Replay() (map[int64]Entry, error) {
	out := map[int64]Entry{}
	f, err := os.Open(s.Path)
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
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
		out[e.MessageID] = e
	}
	return out, scan.Err()
}
