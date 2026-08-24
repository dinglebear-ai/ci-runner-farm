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

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/journal"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/ownership"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/protocol"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/session"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/supervisor"
)

var (
	identifier = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	poolID     = regexp.MustCompile(`^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$`)
	label      = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$`)
	revision   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	workFolder = regexp.MustCompile(`^[_A-Za-z0-9][_A-Za-z0-9.-]{0,63}$`)
	issuedKey  = regexp.MustCompile(`^[1-9][0-9]*:[1-9][0-9]*$`)
)

const (
	maxIssuedHandles     = 131072
	maxJITDescriptorSize = 64 << 10
)

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
	seenPools := map[string]bool{}
	routingLabels := map[string]bool{}
	for _, pool := range cfg.Pools {
		if !poolID.MatchString(pool.ID) || !label.MatchString(pool.RoutingLabel) ||
			len(pool.Labels) == 0 || seenPools[pool.ID] || routingLabels[pool.RoutingLabel] {
			return errors.New("invalid_runtime_pool")
		}
		seenPools[pool.ID] = true
		routingLabels[pool.RoutingLabel] = true
	}
	for _, pool := range cfg.Pools {
		seenLabels := map[string]bool{}
		routingFound := false
		for _, candidate := range pool.Labels {
			if !label.MatchString(candidate) || seenLabels[candidate] ||
				(routingLabels[candidate] && candidate != pool.RoutingLabel) {
				return errors.New("invalid_runtime_pool_labels")
			}
			seenLabels[candidate] = true
			if candidate == pool.RoutingLabel {
				routingFound = true
			}
		}
		if !routingFound {
			return errors.New("runtime_routing_label_missing")
		}
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

type sessionPoller interface {
	supervisor.Poller
	HasHandle(int64, int64) bool
	ConsumeHandle(int64, int64) bool
	RetireHandle(int64, int64) error
	Close(context.Context) error
}

type Control struct {
	cfg       RuntimeConfig
	api       crfgithub.ScaleSetAPI
	ownership *ownership.Manager
	mu        sync.Mutex
	poller    sessionPoller
	super     *supervisor.Supervisor
	cancel    context.CancelFunc
	superDone chan error
	issued    map[string]issuedRecord
	retired   map[string]issuedRecord
	lastSeq   uint64
}

type issuedRecord struct {
	State             string `json:"state"`
	PoolID            string `json:"pool_id"`
	ScaleSetID        int64  `json:"scale_set_id"`
	OwnershipRevision string `json:"ownership_revision"`
	WorkHandle        int64  `json:"work_handle"`
	LegacyUnbound     bool   `json:"legacy_unbound,omitempty"`
}

type issuedDocument struct {
	SchemaVersion int                     `json:"schema_version"`
	Records       map[string]issuedRecord `json:"records"`
}

type retirementPayload struct {
	PoolID                    string `json:"pool_id"`
	ExpectedScaleSetID        int64  `json:"expected_scale_set_id"`
	ExpectedOwnershipRevision string `json:"expected_ownership_revision"`
	WorkHandle                int64  `json:"work_handle"`
}

func New(cfg RuntimeConfig, api crfgithub.ScaleSetAPI) (*Control, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if api == nil {
		return nil, errors.New("scale_set_api_required")
	}
	cfg.Pools = slices.Clone(cfg.Pools)
	for i := range cfg.Pools {
		cfg.Pools[i].Labels = slices.Clone(cfg.Pools[i].Labels)
	}
	manager, err := ownership.New(ownership.Config{Path: cfg.OwnershipPath,
		InstallationID: cfg.InstallationID, Owner: cfg.Owner,
		ProductionRunnerGroupID: cfg.RunnerGroupID,
		QuarantineRunnerGroupID: cfg.QuarantineRunnerGroupID,
		ConfigRevision:          cfg.ConfigRevision, OwnershipRevision: cfg.OwnershipRevision}, api)
	if err != nil {
		return nil, err
	}
	control := &Control{cfg: cfg, api: api, ownership: manager,
		issued: map[string]issuedRecord{}, retired: map[string]issuedRecord{}}
	if err := control.loadIssued(); err != nil {
		return nil, err
	}
	if err := control.loadRetired(); err != nil {
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
	for key, record := range c.issued {
		if record.State != "" {
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
	var joinErr error
	if c.superDone != nil {
		select {
		case err := <-c.superDone:
			c.superDone = nil
			c.super = nil
			if err != nil {
				joinErr = fmt.Errorf("join_previous_supervisor: %w", err)
			}
		case <-ctx.Done():
			return fmt.Errorf("join_previous_supervisor: %w", ctx.Err())
		}
	}
	if c.poller != nil {
		if err := c.poller.Close(ctx); err != nil {
			return errors.Join(joinErr, fmt.Errorf("close_previous_sessions: %w", err))
		}
		c.poller = nil
	}
	c.super = nil
	return joinErr
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
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
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
		if err := c.super.SetLeases(payload.Leases); err != nil {
			return failure(req, "invalid_leases", err)
		}
		return response(req, map[string]bool{"applied": true})
	case "read_snapshot":
		if c.super == nil {
			return failure(req, "sessions_not_applied", nil)
		}
		return response(req, c.super.Snapshot())
	case "read_jit_state":
		states := make([]protocol.JITState, 0, len(c.issued))
		for key, record := range c.issued {
			var scaleSetID, workHandle int64
			if _, err := fmt.Sscanf(key, "%d:%d", &scaleSetID, &workHandle); err != nil ||
				scaleSetID <= 0 || workHandle <= 0 {
				return failure(req, "invalid_issued_state", err)
			}
			pool := record.PoolID
			_, descriptorErr := c.readJITDescriptor(scaleSetID, workHandle)
			states = append(states, protocol.JITState{PoolID: pool, ScaleSetID: scaleSetID,
				WorkHandle: workHandle, State: record.State, DescriptorAvailable: descriptorErr == nil})
		}
		slices.SortFunc(states, func(a, b protocol.JITState) int {
			if a.ScaleSetID < b.ScaleSetID {
				return -1
			}
			if a.ScaleSetID > b.ScaleSetID {
				return 1
			}
			if a.WorkHandle < b.WorkHandle {
				return -1
			}
			if a.WorkHandle > b.WorkHandle {
				return 1
			}
			return 0
		})
		return response(req, map[string]any{"states": states})
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
			PoolID                    string `json:"pool_id"`
			ExpectedScaleSetID        int64  `json:"expected_scale_set_id"`
			ExpectedOwnershipRevision string `json:"expected_ownership_revision"`
			WorkHandle                int64  `json:"work_handle"`
			RunnerName                string `json:"runner_name"`
			WorkFolder                string `json:"work_folder"`
		}
		if err := decodePayload(req.Payload, &payload); err != nil ||
			!identifier.MatchString(payload.PoolID) || payload.ExpectedScaleSetID <= 0 ||
			!revision.MatchString(payload.ExpectedOwnershipRevision) || payload.WorkHandle <= 0 ||
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
		if payload.ExpectedOwnershipRevision != state.IdentityRevision {
			return failure(req, "ownership_identity_mismatch", nil)
		}
		scaleSetID := int64(0)
		for _, record := range state.Records {
			if record.PoolID == payload.PoolID {
				scaleSetID = record.ScaleSetID
				break
			}
		}
		key := fmt.Sprintf("%d:%d", scaleSetID, payload.WorkHandle)
		if scaleSetID <= 0 {
			return failure(req, "work_handle_not_available", nil)
		}
		if scaleSetID != payload.ExpectedScaleSetID {
			return failure(req, "scale_set_mismatch", nil)
		}
		if record, ok := c.issued[key]; ok {
			descriptor, descriptorErr := c.readJITDescriptor(scaleSetID, payload.WorkHandle)
			switch record.State {
			case "issued":
				if descriptorErr != nil {
					return failure(req, "jit_descriptor_unavailable", descriptorErr)
				}
				return response(req, map[string]any{"descriptor": string(descriptor), "scale_set_id": scaleSetID})
			case "issue_started":
				if descriptorErr != nil {
					return failure(req, "jit_issue_ambiguous", descriptorErr)
				}
				record.State = "issued"
				c.issued[key] = record
				if err := c.writeIssued(); err != nil {
					record.State = "issue_started"
					c.issued[key] = record
					return failure(req, "jit_state_failed", err)
				}
				return response(req, map[string]any{"descriptor": string(descriptor), "scale_set_id": scaleSetID})
			default:
				return failure(req, "invalid_issued_state", nil)
			}
		}
		if !c.poller.HasHandle(scaleSetID, payload.WorkHandle) {
			return failure(req, "work_handle_not_available", nil)
		}
		c.issued[key] = issuedRecord{State: "issue_started", PoolID: payload.PoolID,
			ScaleSetID: scaleSetID, OwnershipRevision: payload.ExpectedOwnershipRevision,
			WorkHandle: payload.WorkHandle}
		if err := c.writeIssued(); err != nil {
			delete(c.issued, key)
			return failure(req, "jit_state_failed", err)
		}
		if !c.poller.ConsumeHandle(scaleSetID, payload.WorkHandle) {
			if err := c.removeIssued(key); err != nil {
				return failure(req, "jit_state_failed", err)
			}
			return failure(req, "work_handle_not_available_after_reservation", nil)
		}
		descriptor, err := c.api.GenerateJitRunnerConfig(ctx, scaleSetID,
			crfgithub.JITRequest{Name: payload.RunnerName, WorkFolder: payload.WorkFolder})
		if err != nil {
			return failure(req, "jit_issue_ambiguous", err)
		}
		if err := c.writeJITDescriptor(scaleSetID, payload.WorkHandle, descriptor); err != nil {
			return failure(req, "jit_state_failed", err)
		}
		record := c.issued[key]
		record.State = "issued"
		c.issued[key] = record
		if err := c.writeIssued(); err != nil {
			record.State = "issue_started"
			c.issued[key] = record
			return failure(req, "jit_state_failed", err)
		}
		return response(req, map[string]any{"descriptor": string(descriptor), "scale_set_id": scaleSetID})
	case "retire_jit":
		var payload retirementPayload
		if err := decodePayload(req.Payload, &payload); err != nil ||
			!identifier.MatchString(payload.PoolID) || payload.ExpectedScaleSetID <= 0 ||
			!revision.MatchString(payload.ExpectedOwnershipRevision) || payload.WorkHandle <= 0 {
			return failure(req, "invalid_jit_retirement", err)
		}
		key := fmt.Sprintf("%d:%d", payload.ExpectedScaleSetID, payload.WorkHandle)
		record, issued := c.issued[key]
		if !issued {
			if retired, ok := c.retired[key]; ok && sameRetirement(retired, payload.PoolID,
				payload.ExpectedScaleSetID, payload.ExpectedOwnershipRevision, payload.WorkHandle) {
				return response(req, map[string]bool{"retired": true})
			}
			state, err := c.ownership.Load()
			if err != nil {
				return failure(req, "ownership_load_failed", err)
			}
			if payload.ExpectedOwnershipRevision != state.IdentityRevision {
				return failure(req, "ownership_identity_mismatch", nil)
			}
			for _, owned := range state.Records {
				if owned.PoolID == payload.PoolID && owned.ScaleSetID == payload.ExpectedScaleSetID {
					return response(req, map[string]bool{"retired": true})
				}
			}
			return failure(req, "scale_set_mismatch", nil)
		}
		if !sameRetirement(record, payload.PoolID, payload.ExpectedScaleSetID,
			payload.ExpectedOwnershipRevision, payload.WorkHandle) {
			if record.LegacyUnbound && record.PoolID == payload.PoolID &&
				record.ScaleSetID == payload.ExpectedScaleSetID && record.WorkHandle == payload.WorkHandle {
				previous := record
				record.OwnershipRevision = payload.ExpectedOwnershipRevision
				record.LegacyUnbound = false
				c.issued[key] = record
				if err := c.writeIssued(); err != nil {
					c.issued[key] = previous
					return failure(req, "jit_state_failed", err)
				}
			} else {
				if record.OwnershipRevision != payload.ExpectedOwnershipRevision {
					return failure(req, "ownership_identity_mismatch", nil)
				}
				return failure(req, "retirement_fence_mismatch", nil)
			}
		}
		if record.State != "issued" && record.State != "issue_started" {
			return failure(req, "invalid_issued_state", nil)
		}
		if c.poller == nil {
			return failure(req, "sessions_not_applied", nil)
		}
		if err := c.persistRetired(key, record); err != nil {
			return failure(req, "jit_state_failed", err)
		}
		// REVIEW(crf-v3q.13.10): Compact the durable replay proof before
		// removing the issued-handle tombstone. A crash at either boundary
		// leaves a conservative, replay-safe record instead of a reusable JIT.
		if err := c.poller.RetireHandle(record.ScaleSetID, payload.WorkHandle); err != nil {
			return failure(req, "jit_retirement_failed", err)
		}
		if err := c.removeJITDescriptor(record.ScaleSetID, payload.WorkHandle); err != nil {
			return failure(req, "jit_state_failed", err)
		}
		if err := c.removeIssued(key); err != nil {
			return failure(req, "jit_state_failed", err)
		}
		return response(req, map[string]bool{"retired": true})
	case "confirm_jit_retirement":
		var payload retirementPayload
		if err := decodePayload(req.Payload, &payload); err != nil ||
			!identifier.MatchString(payload.PoolID) || payload.ExpectedScaleSetID <= 0 ||
			!revision.MatchString(payload.ExpectedOwnershipRevision) || payload.WorkHandle <= 0 {
			return failure(req, "invalid_jit_retirement_confirmation", err)
		}
		key := fmt.Sprintf("%d:%d", payload.ExpectedScaleSetID, payload.WorkHandle)
		proof, ok := c.retired[key]
		if !ok {
			return response(req, map[string]bool{"confirmed": true})
		}
		if !sameRetirement(proof, payload.PoolID, payload.ExpectedScaleSetID,
			payload.ExpectedOwnershipRevision, payload.WorkHandle) {
			return failure(req, "retirement_fence_mismatch", nil)
		}
		delete(c.retired, key)
		if err := writeRecordState(c.retiredPath(), c.retired); err != nil {
			c.retired[key] = proof
			return failure(req, "jit_state_failed", err)
		}
		return response(req, map[string]bool{"confirmed": true})
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
		c.issued = map[string]issuedRecord{}
		c.retired = map[string]issuedRecord{}
		if err := c.writeIssued(); err != nil {
			return failure(req, "jit_state_cleanup_failed", err)
		}
		if err := writeRecordState(c.retiredPath(), c.retired); err != nil {
			return failure(req, "jit_state_cleanup_failed", err)
		}
		if err := os.RemoveAll(c.descriptorDir()); err != nil {
			return failure(req, "jit_descriptor_cleanup_failed", err)
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

func (c *Control) retiredPath() string {
	return filepath.Join(c.cfg.StateDir, "retired-handles.json")
}

func sameRetirement(record issuedRecord, pool string, scaleSetID int64, revision string, handle int64) bool {
	return record.PoolID == pool && record.ScaleSetID == scaleSetID &&
		record.OwnershipRevision == revision && record.WorkHandle == handle
}

func (c *Control) descriptorDir() string {
	return filepath.Join(c.cfg.StateDir, "jit-descriptors")
}

func (c *Control) descriptorPath(scaleSetID, workHandle int64) string {
	return filepath.Join(c.descriptorDir(), fmt.Sprintf("%d-%d.jit", scaleSetID, workHandle))
}

func validJITDescriptor(descriptor []byte) bool {
	if len(descriptor) == 0 || len(descriptor) > maxJITDescriptorSize {
		return false
	}
	for _, b := range descriptor {
		if (b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') ||
			b == '.' || b == '_' || b == '+' || b == '/' || b == '=' || b == ':' || b == '-' {
			continue
		}
		return false
	}
	return true
}

func (c *Control) writeJITDescriptor(scaleSetID, workHandle int64, descriptor []byte) error {
	if scaleSetID <= 0 || workHandle <= 0 || !validJITDescriptor(descriptor) {
		return errors.New("invalid_jit_descriptor")
	}
	dir := c.descriptorDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".jit.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(descriptor); err != nil {
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
	if err := os.Rename(name, c.descriptorPath(scaleSetID, workHandle)); err != nil {
		return fmt.Errorf("persist JIT descriptor: %w", err)
	}
	return syncDirectory(dir)
}

func (c *Control) readJITDescriptor(scaleSetID, workHandle int64) ([]byte, error) {
	path := c.descriptorPath(scaleSetID, workHandle)
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() <= 0 || info.Size() > maxJITDescriptorSize {
		return nil, errors.New("jit_descriptor_permissions_or_size")
	}
	descriptor, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if !validJITDescriptor(descriptor) {
		return nil, errors.New("invalid_jit_descriptor")
	}
	return descriptor, nil
}

func (c *Control) removeJITDescriptor(scaleSetID, workHandle int64) error {
	path := c.descriptorPath(scaleSetID, workHandle)
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if _, err := os.Stat(c.descriptorDir()); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	return syncDirectory(c.descriptorDir())
}

func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = dir.Close() }()
	return dir.Sync()
}

func (c *Control) loadIssued() error {
	data, err := readPrivateState(c.issuedPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var document issuedDocument
	if err := decodeExact(data, &document); err == nil && document.SchemaVersion == 2 {
		if err := validateIssuedRecords(document.Records, false); err != nil {
			return err
		}
		c.issued = document.Records
		return nil
	}
	var legacy map[string]string
	if err := decodeExact(data, &legacy); err != nil {
		return errors.New("invalid_issued_state")
	}
	owned, err := c.ownership.Load()
	if err != nil {
		return errors.New("legacy_issued_identity_mismatch")
	}
	records := make(map[string]issuedRecord, len(legacy))
	for key, state := range legacy {
		var scaleSetID, handle int64
		if _, err := fmt.Sscanf(key, "%d:%d", &scaleSetID, &handle); err != nil {
			return errors.New("invalid_issued_state")
		}
		pool := ""
		for _, candidate := range owned.Records {
			if candidate.ScaleSetID == scaleSetID {
				if pool != "" {
					return errors.New("ambiguous_legacy_issued_state")
				}
				pool = candidate.PoolID
			}
		}
		if pool == "" {
			return errors.New("unbound_legacy_issued_state")
		}
		records[key] = issuedRecord{State: state, PoolID: pool, ScaleSetID: scaleSetID,
			WorkHandle: handle, LegacyUnbound: true}
	}
	if err := validateIssuedRecords(records, false); err != nil {
		return err
	}
	c.issued = records
	return c.writeIssued()
}

func (c *Control) loadRetired() error {
	data, err := readPrivateState(c.retiredPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var document issuedDocument
	if err := decodeExact(data, &document); err != nil || document.SchemaVersion != 2 {
		return errors.New("invalid_retired_state")
	}
	if err := validateIssuedRecords(document.Records, true); err != nil {
		return err
	}
	c.retired = document.Records
	return nil
}

func readPrivateState(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 8<<20 {
		return nil, errors.New("jit_state_permissions_or_size")
	}
	return os.ReadFile(path)
}

func decodeExact(data []byte, target any) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("jit_state_trailing_data")
	}
	return nil
}

func validateIssuedRecords(records map[string]issuedRecord, _retired bool) error {
	if len(records) > maxIssuedHandles {
		return errors.New("issued_state_capacity_exhausted")
	}
	for key, record := range records {
		expected := fmt.Sprintf("%d:%d", record.ScaleSetID, record.WorkHandle)
		if !issuedKey.MatchString(key) || key != expected ||
			(record.State != "issue_started" && record.State != "issued") ||
			!identifier.MatchString(record.PoolID) || record.ScaleSetID <= 0 || record.WorkHandle <= 0 ||
			(record.LegacyUnbound && record.OwnershipRevision != "") ||
			(!record.LegacyUnbound && !revision.MatchString(record.OwnershipRevision)) {
			return errors.New("invalid_issued_state")
		}
	}
	return nil
}

func (c *Control) removeIssued(key string) error {
	state, ok := c.issued[key]
	if !ok {
		return nil
	}
	delete(c.issued, key)
	if err := c.writeIssued(); err != nil {
		c.issued[key] = state
		return err
	}
	return nil
}

func (c *Control) writeIssued() error {
	return writeRecordState(c.issuedPath(), c.issued)
}

func (c *Control) persistRetired(key string, record issuedRecord) error {
	if existing, ok := c.retired[key]; ok {
		if existing != record {
			return errors.New("retired_state_conflict")
		}
		return nil
	}
	if len(c.retired) >= maxIssuedHandles {
		return errors.New("retired_state_capacity_exhausted")
	}
	c.retired[key] = record
	if err := writeRecordState(c.retiredPath(), c.retired); err != nil {
		delete(c.retired, key)
		return err
	}
	return nil
}

func writeRecordState(path string, records map[string]issuedRecord) error {
	if err := validateIssuedRecords(records, path != filepath.Join(filepath.Dir(path), "issued-handles.json")); err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(issuedDocument{SchemaVersion: 2, Records: records})
	if err != nil {
		return err
	}
	if len(data)+1 > 8<<20 {
		return errors.New("jit_state_encoded_size_exceeded")
	}
	tmp, err := os.CreateTemp(dir, ".jit-state.*")
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
	if err := os.Rename(name, path); err != nil {
		return fmt.Errorf("persist issued handles: %w", err)
	}
	return syncDirectory(dir)
}
