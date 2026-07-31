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
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	crfgithub "github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/github"
)

var (
	identity = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	revision = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

var recordStates = []string{
	"creating",
	"ineligible",
	"eligible",
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
	PoolID             string   `json:"pool_id"`
	RemoteName         string   `json:"remote_name"`
	ScaleSetID         int64    `json:"scale_set_id"`
	RunnerGroupID      int64    `json:"runner_group_id"`
	ConfiguredLabels   []string `json:"configured_labels"`
	AppliedLabels      []string `json:"applied_labels"`
	RemoteSpecRevision string   `json:"remote_spec_revision"`
	State              string   `json:"state"`
	UpdatedAt          string   `json:"updated_at"`
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

func remoteName(installationID, poolID, specRevision string) string {
	install := strings.ReplaceAll(installationID, "-", "")
	if len(install) > 12 {
		install = install[:12]
	}
	return fmt.Sprintf("crf-%s-%s-%s", install, poolID, specRevision[:12])
}

func specRevision(pool Pool, productionGroupID, quarantineGroupID int64) string {
	labels := slices.Clone(pool.Labels)
	sort.Strings(labels)
	data, _ := json.Marshal([]any{pool.ID, pool.RoutingLabel, labels, productionGroupID, quarantineGroupID})
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
	defer file.Close()
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
			record.State != "orphan_create_ambiguous" && record.State != "delete_pending" {
			return State{}, errors.New("invalid_ownership_record")
		}
		if _, err := time.Parse(time.RFC3339, record.UpdatedAt); err != nil {
			return State{}, errors.New("invalid_ownership_record")
		}
		for _, label := range append(slices.Clone(record.ConfiguredLabels), record.AppliedLabels...) {
			if !identity.MatchString(label) {
				return State{}, errors.New("invalid_ownership_record")
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
	if err := os.MkdirAll(filepath.Dir(m.cfg.Path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(m.cfg.Path), ".ownership.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, m.cfg.Path)
}

func equalSpec(remote crfgithub.ScaleSet, name string, groupID int64, labels []string) bool {
	if remote.ID <= 0 || remote.Name != name || remote.RunnerGroupID != groupID {
		return false
	}
	got, want := slices.Clone(remote.Labels), slices.Clone(labels)
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
	gotLabels, wantLabels := slices.Clone(remote.Labels), slices.Clone(labels)
	sort.Strings(gotLabels)
	sort.Strings(wantLabels)
	return fmt.Errorf(
		"verify_updated_scale_set_mismatch: got_name=%q want_name=%q got_group=%d want_group=%d got_labels=%q want_labels=%q",
		remote.Name, name, remote.RunnerGroupID, groupID,
		strings.Join(gotLabels, ","), strings.Join(wantLabels, ","),
	)
}

func (m *Manager) replaceOwnedSpec(ctx context.Context, state *State, record *Record,
	pool Pool, name, specRev string) error {
	oldName := record.RemoteName
	oldLabels := slices.Clone(record.AppliedLabels)

	// GitHub's scale-set update endpoint can add labels but does not reliably
	// remove them. Replacement is therefore the only way to narrow routing.
	// First force the exact owned ID back behind quarantine using its persisted
	// old spec. Also recognize and repair a narrowly bounded partial update from
	// an interrupted older build: same ID, old labels, and either the old or the
	// deterministic new name in one of our two bound runner groups.
	if record.State != "delete_pending" {
		remote, err := m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
		if err != nil {
			return fmt.Errorf("get_owned_before_spec_replacement: %w", err)
		}
		nameKnown := remote.Name == oldName || remote.Name == name
		groupKnown := remote.RunnerGroupID == m.cfg.ProductionRunnerGroupID ||
			remote.RunnerGroupID == m.cfg.QuarantineRunnerGroupID
		if remote.ID != record.ScaleSetID || !nameKnown || !groupKnown ||
			!equalSpec(remote, remote.Name, remote.RunnerGroupID, oldLabels) {
			return fmt.Errorf("owned_remote_drift_before_spec_migration: %w",
				specMismatch(remote, oldName, record.RunnerGroupID, oldLabels))
		}
		if !equalSpec(remote, oldName, m.cfg.QuarantineRunnerGroupID, oldLabels) {
			if _, err := m.api.UpdateRunnerScaleSet(ctx, record.ScaleSetID, crfgithub.UpdateSpec{
				Name: oldName, RunnerGroupID: m.cfg.QuarantineRunnerGroupID, Labels: oldLabels,
			}); err != nil {
				return fmt.Errorf("quarantine_owned_before_spec_replacement: %w", err)
			}
			remote, err = m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
			if err != nil || !equalSpec(remote, oldName, m.cfg.QuarantineRunnerGroupID, oldLabels) {
				return fmt.Errorf("verify_quarantined_before_spec_replacement: %w", err)
			}
		}
		record.RunnerGroupID = m.cfg.QuarantineRunnerGroupID
		record.State = "delete_pending"
		record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		if err := m.write(*state); err != nil {
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
	for _, pool := range pools {
		if !validPool(pool) || desired[pool.ID] {
			return nil, errors.New("invalid_pool")
		}
		desired[pool.ID] = true
	}
	state, err := m.Load()
	if err != nil {
		return nil, err
	}
	byPool := make(map[string]int, len(state.Records))
	for i, record := range state.Records {
		byPool[record.PoolID] = i
	}
	for _, pool := range pools {
		specRev := specRevision(pool, m.cfg.ProductionRunnerGroupID, m.cfg.QuarantineRunnerGroupID)
		name := remoteName(m.cfg.InstallationID, pool.ID, specRev)
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
		}
		record := &state.Records[idx]
		if record.RemoteName != name || record.RemoteSpecRevision != specRev {
			if record.ScaleSetID <= 0 {
				return nil, errors.New("owned_spec_revision_mismatch")
			}
			if err := m.replaceOwnedSpec(ctx, &state, record, pool, name, specRev); err != nil {
				return nil, err
			}
		}
		if record.ScaleSetID == 0 {
			created := crfgithub.ScaleSet{}
			if exists {
				reconciled, getErr := m.api.GetRunnerScaleSetByName(ctx, record.RunnerGroupID, name)
				if getErr == nil && reconciled.ID > 0 {
					if !equalSpec(reconciled, name, record.RunnerGroupID, applied) {
						return nil, errors.New("foreign_collision_during_intent_recovery")
					}
					created = reconciled
				} else if getErr != nil && !errors.Is(getErr, crfgithub.ErrNotFound) {
					return nil, fmt.Errorf("recover_create_intent: %w", getErr)
				}
			}
			if created.ID == 0 {
				var createErr error
				created, createErr = m.api.CreateRunnerScaleSet(ctx, crfgithub.CreateSpec{
					Name: name, RunnerGroupID: record.RunnerGroupID, Labels: applied,
				})
				if createErr != nil {
					reconciled, getErr := m.api.GetRunnerScaleSetByName(ctx, record.RunnerGroupID, name)
					if getErr != nil || !equalSpec(reconciled, name, record.RunnerGroupID, applied) {
						return nil, fmt.Errorf("foreign_collision_or_ambiguous_create: %w", createErr)
					}
					created = reconciled
				}
			}
			record.ScaleSetID = created.ID
			if err := m.write(state); err != nil {
				return nil, err
			}
		}
		remote, err := m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
		if err != nil {
			return nil, fmt.Errorf("get_owned_scale_set: %w", err)
		}
		if remote.ID != record.ScaleSetID || remote.Name != record.RemoteName ||
			remote.RunnerGroupID != record.RunnerGroupID {
			return nil, errors.New("owned_remote_identity_mismatch")
		}
		if !equalSpec(remote, name, targetGroupID, applied) {
			_, err = m.api.UpdateRunnerScaleSet(ctx, record.ScaleSetID, crfgithub.UpdateSpec{
				Name: name, RunnerGroupID: targetGroupID, Labels: applied,
			})
			if err != nil {
				return nil, fmt.Errorf("update_owned_scale_set: %w", err)
			}
			remote, err = m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
			if err != nil {
				return nil, fmt.Errorf("verify_updated_scale_set: %w", err)
			}
			if !equalSpec(remote, name, targetGroupID, applied) {
				return nil, specMismatch(remote, name, targetGroupID, applied)
			}
		}
		record.RunnerGroupID = targetGroupID
		record.ConfiguredLabels = slices.Clone(pool.Labels)
		record.AppliedLabels = slices.Clone(applied)
		record.State = targetState
		record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		if err := m.write(state); err != nil {
			return nil, err
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
		remote, err := m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
		if err != nil || remote.ID != record.ScaleSetID || remote.Name != record.RemoteName ||
			remote.RunnerGroupID != record.RunnerGroupID {
			return nil, fmt.Errorf("orphan_owned_remote_identity_mismatch: %w", err)
		}
		applied := slices.Clone(record.ConfiguredLabels)
		if !equalSpec(remote, record.RemoteName, m.cfg.QuarantineRunnerGroupID, applied) {
			_, err = m.api.UpdateRunnerScaleSet(ctx, record.ScaleSetID, crfgithub.UpdateSpec{
				Name: record.RemoteName, RunnerGroupID: m.cfg.QuarantineRunnerGroupID, Labels: applied,
			})
			if err != nil {
				return nil, fmt.Errorf("make_orphan_ineligible: %w", err)
			}
			remote, err = m.api.GetRunnerScaleSet(ctx, record.ScaleSetID)
			if err != nil || !equalSpec(remote, record.RemoteName, m.cfg.QuarantineRunnerGroupID, applied) {
				return nil, fmt.Errorf("verify_orphan_ineligible: %w", err)
			}
		}
		record.RunnerGroupID = m.cfg.QuarantineRunnerGroupID
		record.AppliedLabels = applied
		record.State = "orphan_ineligible"
		record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		if err := m.write(state); err != nil {
			return nil, err
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
		if err := m.api.DeleteRunnerScaleSet(ctx, record.ScaleSetID); err != nil &&
			!strings.Contains(err.Error(), "404") && !errors.Is(err, crfgithub.ErrNotFound) {
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
