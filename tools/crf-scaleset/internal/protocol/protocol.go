package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"time"
)

const (
	SchemaVersion = 1
	MaxFrameBytes = 1 << 20
)

var (
	identifier = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	revision   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	operations = map[string]bool{
		"apply_sessions":          true,
		"publish_capacity_leases": true,
		"issue_jit":               true,
		"read_snapshot":           true,
		"reconcile_owned":         true,
		"delete_owned":            true,
	}
)

type Request struct {
	SchemaVersion        int             `json:"schema_version"`
	RequestID            string          `json:"request_id"`
	Operation            string          `json:"operation"`
	ConfigRevision       string          `json:"config_revision"`
	OwnershipRevision    string          `json:"ownership_revision"`
	ControllerInstanceID string          `json:"controller_instance_id"`
	Sequence             uint64          `json:"sequence"`
	Payload              json.RawMessage `json:"payload,omitempty"`
}

type Response struct {
	SchemaVersion int    `json:"schema_version"`
	RequestID     string `json:"request_id"`
	OK            bool   `json:"ok"`
	Code          string `json:"code,omitempty"`
	Error         string `json:"error,omitempty"`
	Result        any    `json:"result,omitempty"`
}

func (r Request) Validate() error {
	if r.SchemaVersion != SchemaVersion {
		return errors.New("schema_version")
	}
	if !identifier.MatchString(r.RequestID) || !identifier.MatchString(r.ControllerInstanceID) {
		return errors.New("identifier")
	}
	if !operations[r.Operation] {
		return errors.New("operation")
	}
	if !revision.MatchString(r.ConfigRevision) || !revision.MatchString(r.OwnershipRevision) {
		return errors.New("revision")
	}
	if len(r.Payload) > MaxFrameBytes/2 {
		return errors.New("payload_too_large")
	}
	return nil
}

func Decode(rd io.Reader) (Request, error) {
	data, err := io.ReadAll(io.LimitReader(rd, MaxFrameBytes+1))
	if err != nil {
		return Request{}, err
	}
	if len(data) > MaxFrameBytes {
		return Request{}, errors.New("frame_too_large")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var req Request
	if err := dec.Decode(&req); err != nil {
		return Request{}, fmt.Errorf("decode: %w", err)
	}
	if dec.More() {
		return Request{}, errors.New("trailing_data")
	}
	return req, req.Validate()
}

type PoolSnapshot struct {
	PoolID             string `json:"pool_id"`
	ScaleSetID         int64  `json:"scale_set_id"`
	AssignedJobs       int    `json:"assigned_jobs"`
	AdvertisedCapacity int    `json:"advertised_capacity"`
	LastMessageID      int64  `json:"last_message_id"`
	SessionHealthy     bool   `json:"session_healthy"`
}

type Snapshot struct {
	SchemaVersion        int            `json:"schema_version"`
	ControllerInstanceID string         `json:"controller_instance_id"`
	ConfigRevision       string         `json:"config_revision"`
	OwnershipRevision    string         `json:"ownership_revision"`
	Sequence             uint64         `json:"sequence"`
	ObservedAt           time.Time      `json:"observed_at"`
	ValidUntil           time.Time      `json:"valid_until"`
	Pools                []PoolSnapshot `json:"pools"`
}

func (s Snapshot) Validate(now time.Time) error {
	if s.SchemaVersion != SchemaVersion || !identifier.MatchString(s.ControllerInstanceID) {
		return errors.New("snapshot_identity")
	}
	if !revision.MatchString(s.ConfigRevision) || !revision.MatchString(s.OwnershipRevision) {
		return errors.New("snapshot_revision")
	}
	if s.ObservedAt.After(now.Add(5*time.Second)) || !s.ValidUntil.After(now) ||
		s.ValidUntil.Sub(s.ObservedAt) > 30*time.Second {
		return errors.New("snapshot_stale")
	}
	if len(s.Pools) > 8 {
		return errors.New("too_many_pools")
	}
	return nil
}
