package ownership

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/durable"
	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
)

var (
	identity = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	revision = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

var recordStates = []string{
	"creating",
	"create_ambiguous",
	"ineligible",
	"eligible",
	"update_pending",
	"orphan_create_ambiguous",
	"orphan_ineligible",
	"delete_pending",
}

type Config struct {
	Path                    string
	InstallationID          string
	Owner                   string
	ProductionRunnerGroupID int64
	QuarantineRunnerGroupID int64
	ConfigRevision          string
	OwnershipRevision       string
}

type Pool struct {
	ID           string   `json:"id"`
	RoutingLabel string   `json:"routing_label"`
	Labels       []string `json:"labels"`
}

type Record struct {
	PoolID               string   `json:"pool_id"`
	RemoteName           string   `json:"remote_name"`
	ScaleSetID           int64    `json:"scale_set_id"`
	RunnerGroupID        int64    `json:"runner_group_id"`
	ConfiguredLabels     []string `json:"configured_labels"`
	AppliedLabels        []string `json:"applied_labels"`
	RemoteSpecRevision   string   `json:"remote_spec_revision"`
	State                string   `json:"state"`
	PendingRunnerGroupID int64    `json:"pending_runner_group_id,omitempty"`
	PendingAppliedLabels []string `json:"pending_applied_labels,omitempty"`
	PendingState         string   `json:"pending_state,omitempty"`
	UpdatedAt            string   `json:"updated_at"`
}

type State struct {
	SchemaVersion           int      `json:"schema_version"`
	InstallationID          string   `json:"installation_id"`
	Owner                   string   `json:"owner"`
	ProductionRunnerGroupID int64    `json:"production_runner_group_id"`
	QuarantineRunnerGroupID int64    `json:"quarantine_runner_group_id"`
	ConfigRevision          string   `json:"config_revision"`
	IdentityRevision        string   `json:"identity_revision"`
	Records                 []Record `json:"records"`
}

type Manager struct {
	cfg Config
	api crfgithub.ScaleSetAPI
}

func New(cfg Config, api crfgithub.ScaleSetAPI) (*Manager, error) {
	if cfg.Path == "" || !identity.MatchString(cfg.InstallationID) ||
		!identity.MatchString(cfg.Owner) || cfg.ProductionRunnerGroupID <= 0 ||
		cfg.QuarantineRunnerGroupID <= 0 ||
		cfg.ProductionRunnerGroupID == cfg.QuarantineRunnerGroupID ||
		!revision.MatchString(cfg.ConfigRevision) || !revision.MatchString(cfg.OwnershipRevision) ||
		api == nil {
		return nil, errors.New("invalid_ownership_config")
	}
	return &Manager{cfg: cfg, api: api}, nil
}

func remoteName(routingLabel string) string {
	return routingLabel
}

const (
	scaleSetLabelContract = "canonical-name-label-v1"
	scaleSetNameContract  = "routing-label-name-v1"
)

func specRevision(pool Pool, productionGroupID, quarantineGroupID int64) string {
	labels := slices.Clone(pool.Labels)
	sort.Strings(labels)
	data, _ := json.Marshal([]any{scaleSetLabelContract, scaleSetNameContract, pool.ID,
		pool.RoutingLabel, labels, productionGroupID, quarantineGroupID})
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func validPool(pool Pool) bool {
	if !identity.MatchString(pool.ID) || !identity.MatchString(pool.RoutingLabel) ||
		len(pool.Labels) == 0 || len(pool.Labels) > 32 {
		return false
	}
	seen := map[string]bool{}
	for _, label := range pool.Labels {
		if !identity.MatchString(label) || seen[strings.ToLower(label)] {
			return false
		}
		seen[strings.ToLower(label)] = true
	}
	return true
}

func (m *Manager) emptyState() State {
	return State{SchemaVersion: 2, InstallationID: m.cfg.InstallationID, Owner: m.cfg.Owner,
		ProductionRunnerGroupID: m.cfg.ProductionRunnerGroupID,
		QuarantineRunnerGroupID: m.cfg.QuarantineRunnerGroupID, ConfigRevision: m.cfg.ConfigRevision,
		IdentityRevision: m.cfg.OwnershipRevision, Records: []Record{}}
}

func (m *Manager) Load() (State, error) {
	info, err := os.Lstat(m.cfg.Path)
	if errors.Is(err, os.ErrNotExist) {
		return m.emptyState(), nil
	}
	if err != nil {
		return State{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 1<<20 {
		return State{}, errors.New("ownership_permissions_or_size")
	}
	file, err := os.Open(m.cfg.Path)
	if err != nil {
		return State{}, err
	}
	defer func() { _ = file.Close() }()
	dec := json.NewDecoder(file)
	dec.DisallowUnknownFields()
	var state State
	if err := dec.Decode(&state); err != nil {
		return State{}, err
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return State{}, errors.New("ownership_trailing_data")
	}
	if state.SchemaVersion != 2 || state.InstallationID != m.cfg.InstallationID ||
		state.Owner != m.cfg.Owner ||
		state.ProductionRunnerGroupID != m.cfg.ProductionRunnerGroupID ||
		state.QuarantineRunnerGroupID != m.cfg.QuarantineRunnerGroupID ||
		state.IdentityRevision != m.cfg.OwnershipRevision ||
		!revision.MatchString(state.ConfigRevision) || len(state.Records) > 64 {
		return State{}, errors.New("ownership_identity_mismatch")
	}
	seen := make(map[string]bool, len(state.Records))
	for _, record := range state.Records {
		if !identity.MatchString(record.PoolID) || !identity.MatchString(record.RemoteName) ||
			record.ScaleSetID < 0 ||
			(record.RunnerGroupID != m.cfg.ProductionRunnerGroupID &&
				record.RunnerGroupID != m.cfg.QuarantineRunnerGroupID) ||
			!revision.MatchString(record.RemoteSpecRevision) ||
			!slices.Contains(recordStates, record.State) || seen[record.PoolID] ||
			len(record.ConfiguredLabels) == 0 || len(record.ConfiguredLabels) > 32 ||
			len(record.AppliedLabels) == 0 || len(record.AppliedLabels) > 32 {
			return State{}, errors.New("invalid_ownership_record")
		}
		if record.ScaleSetID == 0 && record.State != "creating" &&
			record.State != "create_ambiguous" &&
			record.State != "orphan_create_ambiguous" && record.State != "delete_pending" {
			return State{}, errors.New("invalid_ownership_record")
		}
		if _, err := time.Parse(time.RFC3339, record.UpdatedAt); err != nil {
			return State{}, errors.New("invalid_ownership_record")
		}
		pending := record.State == "update_pending"
		if pending {
			if (record.PendingRunnerGroupID != m.cfg.ProductionRunnerGroupID &&
				record.PendingRunnerGroupID != m.cfg.QuarantineRunnerGroupID) ||
				len(record.PendingAppliedLabels) == 0 ||
				len(record.PendingAppliedLabels) > 32 ||
				!slices.Contains([]string{"eligible", "ineligible", "orphan_ineligible",
					"delete_pending"}, record.PendingState) {
				return State{}, errors.New("invalid_ownership_update_intent")
			}
		} else if record.PendingRunnerGroupID != 0 ||
			len(record.PendingAppliedLabels) != 0 || record.PendingState != "" {
			return State{}, errors.New("invalid_ownership_update_intent")
		}
		for _, label := range append(slices.Clone(record.ConfiguredLabels), record.AppliedLabels...) {
			if !identity.MatchString(label) {
				return State{}, errors.New("invalid_ownership_record")
			}
		}
		for _, label := range record.PendingAppliedLabels {
			if !identity.MatchString(label) {
				return State{}, errors.New("invalid_ownership_update_intent")
			}
		}
		seen[record.PoolID] = true
	}
	return state, nil
}

func (m *Manager) write(state State) error {
	state.SchemaVersion = 2
	state.InstallationID = m.cfg.InstallationID
	state.Owner = m.cfg.Owner
	state.ProductionRunnerGroupID = m.cfg.ProductionRunnerGroupID
	state.QuarantineRunnerGroupID = m.cfg.QuarantineRunnerGroupID
	state.ConfigRevision = m.cfg.ConfigRevision
	state.IdentityRevision = m.cfg.OwnershipRevision
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return durable.Replace(m.cfg.Path, ".ownership.*", 0o600, 1<<20,
		func(w io.Writer) error {
			_, err := w.Write(data)
			return err
		})
}

func equalSpec(remote crfgithub.ScaleSet, name string, groupID int64, labels []string) bool {
	if remote.ID <= 0 || remote.Name != name || remote.RunnerGroupID != groupID {
		return false
	}
	got, want := crfgithub.LabelsForComparison(remote, labels), slices.Clone(labels)
	for i := range got {
		got[i] = strings.ToLower(got[i])
	}
	for i := range want {
		want[i] = strings.ToLower(want[i])
	}
	sort.Strings(got)
	sort.Strings(want)
	return slices.Equal(got, want)
}

func specMismatch(remote crfgithub.ScaleSet, name string, groupID int64, labels []string) error {
	gotLabels, wantLabels := crfgithub.LabelsForComparison(remote, labels), slices.Clone(labels)
	sort.Strings(gotLabels)
	sort.Strings(wantLabels)
	return fmt.Errorf(
		"verify_updated_scale_set_mismatch: got_name=%q want_name=%q got_group=%d want_group=%d got_labels=%q want_labels=%q",
		remote.Name, name, remote.RunnerGroupID, groupID,
		strings.Join(gotLabels, ","), strings.Join(wantLabels, ","),
	)
}

func (m *Manager) finishPendingUpdate(ctx context.Context, state *State,
	record *Record) error {
	if record.State != "update_pending" {
		return nil
	}
	remote, err := m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
	if err != nil {
		return fmt.Errorf("get_pending_owned_update: %w", err)
	}
	oldMatches := equalSpec(remote, record.RemoteName, record.RunnerGroupID, record.AppliedLabels)
	targetMatches := equalSpec(remote, record.RemoteName, record.PendingRunnerGroupID,
		record.PendingAppliedLabels)
	if !oldMatches && !targetMatches {
		return fmt.Errorf("owned_remote_drift_during_update: %w",
			specMismatch(remote, record.RemoteName, record.PendingRunnerGroupID,
				record.PendingAppliedLabels))
	}
	if oldMatches {
		if _, err := m.api.UpdateRunnerScaleSet(ctx, record.ScaleSetID, crfgithub.UpdateSpec{
			Name: record.RemoteName, RunnerGroupID: record.PendingRunnerGroupID,
			Labels: slices.Clone(record.PendingAppliedLabels),
		}); err != nil {
			return fmt.Errorf("update_owned_scale_set: %w", err)
		}
		remote, err = m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
		if err != nil {
			return fmt.Errorf("verify_updated_scale_set: %w", err)
		}
		if !equalSpec(remote, record.RemoteName, record.PendingRunnerGroupID,
			record.PendingAppliedLabels) {
			return specMismatch(remote, record.RemoteName, record.PendingRunnerGroupID,
				record.PendingAppliedLabels)
		}
	}
	record.RunnerGroupID = record.PendingRunnerGroupID
	record.AppliedLabels = slices.Clone(record.PendingAppliedLabels)
	record.State = record.PendingState
	record.PendingRunnerGroupID = 0
	record.PendingAppliedLabels = nil
	record.PendingState = ""
	record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	return m.write(*state)
}

func (m *Manager) updateOwnedSpec(ctx context.Context, state *State, record *Record,
	targetGroupID int64, labels []string, targetState string) error {
	if record.State == "update_pending" {
		if err := m.finishPendingUpdate(ctx, state, record); err != nil {
			return err
		}
	}
	remote, err := m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
	if err != nil {
		return fmt.Errorf("get_owned_before_update: %w", err)
	}
	if !equalSpec(remote, record.RemoteName, record.RunnerGroupID, record.AppliedLabels) {
		return fmt.Errorf("owned_remote_identity_mismatch: %w",
			specMismatch(remote, record.RemoteName, record.RunnerGroupID, record.AppliedLabels))
	}
	if equalSpec(remote, record.RemoteName, targetGroupID, labels) {
		if record.RunnerGroupID == targetGroupID &&
			slices.Equal(record.AppliedLabels, labels) && record.State == targetState {
			return nil
		}
		record.RunnerGroupID = targetGroupID
		record.AppliedLabels = slices.Clone(labels)
		record.State = targetState
		record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		return m.write(*state)
	}
	record.PendingRunnerGroupID = targetGroupID
	record.PendingAppliedLabels = slices.Clone(labels)
	record.PendingState = targetState
	record.State = "update_pending"
	record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	if err := m.write(*state); err != nil {
		return err
	}
	return m.finishPendingUpdate(ctx, state, record)
}

func (m *Manager) replaceOwnedSpec(ctx context.Context, state *State, record *Record,
	pool Pool, name, specRev string) error {
	oldName := record.RemoteName
	oldLabels := slices.Clone(record.AppliedLabels)
	if record.State == "update_pending" {
		if err := m.finishPendingUpdate(ctx, state, record); err != nil {
			return err
		}
	}

	// GitHub's scale-set update endpoint can add labels but does not reliably
	// remove them. Replacement is therefore the only way to narrow routing.
	// First force the exact owned ID back behind quarantine using an intent-first
	// update. Remote state may be only the exact persisted old identity or the
	// exact intended identity after a crash.
	if record.State != "delete_pending" {
		remote, err := m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
		if err != nil {
			return fmt.Errorf("get_owned_before_spec_replacement: %w", err)
		}
		if remote.ID != record.ScaleSetID ||
			!equalSpec(remote, oldName, record.RunnerGroupID, oldLabels) {
			return fmt.Errorf("owned_remote_drift_before_spec_migration: %w",
				specMismatch(remote, oldName, record.RunnerGroupID, oldLabels))
		}
		if err := m.updateOwnedSpec(ctx, state, record, m.cfg.QuarantineRunnerGroupID,
			oldLabels, "delete_pending"); err != nil {
			return err
		}
	}

	remote, err := m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
	if err == nil {
		if !equalSpec(remote, oldName, m.cfg.QuarantineRunnerGroupID, oldLabels) {
			return errors.New("owned_remote_drift_during_spec_replacement")
		}
		if err := m.api.DeleteRunnerScaleSet(ctx, record.ScaleSetID); err != nil &&
			!errors.Is(err, crfgithub.ErrNotFound) {
			return fmt.Errorf("delete_owned_during_spec_replacement: %w", err)
		}
	} else if !errors.Is(err, crfgithub.ErrNotFound) {
		return fmt.Errorf("verify_owned_during_spec_replacement: %w", err)
	}

	record.RemoteName = name
	record.ScaleSetID = 0
	record.RunnerGroupID = m.cfg.QuarantineRunnerGroupID
	record.ConfiguredLabels = slices.Clone(pool.Labels)
	record.AppliedLabels = slices.Clone(pool.Labels)
	record.RemoteSpecRevision = specRev
	record.State = "creating"
	record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	return m.write(*state)
}

func (m *Manager) Reconcile(ctx context.Context, pools []Pool, eligible bool) ([]Record, error) {
	if len(pools) == 0 || len(pools) > 8 {
		return nil, errors.New("invalid_pool_count")
	}
	desired := make(map[string]bool, len(pools))
	desiredNames := make(map[string]bool, len(pools))
	for _, pool := range pools {
		nameKey := strings.ToLower(pool.RoutingLabel)
		if !validPool(pool) || desired[pool.ID] || desiredNames[nameKey] {
			return nil, errors.New("invalid_pool")
		}
		desired[pool.ID] = true
		desiredNames[nameKey] = true
	}
	state, err := m.Load()
	if err != nil {
		return nil, err
	}
	byPool := make(map[string]int, len(state.Records))
	newIntent := make(map[string]bool, len(pools))
	for i, record := range state.Records {
		byPool[record.PoolID] = i
	}
	for _, pool := range pools {
		specRev := specRevision(pool, m.cfg.ProductionRunnerGroupID, m.cfg.QuarantineRunnerGroupID)
		name := remoteName(pool.RoutingLabel)
		applied := slices.Clone(pool.Labels)
		targetGroupID := m.cfg.QuarantineRunnerGroupID
		targetState := "ineligible"
		if eligible {
			targetGroupID = m.cfg.ProductionRunnerGroupID
			targetState = "eligible"
		}
		idx, exists := byPool[pool.ID]
		if !exists {
			record := Record{PoolID: pool.ID, RemoteName: name, RunnerGroupID: targetGroupID,
				ConfiguredLabels: slices.Clone(pool.Labels), AppliedLabels: slices.Clone(applied),
				RemoteSpecRevision: specRev, State: "creating", UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
			state.Records = append(state.Records, record)
			idx = len(state.Records) - 1
			byPool[pool.ID] = idx
			if err := m.write(state); err != nil {
				return nil, err
			}
			newIntent[pool.ID] = true
		}
		record := &state.Records[idx]
		if record.RemoteName != name || record.RemoteSpecRevision != specRev {
			if record.ScaleSetID <= 0 {
				return nil, errors.New("owned_spec_revision_mismatch")
			}
			if err := m.replaceOwnedSpec(ctx, &state, record, pool, name, specRev); err != nil {
				return nil, err
			}
			newIntent[pool.ID] = true
		}
		if record.ScaleSetID == 0 {
			// REVIEW(crf-v3q.13.3, MUST-CHECK): A persisted ID-less intent
			// proves only that a create may have been attempted. Predictable
			// name/spec equality cannot prove ownership after response loss, so
			// never adopt by name. Only an intent created in this in-memory
			// reconciliation pass may issue the remote create.
			if !newIntent[pool.ID] {
				record.State = "create_ambiguous"
				record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
				if err := m.write(state); err != nil {
					return nil, err
				}
				return nil, errors.New("ambiguous_create_intent")
			}
			created, createErr := m.api.CreateRunnerScaleSet(ctx, crfgithub.CreateSpec{
				Name: name, RunnerGroupID: record.RunnerGroupID, Labels: applied,
			})
			if createErr != nil {
				record.State = "create_ambiguous"
				record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
				if err := m.write(state); err != nil {
					return nil, err
				}
				return nil, fmt.Errorf("ambiguous_create_intent: %w", createErr)
			}
			record.ScaleSetID = created.ID
			if err := m.write(state); err != nil {
				return nil, err
			}
		}
		if err := m.updateOwnedSpec(ctx, &state, record, targetGroupID, applied,
			targetState); err != nil {
			return nil, err
		}
		if !slices.Equal(record.ConfiguredLabels, pool.Labels) {
			record.ConfiguredLabels = slices.Clone(pool.Labels)
			record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
			if err := m.write(state); err != nil {
				return nil, err
			}
		}
	}
	for i := range state.Records {
		record := &state.Records[i]
		if desired[record.PoolID] {
			continue
		}
		if record.ScaleSetID <= 0 {
			record.State = "orphan_create_ambiguous"
			record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
			if err := m.write(state); err != nil {
				return nil, err
			}
			continue
		}
		applied := slices.Clone(record.ConfiguredLabels)
		if err := m.updateOwnedSpec(ctx, &state, record, m.cfg.QuarantineRunnerGroupID,
			applied, "orphan_ineligible"); err != nil {
			return nil, fmt.Errorf("make_orphan_ineligible: %w", err)
		}
	}
	return slices.Clone(state.Records), nil
}

func (m *Manager) DeleteOwned(ctx context.Context) error {
	state, err := m.Load()
	if err != nil {
		return err
	}
	for i := range state.Records {
		state.Records[i].State = "delete_pending"
		state.Records[i].UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	if err := m.write(state); err != nil {
		return err
	}
	var first error
	kept := make([]Record, 0, len(state.Records))
	for _, record := range state.Records {
		if record.ScaleSetID <= 0 {
			if first == nil {
				first = errors.New("ambiguous_create_intent")
			}
			kept = append(kept, record)
			continue
		}
		// REVIEW(crf-v3q.13.4, MUST-CHECK): An owned numeric ID is necessary
		// but not sufficient after operator/API drift. Re-read and verify the
		// complete persisted identity before deletion; only the typed not-found
		// sentinel is idempotent success.
		remote, getErr := m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
		if errors.Is(getErr, crfgithub.ErrNotFound) {
			continue
		}
		if getErr != nil || !equalSpec(remote, record.RemoteName, record.RunnerGroupID,
			record.AppliedLabels) {
			if first == nil {
				if getErr != nil {
					first = fmt.Errorf("delete_owned_identity_check: %w", getErr)
				} else {
					first = fmt.Errorf("delete_owned_remote_identity_mismatch: %w",
						specMismatch(remote, record.RemoteName, record.RunnerGroupID,
							record.AppliedLabels))
				}
			}
			kept = append(kept, record)
			continue
		}
		if err := m.api.DeleteRunnerScaleSet(ctx, record.ScaleSetID); err != nil &&
			!errors.Is(err, crfgithub.ErrNotFound) {
			if first == nil {
				first = err
			}
			kept = append(kept, record)
			continue
		}
	}
	state.Records = kept
	if err := m.write(state); err != nil {
		return err
	}
	return first
}
