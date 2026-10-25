package nativebackend

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/githubapp"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"time"

	"github.com/unraid/ci-runner-farm/internal/remotehost"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// AppliedSetupEvidence describes observed target configuration only. It grants
// no installation, admission, workload or GitHub registration authority.
// SettingsProjectionSHA256 binds only the explicitly verified settings below;
// unrelated settings are neither certified nor invalidation inputs.
type AppliedSetupEvidence struct {
	Protocol                 string `json:"protocol"`
	ProposalID               string `json:"proposalID"`
	ProposalSHA256           string `json:"proposalSHA256"`
	PackageSHA256            string `json:"packageSHA256"`
	InstalledTreeSHA256      string `json:"installedTreeSHA256"`
	Host                     string `json:"host"`
	Epoch                    string `json:"epoch"`
	PolicySHA256             string `json:"policySHA256"`
	SettingsProjectionSHA256 string `json:"settingsProjectionSHA256"`
	LedgerPolicyDigest       string `json:"ledgerPolicyDigest"`
}

func setupHash(value any) string {
	raw, _ := json.Marshal(value)
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:])
}

func verifyAppliedSetup(p remotehost.SetupProposal, artifact remotehost.PackageView, installed InstallationIdentity, settings map[string]string, policy *hostcapacity.Config, ledger sharedcapacity.Diagnostics, boundCache, host string) (AppliedSetupEvidence, error) {
	var zero AppliedSetupEvidence
	refuse := errors.New("remote_setup_actual_configuration_mismatch")
	if p.Validate() != nil || !installed.valid() || artifact.SHA256 != p.PackageSHA256 || artifact.Version != installed.Version || artifact.TreeSHA256 != installed.TreeSHA256 || artifact.ManifestSHA256 != installed.ManifestSHA256 || artifact.BackendSHA256 != installed.BackendSHA256 {
		return zero, refuse
	}
	if policy == nil || policy.Validate(host) != nil || policy.Mode != "active" || policy.Organization != p.Owner || len(policy.ScanRepositories) != 1 || policy.ScanRepositories[0] != p.Owner+"/"+p.Repository || policy.PoolExpansion != nil {
		return zero, refuse
	}
	expected := map[string]string{"CI_PROVIDER": "github", "GH_SCOPE": "repo", "RUNNER_MODE": "single", "GH_OWNER": p.Owner, "GH_REPOS": p.Owner + "/" + p.Repository, "RUNNER_COUNT": "1", "CACHE_ROOT": boundCache}
	if boundCache == "" || policy.LedgerPath != boundCache+"/native-capacity/ledger.db" || policy.ReceiptRoot != boundCache+"/native-capacity/receipts" {
		return zero, refuse
	}
	for key, value := range expected {
		if settings[key] != value {
			return zero, refuse
		}
	}
	resources := sharedcapacity.Resources{MemoryMiB: p.MemoryMiB, VCPUs: p.VCPUs}
	pool, ok := policy.Policy.Pools["build"]
	if !ok || len(policy.Policy.Pools) != 1 || policy.Policy.Budget != resources || pool.Cost != resources || pool.Minimum != 1 || pool.Maximum != p.RunnerCount || !ledger.PolicyMatches || !reflect.DeepEqual(ledger.Policy, policy.Policy) || !installationDigest.MatchString(ledger.ActivePolicyDigest) || ledger.ActivePolicyDigest != ledger.LedgerPolicyDigest {
		return zero, refuse
	}
	return AppliedSetupEvidence{Protocol: "farm-applied-setup/v1", ProposalID: p.OperationID, ProposalSHA256: setupHash(p), PackageSHA256: artifact.SHA256, InstalledTreeSHA256: installed.TreeSHA256, Host: host, Epoch: policy.Epoch, PolicySHA256: setupHash(policy), SettingsProjectionSHA256: setupHash(expected), LedgerPolicyDigest: ledger.LedgerPolicyDigest}, nil
}

// remoteAppliedSetup observes existing owners. The explicit native verify action
// records facts only after settings/admission were separately saved by their UI.
func (s *Service) remoteAppliedSetup(r Request) Response {
	if len(r.Args) != 0 || len(r.Values) != 0 || r.Kind != "" || !cancelJobPattern.MatchString(r.Value) {
		return fail("invalid_applied_setup_request")
	}
	engine, ok := s.engine.(*Engine)
	if !ok || engine.BoundCache == "" {
		return fail("applied_setup_native_owner_required")
	}
	if !s.mu.TryLock() {
		return fail("backend_busy")
	}
	defer s.mu.Unlock()
	if !s.accepting || s.active != nil {
		return fail("backend_busy")
	}
	root := filepath.Join(s.config, "native-onboarding")
	if CheckDirectory(s.config, uint32(os.Geteuid())) != nil || CheckDirectory(root, uint32(os.Geteuid())) != nil {
		return fail("installation_receipt_unavailable")
	}
	installed, err := readInstallation(filepath.Join(root, "current-installation.json"))
	if err != nil {
		return fail("installation_identity_missing_or_changed")
	}
	helper, err := actualInstallationHelper()
	if err != nil || installed.BackendSHA256 != helper {
		return fail("installation_identity_missing_or_changed")
	}
	proposals, err := remotehost.ListSetupProposals(filepath.Join(s.config, "pending-setup"))
	if err != nil {
		return fail("remote_setup_inventory_unavailable")
	}
	var proposal *remotehost.SetupProposal
	for i := range proposals {
		if proposals[i].OperationID == r.Value {
			proposal = &proposals[i]
			break
		}
	}
	if proposal == nil {
		return fail("remote_setup_proposal_unavailable")
	}
	artifact, err := remotehost.InspectStagedSetupPackage("/var/tmp/unraid-farm-bootstrap", *proposal)
	if err != nil {
		return fail("remote_setup_staged_package_changed")
	}
	ctx, cancel := context.WithTimeout(s.ctx, 10*time.Second)
	defer cancel()
	raw, err := engine.Run(ctx, "native-config-json", nil, "")
	if err != nil {
		return fail("remote_setup_settings_unavailable")
	}
	var settings map[string]string
	if json.Unmarshal([]byte(raw), &settings) != nil {
		return fail("remote_setup_settings_unavailable")
	}
	policy, err := hostcapacity.Load(hostcapacity.ConfigPath)
	if err != nil {
		return fail("remote_setup_policy_unavailable")
	}
	raw, err = engine.Run(ctx, "native-admission-status", nil, "")
	if err != nil {
		return fail("remote_setup_ledger_unavailable")
	}
	var ledger sharedcapacity.Diagnostics
	if json.Unmarshal([]byte(raw), &ledger) != nil {
		return fail("remote_setup_ledger_unavailable")
	}
	host, err := os.Hostname()
	if err != nil {
		return fail("remote_setup_host_unavailable")
	}
	facts, err := verifyAppliedSetup(*proposal, artifact, installed.InstallationIdentity, settings, policy, ledger, engine.BoundCache, host)
	if err != nil {
		return fail("remote_setup_actual_configuration_mismatch")
	}
	path := filepath.Join(root, "applied-"+proposal.OperationID+".json")
	release, err := githubapp.AcquireCredentialLease(ctx, filepath.Join(root, "installation"))
	if err != nil {
		return fail("installation_inventory_busy")
	}
	defer release()
	existing, err := readAppliedSetup(path)
	if err == nil {
		if existing.Evidence != facts {
			return fail("remote_setup_applied_receipt_changed_inspect")
		}
		return success(existing)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return fail("remote_setup_applied_receipt_unsafe")
	}
	if r.Action == "remote-setup-applied-status" {
		return fail("remote_setup_applied_receipt_missing")
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) >= 100 {
		return fail("installation_inventory_limit")
	}
	record := appliedSetupReceipt{Evidence: facts, ObservedAt: time.Now().UTC()}
	encoded, _ := json.Marshal(record)
	if publishExclusive(path, encoded) != nil {
		return fail("remote_setup_applied_receipt_uncertain")
	}
	return success(record)
}

type appliedSetupReceipt struct {
	Evidence   AppliedSetupEvidence `json:"evidence"`
	ObservedAt time.Time            `json:"observedAt"`
}

func readAppliedSetup(path string) (appliedSetupReceipt, error) {
	var result appliedSetupReceipt
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return result, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 8192 {
		return result, errors.New("unsafe_applied_setup_receipt")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return result, errors.New("unsafe_applied_setup_receipt")
	}
	raw, err := io.ReadAll(io.LimitReader(f, 8193))
	if err != nil || len(raw) > 8192 {
		return result, errors.New("unsafe_applied_setup_receipt")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&result) != nil || decoder.Decode(new(any)) != io.EOF || result.ObservedAt.IsZero() {
		return result, errors.New("invalid_applied_setup_receipt")
	}
	return result, nil
}
