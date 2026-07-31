package controller

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sync"
	"time"

	crfgithub "github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/journal"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/ownership"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/session"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/supervisor"
)

var (
	identifier = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	revision   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	workFolder = regexp.MustCompile(`^[_A-Za-z0-9][_A-Za-z0-9.-]{0,63}$`)
	issuedKey  = regexp.MustCompile(`^[1-9][0-9]*:[1-9][0-9]*$`)
)

const maxIssuedHandles = 131072

type AuthConfig struct {
	Mode           string `json:"mode"`
	TokenFile      string `json:"token_file,omitempty"`
	AppClientID    string `json:"app_client_id,omitempty"`
	InstallationID int64  `json:"installation_id,omitempty"`
	PrivateKeyFile string `json:"private_key_file,omitempty"`
}

type PoolConfig struct {
	ID           string   `json:"id"`
	RoutingLabel string   `json:"routing_label"`
	Labels       []string `json:"labels"`
}

type RuntimeConfig struct {
	SchemaVersion           int          `json:"schema_version"`
	ControllerInstanceID    string       `json:"controller_instance_id"`
	ConfigRevision          string       `json:"config_revision"`
	OwnershipRevision       string       `json:"ownership_revision"`
	InstallationID          string       `json:"installation_id"`
	HostID                  string       `json:"host_id"`
	PluginDigest            string       `json:"plugin_digest"`
	ImageDigest             string       `json:"image_digest"`
	DockerfileDigest        string       `json:"dockerfile_digest"`
	EntrypointDigest        string       `json:"entrypoint_digest"`
	Owner                   string       `json:"owner"`
	GitHubConfigURL         string       `json:"github_config_url"`
	RunnerGroupID           int64        `json:"runner_group_id"`
	QuarantineRunnerGroupID int64        `json:"quarantine_runner_group_id"`
	StateDir                string       `json:"state_dir"`
	OwnershipPath           string       `json:"ownership_path"`
	HeartbeatSeconds        int          `json:"heartbeat_seconds"`
	Auth                    AuthConfig   `json:"auth"`
	Pools                   []PoolConfig `json:"pools"`
}

func (cfg RuntimeConfig) Validate() error {
	if cfg.SchemaVersion != 1 || !identifier.MatchString(cfg.ControllerInstanceID) ||
		!revision.MatchString(cfg.ConfigRevision) || !revision.MatchString(cfg.OwnershipRevision) ||
		!revision.MatchString(cfg.PluginDigest) || !revision.MatchString(cfg.ImageDigest) ||
		!revision.MatchString(cfg.DockerfileDigest) || !revision.MatchString(cfg.EntrypointDigest) ||
		!identifier.MatchString(cfg.InstallationID) || !identifier.MatchString(cfg.HostID) ||
		!identifier.MatchString(cfg.Owner) ||
		cfg.RunnerGroupID <= 0 || cfg.QuarantineRunnerGroupID <= 0 ||
		cfg.QuarantineRunnerGroupID == cfg.RunnerGroupID ||
		cfg.StateDir == "" || cfg.OwnershipPath == "" ||
		cfg.HeartbeatSeconds <= 0 || cfg.HeartbeatSeconds > 10 ||
		len(cfg.Pools) == 0 || len(cfg.Pools) > 8 {
		return errors.New("invalid_runtime_config")
	}
	seen := map[string]bool{}
	for _, pool := range cfg.Pools {
		if !identifier.MatchString(pool.ID) || !identifier.MatchString(pool.RoutingLabel) ||
			len(pool.Labels) == 0 || seen[pool.ID] {
			return errors.New("invalid_runtime_pool")
		}
		seen[pool.ID] = true
	}
	return nil
}

func LoadRuntimeConfig(path string) (RuntimeConfig, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return RuntimeConfig{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 256<<10 {
		return RuntimeConfig{}, errors.New("runtime_config_permissions_or_size")
	}
	file, err := os.Open(path)
	if err != nil {
		return RuntimeConfig{}, err
	}
	defer func() { _ = file.Close() }()
	dec := json.NewDecoder(file)
	dec.DisallowUnknownFields()
	var cfg RuntimeConfig
	if err := dec.Decode(&cfg); err != nil {
		return RuntimeConfig{}, err
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return RuntimeConfig{}, errors.New("runtime_config_trailing_data")
	}
	if err := cfg.Validate(); err != nil {
		return RuntimeConfig{}, err
	}
	return cfg, nil
}

type Control struct {
	cfg       RuntimeConfig
	api       crfgithub.ScaleSetAPI
	ownership *ownership.Manager
	mu        sync.Mutex
	poller    *session.Poller
	super     *supervisor.Supervisor
	cancel    context.CancelFunc
	superDone chan error
	issued    map[string]string
	lastSeq   uint64
}

func New(cfg RuntimeConfig, api crfgithub.ScaleSetAPI) (*Control, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	manager, err := ownership.New(ownership.Config{Path: cfg.OwnershipPath,
		InstallationID: cfg.InstallationID, Owner: cfg.Owner,
		ProductionRunnerGroupID: cfg.RunnerGroupID,
		QuarantineRunnerGroupID: cfg.QuarantineRunnerGroupID,
		ConfigRevision:          cfg.ConfigRevision, OwnershipRevision: cfg.OwnershipRevision}, api)
	if err != nil {
		return nil, err
	}
	control := &Control{cfg: cfg, api: api, ownership: manager, issued: map[string]string{}}
	if err := control.loadIssued(); err != nil {
		return nil, err
	}
	return control, nil
}

func (c *Control) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	_ = c.stopSessions(ctx)
	cancel()
}

func (c *Control) poolRecords() []ownership.Pool {
	out := make([]ownership.Pool, 0, len(c.cfg.Pools))
	for _, pool := range c.cfg.Pools {
		out = append(out, ownership.Pool{ID: pool.ID, RoutingLabel: pool.RoutingLabel,
			Labels: slices.Clone(pool.Labels)})
	}
	return out
}

func (c *Control) startSessions(records []ownership.Record) error {
	ctx, cancelStop := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancelStop()
	if err := c.stopSessions(ctx); err != nil {
		return err
	}
	consumed := make(map[string]bool, len(c.issued))
	for key, state := range c.issued {
		if state != "" {
			consumed[key] = true
		}
	}
	poller, err := session.New(session.Config{API: c.api,
		Store:          journal.Store{Path: filepath.Join(c.cfg.StateDir, "replay", "messages.jsonl")},
		ConfigRevision: c.cfg.ConfigRevision, OwnershipRevision: c.cfg.OwnershipRevision,
		ConsumedHandles: consumed})
	if err != nil {
		return err
	}
	pools := make([]supervisor.Pool, 0, len(c.cfg.Pools))
	for _, pool := range c.cfg.Pools {
		found := false
		for _, record := range records {
			if record.PoolID == pool.ID && record.ScaleSetID > 0 {
				pools = append(pools, supervisor.Pool{ID: pool.ID, ScaleSetID: record.ScaleSetID})
				found = true
				break
			}
		}
		if !found {
			return errors.New("owned_scale_set_missing")
		}
	}
	runner, err := supervisor.New(supervisor.Config{ControllerInstanceID: c.cfg.ControllerInstanceID,
		ConfigRevision: c.cfg.ConfigRevision, OwnershipRevision: c.cfg.OwnershipRevision,
		Pools: pools, Heartbeat: time.Duration(c.cfg.HeartbeatSeconds) * time.Second}, poller)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	c.poller, c.super, c.cancel, c.superDone = poller, runner, cancel, done
	go func() { done <- runner.Run(ctx) }()
	return nil
}

func (c *Control) stopSessions(ctx context.Context) error {
	// REVIEW(crf-v3q.13.12): Canceling a supervisor is not completion. Join it
	// before closing its sessions or installing a successor so long polls from
	// two generations can never overlap.
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
	if c.superDone != nil {
		select {
		case err := <-c.superDone:
			c.superDone = nil
			if err != nil {
				return fmt.Errorf("join_previous_supervisor: %w", err)
			}
		case <-ctx.Done():
			return fmt.Errorf("join_previous_supervisor: %w", ctx.Err())
		}
	}
	if c.poller != nil {
		if err := c.poller.Close(ctx); err != nil {
			return fmt.Errorf("close_previous_sessions: %w", err)
		}
	}
	c.poller, c.super = nil, nil
	return nil
}

func decodePayload(data []byte, target any) error {
	if len(data) == 0 {
		data = []byte(`{}`)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := dec.Decode(&trailing); err == nil {
		return errors.New("payload_trailing_data")
	}
	return nil
}

func response(req protocol.Request, result any) protocol.Response {
	return protocol.Response{SchemaVersion: protocol.SchemaVersion, RequestID: req.RequestID, OK: true, Result: result}
}

func failure(req protocol.Request, code string, err error) protocol.Response {
	message := code
	if err != nil {
		message = err.Error()
	}
	return protocol.Response{SchemaVersion: protocol.SchemaVersion, RequestID: req.RequestID,
		Code: code, Error: message}
}

func (c *Control) lock(ctx context.Context) bool {
	for {
		if c.mu.TryLock() {
			return true
		}
		timer := time.NewTimer(10 * time.Millisecond)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return false
		case <-timer.C:
		}
	}
}

func (c *Control) Handle(ctx context.Context, req protocol.Request) protocol.Response {
	if req.ConfigRevision != c.cfg.ConfigRevision ||
		req.OwnershipRevision != c.cfg.OwnershipRevision ||
		req.ControllerInstanceID != c.cfg.ControllerInstanceID {
		return failure(req, "identity_mismatch", nil)
	}
	if !c.lock(ctx) {
		return failure(req, "request_timeout", ctx.Err())
	}
	defer c.mu.Unlock()
	if req.Sequence <= c.lastSeq {
		return failure(req, "sequence_regression", nil)
	}
	c.lastSeq = req.Sequence
	switch req.Operation {
	case "apply_sessions":
		var payload struct {
			Eligible bool `json:"eligible"`
		}
		if err := decodePayload(req.Payload, &payload); err != nil {
			return failure(req, "invalid_sessions", err)
		}
		records, err := c.ownership.Reconcile(ctx, c.poolRecords(), payload.Eligible)
		if err != nil {
			return failure(req, "ownership_reconcile_failed", err)
		}
		if err := c.startSessions(records); err != nil {
			return failure(req, "session_start_failed", err)
		}
		return response(req, map[string]any{"records": records})
	case "publish_capacity_leases":
		var payload struct {
			Leases map[string]int `json:"leases"`
		}
		if err := decodePayload(req.Payload, &payload); err != nil {
			return failure(req, "invalid_leases", err)
		}
		if len(payload.Leases) > len(c.cfg.Pools) {
			return failure(req, "invalid_leases", nil)
		}
		valid := map[string]bool{}
		for _, pool := range c.cfg.Pools {
			valid[pool.ID] = true
		}
		for pool, capacity := range payload.Leases {
			if !valid[pool] || capacity < 0 || capacity > 64 {
				return failure(req, "invalid_leases", nil)
			}
		}
		if c.super == nil {
			return failure(req, "sessions_not_applied", nil)
		}
		c.super.SetLeases(payload.Leases)
		return response(req, map[string]bool{"applied": true})
	case "read_snapshot":
		if c.super == nil {
			return failure(req, "sessions_not_applied", nil)
		}
		return response(req, c.super.Snapshot())
	case "reconcile_owned":
		var payload struct {
			Eligible bool `json:"eligible"`
		}
		if err := decodePayload(req.Payload, &payload); err != nil {
			return failure(req, "invalid_reconcile", err)
		}
		records, err := c.ownership.Reconcile(ctx, c.poolRecords(), payload.Eligible)
		if err != nil {
			return failure(req, "ownership_reconcile_failed", err)
		}
		return response(req, map[string]any{"records": records, "eligible": payload.Eligible})
	case "issue_jit":
		var payload struct {
			PoolID     string `json:"pool_id"`
			WorkHandle int64  `json:"work_handle"`
			RunnerName string `json:"runner_name"`
			WorkFolder string `json:"work_folder"`
		}
		if err := decodePayload(req.Payload, &payload); err != nil ||
			!identifier.MatchString(payload.PoolID) || payload.WorkHandle <= 0 ||
			!identifier.MatchString(payload.RunnerName) || !workFolder.MatchString(payload.WorkFolder) {
			return failure(req, "invalid_jit_request", err)
		}
		if c.poller == nil {
			return failure(req, "sessions_not_applied", nil)
		}
		state, err := c.ownership.Load()
		if err != nil {
			return failure(req, "ownership_load_failed", err)
		}
		scaleSetID := int64(0)
		for _, record := range state.Records {
			if record.PoolID == payload.PoolID {
				scaleSetID = record.ScaleSetID
				break
			}
		}
		key := fmt.Sprintf("%d:%d", scaleSetID, payload.WorkHandle)
		if scaleSetID <= 0 || c.issued[key] != "" ||
			!c.poller.HasHandle(scaleSetID, payload.WorkHandle) {
			return failure(req, "work_handle_not_available", nil)
		}
		c.issued[key] = "issue_started"
		if err := c.writeIssued(); err != nil {
			delete(c.issued, key)
			return failure(req, "jit_state_failed", err)
		}
		if !c.poller.ConsumeHandle(scaleSetID, payload.WorkHandle) {
			return failure(req, "work_handle_not_available_after_reservation", nil)
		}
		descriptor, err := c.api.GenerateJitRunnerConfig(ctx, scaleSetID,
			crfgithub.JITRequest{Name: payload.RunnerName, WorkFolder: payload.WorkFolder})
		if err != nil {
			return failure(req, "jit_issue_ambiguous", err)
		}
		c.issued[key] = "issued"
		if err := c.writeIssued(); err != nil {
			return failure(req, "jit_state_failed", err)
		}
		return response(req, map[string]any{"descriptor": string(descriptor), "scale_set_id": scaleSetID})
	case "retire_jit":
		var payload struct {
			PoolID     string `json:"pool_id"`
			WorkHandle int64  `json:"work_handle"`
		}
		if err := decodePayload(req.Payload, &payload); err != nil ||
			!identifier.MatchString(payload.PoolID) || payload.WorkHandle <= 0 {
			return failure(req, "invalid_jit_retirement", err)
		}
		if c.poller == nil {
			return failure(req, "sessions_not_applied", nil)
		}
		state, err := c.ownership.Load()
		if err != nil {
			return failure(req, "ownership_load_failed", err)
		}
		scaleSetID := int64(0)
		for _, record := range state.Records {
			if record.PoolID == payload.PoolID {
				scaleSetID = record.ScaleSetID
				break
			}
		}
		key := fmt.Sprintf("%d:%d", scaleSetID, payload.WorkHandle)
		if scaleSetID <= 0 || c.issued[key] != "issued" {
			return failure(req, "work_handle_not_issued", nil)
		}
		// REVIEW(crf-v3q.13.10): Compact the durable replay proof before
		// removing the issued-handle tombstone. A crash at either boundary
		// leaves a conservative, replay-safe record instead of a reusable JIT.
		if err := c.poller.RetireHandle(scaleSetID, payload.WorkHandle); err != nil {
			return failure(req, "jit_retirement_failed", err)
		}
		delete(c.issued, key)
		if err := c.writeIssued(); err != nil {
			c.issued[key] = "issued"
			return failure(req, "jit_state_failed", err)
		}
		return response(req, map[string]bool{"retired": true})
	case "delete_owned":
		closeCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		if err := c.stopSessions(closeCtx); err != nil {
			cancel()
			return failure(req, "session_cleanup_failed", err)
		}
		cancel()
		if err := c.ownership.DeleteOwned(ctx); err != nil {
			return failure(req, "delete_owned_failed", err)
		}
		c.issued = map[string]string{}
		if err := c.writeIssued(); err != nil {
			return failure(req, "jit_state_cleanup_failed", err)
		}
		if err := os.RemoveAll(filepath.Join(c.cfg.StateDir, "replay")); err != nil {
			return failure(req, "journal_cleanup_failed", err)
		}
		return response(req, map[string]bool{"deleted": true})
	default:
		return failure(req, "unsupported_operation", nil)
	}
}

func (c *Control) issuedPath() string {
	return filepath.Join(c.cfg.StateDir, "issued-handles.json")
}

func (c *Control) loadIssued() error {
	info, err := os.Lstat(c.issuedPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 8<<20 {
		return errors.New("issued_state_permissions_or_size")
	}
	file, err := os.Open(c.issuedPath())
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	dec := json.NewDecoder(file)
	var issued map[string]string
	if err := dec.Decode(&issued); err != nil {
		return err
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("issued_state_trailing_data")
	}
	if len(issued) > maxIssuedHandles {
		return errors.New("issued_state_capacity_exhausted")
	}
	for key, state := range issued {
		if !issuedKey.MatchString(key) || (state != "issue_started" && state != "issued") {
			return errors.New("invalid_issued_state")
		}
	}
	c.issued = issued
	return nil
}

func (c *Control) writeIssued() error {
	if len(c.issued) > maxIssuedHandles {
		return errors.New("issued_state_capacity_exhausted")
	}
	if err := os.MkdirAll(c.cfg.StateDir, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(c.issued)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(c.cfg.StateDir, ".issued.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
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
	if err := os.Rename(name, c.issuedPath()); err != nil {
		return fmt.Errorf("persist issued handles: %w", err)
	}
	return nil
}
