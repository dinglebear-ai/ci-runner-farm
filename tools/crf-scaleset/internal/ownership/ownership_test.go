package ownership

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
)

type fakeAPI struct {
	path          string
	nextID        int64
	sets          map[int64]crfgithub.ScaleSet
	createErr     error
	deleteErr     error
	sawIntent     bool
	deleted       []int64
	createdLabels []string
	partialUpdate bool
	updateLabels  []string
	normalizeCase bool
}

func (f *fakeAPI) CreateRunnerScaleSet(_ context.Context, spec crfgithub.CreateSpec) (crfgithub.ScaleSet, error) {
	data, _ := os.ReadFile(f.path)
	f.sawIntent = strings.Contains(string(data), `"state": "creating"`) &&
		strings.Contains(string(data), `"scale_set_id": 0`)
	f.createdLabels = slices.Clone(spec.Labels)
	if f.createErr != nil {
		return crfgithub.ScaleSet{}, f.createErr
	}
	f.nextID++
	spec.ID = f.nextID
	if f.normalizeCase {
		spec.Labels = githubCase(spec.Labels)
	}
	f.sets[spec.ID] = spec
	return spec, nil
}
func (f *fakeAPI) GetRunnerScaleSet(_ context.Context, id int64) (crfgithub.ScaleSet, error) {
	v, ok := f.sets[id]
	if !ok {
		return crfgithub.ScaleSet{}, crfgithub.ErrNotFound
	}
	return v, nil
}
func (f *fakeAPI) GetRunnerScaleSetByName(_ context.Context, groupID int64, name string) (crfgithub.ScaleSet, error) {
	for _, v := range f.sets {
		if v.RunnerGroupID == groupID && v.Name == name {
			return v, nil
		}
	}
	return crfgithub.ScaleSet{}, nil
}
func (f *fakeAPI) UpdateRunnerScaleSet(_ context.Context, id int64, spec crfgithub.UpdateSpec) (crfgithub.ScaleSet, error) {
	spec.ID = id
	if f.updateLabels != nil {
		spec.Labels = slices.Clone(f.updateLabels)
	}
	if f.normalizeCase {
		spec.Labels = githubCase(spec.Labels)
	}
	f.sets[id] = spec
	if f.partialUpdate {
		return crfgithub.ScaleSet{}, nil
	}
	return spec, nil
}
func (f *fakeAPI) DeleteRunnerScaleSet(_ context.Context, id int64) error {
	f.deleted = append(f.deleted, id)
	if f.deleteErr != nil {
		return f.deleteErr
	}
	delete(f.sets, id)
	return nil
}
func (*fakeAPI) GetRunnerGroupByName(context.Context, string) (crfgithub.RunnerGroup, error) {
	return crfgithub.RunnerGroup{}, nil
}
func (*fakeAPI) CreateMessageSession(context.Context, int64) (crfgithub.Session, error) {
	return crfgithub.Session{}, nil
}
func (*fakeAPI) GetMessage(context.Context, crfgithub.Session, int64, int) (crfgithub.MessageBatch, error) {
	return crfgithub.MessageBatch{}, nil
}
func (*fakeAPI) AcquireJobs(context.Context, crfgithub.Session, crfgithub.AcquireRequest) (crfgithub.AcquireResult, error) {
	return crfgithub.AcquireResult{}, nil
}
func (*fakeAPI) AcknowledgeMessage(context.Context, crfgithub.Session, int64) error { return nil }
func (*fakeAPI) GenerateJitRunnerConfig(context.Context, int64, crfgithub.JITRequest) ([]byte, error) {
	return nil, nil
}

func githubCase(labels []string) []string {
	out := slices.Clone(labels)
	for i, label := range out {
		switch label {
		case "linux":
			out[i] = "Linux"
		case "x64":
			out[i] = "X64"
		}
	}
	return out
}

func testManager(t *testing.T) (*Manager, *fakeAPI) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ownership.json")
	api := &fakeAPI{path: path, nextID: 40, sets: map[int64]crfgithub.ScaleSet{}}
	m, err := New(Config{
		Path:                    path,
		InstallationID:          "01234567-89ab-cdef-0123-456789abcdef",
		Owner:                   "dinglebear-ai",
		ProductionRunnerGroupID: 7,
		QuarantineRunnerGroupID: 8,
		ConfigRevision:          strings.Repeat("a", 64),
		OwnershipRevision:       strings.Repeat("b", 64),
	}, api)
	if err != nil {
		t.Fatal(err)
	}
	return m, api
}

func TestRemoteNameUsesStableRoutingLabel(t *testing.T) {
	if got := remoteName("ci-pool-ops"); got != "ci-pool-ops" {
		t.Fatalf("remote scale-set name drifted from routing label: %q", got)
	}
}

func TestReconcileRejectsDuplicateRoutingNames(t *testing.T) {
	m, _ := testManager(t)
	_, err := m.Reconcile(context.Background(), []Pool{
		{ID: "rust", RoutingLabel: "ci-pool-build", Labels: []string{"ci-pool-build"}},
		{ID: "ops", RoutingLabel: "CI-POOL-BUILD", Labels: []string{"CI-POOL-BUILD"}},
	}, false)
	if err == nil || !strings.Contains(err.Error(), "invalid_pool") {
		t.Fatalf("duplicate stable routing names were accepted: %v", err)
	}
}

func TestReconcilePersistsIntentAndCreatesIneligible(t *testing.T) {
	m, api := testManager(t)
	records, err := m.Reconcile(context.Background(), []Pool{{
		ID: "python", RoutingLabel: "ci-pool-python",
		Labels: []string{"self-hosted", "linux", "x64", "python"},
	}}, false)
	if err != nil {
		t.Fatal(err)
	}
	if !api.sawIntent {
		t.Fatal("remote create happened before durable create intent")
	}
	if len(records) != 1 || records[0].ScaleSetID != 41 || records[0].State != "ineligible" {
		t.Fatalf("unexpected records: %#v", records)
	}
	if got := api.createdLabels; !slices.Equal(got, []string{"self-hosted", "linux", "x64", "python"}) {
		t.Fatalf("created labels changed in quarantine: %#v", got)
	}
	if records[0].RunnerGroupID != m.cfg.QuarantineRunnerGroupID {
		t.Fatalf("ineligible scale set not quarantined: %#v", records[0])
	}
	info, err := os.Stat(api.path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("ownership file mode: info=%v err=%v", info, err)
	}
}

func TestReconcileNoOpDoesNotRewriteOwnershipFile(t *testing.T) {
	m, api := testManager(t)
	pools := []Pool{{ID: "ops", RoutingLabel: "ci-pool-ops",
		Labels: []string{"ci-pool-ops"}}}
	if _, err := m.Reconcile(context.Background(), pools, false); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(api.path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Reconcile(context.Background(), pools, false); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(api.path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("no-op ownership reconciliation rewrote the durable state file")
	}
}

func TestActivateUsesConfiguredLabelsAndDeleteUsesExactID(t *testing.T) {
	m, api := testManager(t)
	pools := []Pool{{ID: "typescript", RoutingLabel: "ci-pool-typescript",
		Labels: []string{"self-hosted", "linux", "x64", "node"}}}
	records, err := m.Reconcile(context.Background(), pools, false)
	if err != nil {
		t.Fatal(err)
	}
	id := records[0].ScaleSetID
	records, err = m.Reconcile(context.Background(), pools, true)
	if err != nil {
		t.Fatal(err)
	}
	if records[0].State != "eligible" || records[0].RunnerGroupID != m.cfg.ProductionRunnerGroupID ||
		api.sets[id].RunnerGroupID != m.cfg.ProductionRunnerGroupID ||
		!slices.Equal(api.sets[id].Labels, pools[0].Labels) {
		t.Fatalf("activation did not apply configured labels: %#v", api.sets[id])
	}
	if err := m.DeleteOwned(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(api.deleted, []int64{id}) {
		t.Fatalf("deleted IDs: %#v", api.deleted)
	}
	state, err := m.Load()
	if err != nil || len(state.Records) != 0 {
		t.Fatalf("owned records remain: %#v err=%v", state, err)
	}
}

func TestReconcileVerifiesPartialUpdateResponseWithGet(t *testing.T) {
	m, api := testManager(t)
	pools := []Pool{{ID: "typescript", RoutingLabel: "ci-pool-typescript",
		Labels: []string{"self-hosted", "linux", "x64", "node"}}}
	if _, err := m.Reconcile(context.Background(), pools, false); err != nil {
		t.Fatal(err)
	}
	api.partialUpdate = true
	records, err := m.Reconcile(context.Background(), pools, true)
	if err != nil {
		t.Fatalf("partial update response was treated as authoritative: %v", err)
	}
	if records[0].State != "eligible" {
		t.Fatalf("scale set did not become eligible: %#v", records)
	}
}

func TestReconcileReportsNormalizedRemoteSpecMismatch(t *testing.T) {
	m, api := testManager(t)
	pools := []Pool{{ID: "typescript", RoutingLabel: "ci-pool-typescript",
		Labels: []string{"self-hosted", "linux", "x64", "node"}}}
	if _, err := m.Reconcile(context.Background(), pools, false); err != nil {
		t.Fatal(err)
	}
	api.updateLabels = []string{"node"}
	_, err := m.Reconcile(context.Background(), pools, true)
	if err == nil {
		t.Fatal("normalized remote labels were accepted without an exact match")
	}
	message := err.Error()
	for _, want := range []string{
		"verify_updated_scale_set_mismatch",
		`got_group=7 want_group=7`,
		`got_labels="node"`,
		`want_labels="linux,node,self-hosted,x64"`,
	} {
		if !strings.Contains(message, want) {
			t.Fatalf("mismatch error %q missing %q", message, want)
		}
	}
	if strings.Contains(message, "%!w") {
		t.Fatalf("mismatch error contains a formatting failure: %q", message)
	}
}

func TestReconcileAcceptsGitHubLabelCaseNormalization(t *testing.T) {
	m, api := testManager(t)
	api.normalizeCase = true
	pools := []Pool{{ID: "rust", RoutingLabel: "ci-pool-rust",
		Labels: []string{"self-hosted", "linux", "x64", "ci-pool-rust", "unraid"}}}
	records, err := m.Reconcile(context.Background(), pools, false)
	if err != nil {
		t.Fatalf("GitHub label case normalization was rejected: %v", err)
	}
	if len(records) != 1 || records[0].State != "ineligible" {
		t.Fatalf("unexpected records: %#v", records)
	}
}

func TestReconcileMigratesAnExactlyOwnedPoolSpecInPlace(t *testing.T) {
	m, api := testManager(t)
	oldPool := Pool{ID: "python", RoutingLabel: "ci-pool-python",
		Labels: []string{"self-hosted", "linux", "x64", "ci-pool-python"}}
	records, err := m.Reconcile(context.Background(), []Pool{oldPool}, true)
	if err != nil {
		t.Fatal(err)
	}
	id, oldName := records[0].ScaleSetID, records[0].RemoteName
	newPool := Pool{ID: "python", RoutingLabel: "ci-pool-python",
		Labels: []string{"ci-pool-python"}}
	records, err = m.Reconcile(context.Background(), []Pool{newPool}, true)
	if err != nil {
		t.Fatalf("exact owned spec migration failed: %v", err)
	}
	wantRevision := specRevision(newPool, m.cfg.ProductionRunnerGroupID, m.cfg.QuarantineRunnerGroupID)
	if records[0].ScaleSetID == id || records[0].RemoteName != oldName ||
		records[0].RemoteName != newPool.RoutingLabel ||
		records[0].RemoteSpecRevision != wantRevision ||
		!slices.Equal(records[0].AppliedLabels, newPool.Labels) ||
		!equalSpec(api.sets[records[0].ScaleSetID], records[0].RemoteName,
			m.cfg.ProductionRunnerGroupID, newPool.Labels) ||
		!slices.Contains(api.deleted, id) {
		t.Fatalf("owned pool was not replaced exactly: record=%#v sets=%#v deleted=%#v",
			records[0], api.sets, api.deleted)
	}
}

func TestReconcileRefusesPoolSpecMigrationAfterRemoteDrift(t *testing.T) {
	m, api := testManager(t)
	oldPool := Pool{ID: "python", RoutingLabel: "ci-pool-python",
		Labels: []string{"self-hosted", "linux", "x64", "ci-pool-python"}}
	records, err := m.Reconcile(context.Background(), []Pool{oldPool}, true)
	if err != nil {
		t.Fatal(err)
	}
	remote := api.sets[records[0].ScaleSetID]
	remote.Labels = []string{"foreign"}
	api.sets[remote.ID] = remote
	newPool := Pool{ID: "python", RoutingLabel: "ci-pool-python",
		Labels: []string{"ci-pool-python"}}
	if _, err := m.Reconcile(context.Background(), []Pool{newPool}, true); err == nil ||
		!strings.Contains(err.Error(), "owned_remote_drift_before_spec_migration") {
		t.Fatalf("drifted remote was migrated: %v", err)
	}
}

func TestAmbiguousCreateNeverAdoptsForeignObject(t *testing.T) {
	m, api := testManager(t)
	foreign := crfgithub.ScaleSet{ID: 99, Name: remoteName("ci-pool-rust"),
		RunnerGroupID: m.cfg.QuarantineRunnerGroupID, Labels: []string{"foreign"}}
	api.sets[foreign.ID] = foreign
	api.createErr = errors.New("response lost")
	_, err := m.Reconcile(context.Background(), []Pool{{
		ID: "rust", RoutingLabel: "ci-pool-rust", Labels: []string{"self-hosted", "rust"},
	}}, false)
	if err == nil || !strings.Contains(err.Error(), "ambiguous_create_intent") {
		t.Fatalf("foreign object was adopted: %v", err)
	}
	state, loadErr := m.Load()
	if loadErr != nil || len(state.Records) != 1 || state.Records[0].ScaleSetID != 0 ||
		state.Records[0].State != "create_ambiguous" {
		t.Fatalf("create intent was not retained: %#v err=%v", state, loadErr)
	}
}

func TestReconcileNeverNameAdoptsDurableCreateIntentAfterRestart(t *testing.T) {
	m, api := testManager(t)
	pool := Pool{ID: "rust", RoutingLabel: "ci-pool-rust",
		Labels: []string{"self-hosted", "ci-pool-rust"}}
	specRev := specRevision(pool, m.cfg.ProductionRunnerGroupID, m.cfg.QuarantineRunnerGroupID)
	name := remoteName(pool.RoutingLabel)
	applied := slices.Clone(pool.Labels)
	state := m.emptyState()
	state.Records = []Record{{
		PoolID:             pool.ID,
		RemoteName:         name,
		RunnerGroupID:      m.cfg.QuarantineRunnerGroupID,
		ConfiguredLabels:   slices.Clone(pool.Labels),
		AppliedLabels:      slices.Clone(applied),
		RemoteSpecRevision: specRev,
		State:              "creating",
		UpdatedAt:          "2026-07-30T22:00:00Z",
	}}
	if err := m.write(state); err != nil {
		t.Fatal(err)
	}
	api.sets[91] = crfgithub.ScaleSet{ID: 91, Name: name,
		RunnerGroupID: m.cfg.QuarantineRunnerGroupID, Labels: slices.Clone(applied)}

	if _, err := m.Reconcile(context.Background(), []Pool{pool}, false); err == nil ||
		!strings.Contains(err.Error(), "ambiguous_create_intent") {
		t.Fatalf("durable create intent name-adopted a remote object: %v", err)
	}
	persisted, err := m.Load()
	if err != nil || len(persisted.Records) != 1 ||
		persisted.Records[0].ScaleSetID != 0 ||
		persisted.Records[0].State != "create_ambiguous" {
		t.Fatalf("ambiguous create tombstone was not retained: %#v err=%v", persisted, err)
	}
}

func TestDeleteFailureRetainsTombstone(t *testing.T) {
	m, api := testManager(t)
	_, err := m.Reconcile(context.Background(), []Pool{{
		ID: "ops", RoutingLabel: "ci-pool-ops", Labels: []string{"self-hosted", "ops"},
	}}, false)
	if err != nil {
		t.Fatal(err)
	}
	api.deleteErr = errors.New("status 503")
	if err := m.DeleteOwned(context.Background()); err == nil {
		t.Fatal("delete failure was accepted")
	}
	state, loadErr := m.Load()
	if loadErr != nil || len(state.Records) != 1 || state.Records[0].State != "delete_pending" {
		t.Fatalf("delete tombstone was not retained: %#v err=%v", state, loadErr)
	}
}

func TestDeleteRefusesRemoteIdentityDrift(t *testing.T) {
	m, api := testManager(t)
	records, err := m.Reconcile(context.Background(), []Pool{{
		ID: "ops", RoutingLabel: "ci-pool-ops", Labels: []string{"ops"},
	}}, false)
	if err != nil {
		t.Fatal(err)
	}
	remote := api.sets[records[0].ScaleSetID]
	remote.Labels = []string{"foreign"}
	api.sets[remote.ID] = remote
	if err := m.DeleteOwned(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "delete_owned_remote_identity_mismatch") {
		t.Fatalf("drifted remote object was deleted: %v", err)
	}
	if len(api.deleted) != 0 {
		t.Fatalf("delete was issued before identity revalidation: %#v", api.deleted)
	}
}

func TestDeleteDoesNotTreatTextual404AsNotFound(t *testing.T) {
	m, api := testManager(t)
	if _, err := m.Reconcile(context.Background(), []Pool{{
		ID: "ops", RoutingLabel: "ci-pool-ops", Labels: []string{"ops"},
	}}, false); err != nil {
		t.Fatal(err)
	}
	api.deleteErr = errors.New("proxy failure mentions 404 but is not not-found")
	if err := m.DeleteOwned(context.Background()); err == nil {
		t.Fatal("textual 404 was accepted as typed not-found")
	}
	state, err := m.Load()
	if err != nil || len(state.Records) != 1 || state.Records[0].State != "delete_pending" {
		t.Fatalf("delete tombstone was not retained: %#v err=%v", state, err)
	}
}

func TestLoadRejectsSymlinkedOwnershipState(t *testing.T) {
	m, api := testManager(t)
	target := api.path + ".real"
	state := m.emptyState()
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, api.path); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Load(); err == nil {
		t.Fatal("symlinked ownership state was accepted")
	}
}

func TestLoadRejectsMalformedOrDuplicatedOwnershipRecords(t *testing.T) {
	m, api := testManager(t)
	record := Record{
		PoolID:             "python",
		RemoteName:         "crf-install-python-spec",
		ScaleSetID:         41,
		RunnerGroupID:      m.cfg.ProductionRunnerGroupID,
		ConfiguredLabels:   []string{"self-hosted", "python"},
		AppliedLabels:      []string{"self-hosted", "python"},
		RemoteSpecRevision: strings.Repeat("c", 64),
		State:              "eligible",
		UpdatedAt:          "2026-07-30T22:00:00Z",
	}
	state := m.emptyState()
	state.Records = []Record{record, record}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(api.path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Load(); err == nil {
		t.Fatal("duplicated ownership record was accepted")
	}

	state.Records = []Record{record}
	data, err = json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	data = append(data, []byte("\n{}")...)
	if err := os.WriteFile(api.path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Load(); err == nil {
		t.Fatal("ownership state with trailing data was accepted")
	}
}

func TestRemovedPoolIsMadeIneligibleAndRetainedForExactCleanup(t *testing.T) {
	m, api := testManager(t)
	pools := []Pool{
		{ID: "python", RoutingLabel: "python", Labels: []string{"self-hosted", "python"}},
		{ID: "rust", RoutingLabel: "rust", Labels: []string{"self-hosted", "rust"}},
	}
	records, err := m.Reconcile(context.Background(), pools, true)
	if err != nil {
		t.Fatal(err)
	}
	var rustID int64
	for _, record := range records {
		if record.PoolID == "rust" {
			rustID = record.ScaleSetID
		}
	}
	records, err = m.Reconcile(context.Background(), pools[:1], true)
	if err != nil {
		t.Fatal(err)
	}
	var rust Record
	for _, record := range records {
		if record.PoolID == "rust" {
			rust = record
		}
	}
	if rust.State != "orphan_ineligible" || rust.ScaleSetID != rustID ||
		rust.RunnerGroupID != m.cfg.QuarantineRunnerGroupID ||
		api.sets[rustID].RunnerGroupID != m.cfg.QuarantineRunnerGroupID ||
		!slices.Equal(api.sets[rustID].Labels, pools[1].Labels) {
		t.Fatalf("removed pool remained eligible or lost exact ownership: record=%#v remote=%#v",
			rust, api.sets[rustID])
	}
}
