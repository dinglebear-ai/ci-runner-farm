package nativebackend

import (
	"encoding/json"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func registrationObservationFixture(t *testing.T) ([]byte, []byte, []byte) {
	t.Helper()
	r := sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}
	original := hostcapacity.Config{Schema: 1, Host: "target", Epoch: strings.Repeat("1", 32), Organization: "test-org", Mode: "active", LedgerPath: "/cache/ledger", ReceiptRoot: "/cache/receipts", TokenPath: "/config/token", LockPath: "/config/lock", Policy: sharedcapacity.Policy{Budget: r, AgingSeconds: 30, Pools: map[string]sharedcapacity.Pool{"build": {Cost: r, Maximum: 1}}}}
	before, _ := json.Marshal(original)
	next := original
	next.RegistrationScope = "repo"
	next.RegistrationRepositories = []string{"test-org/first"}
	policySHA := farmcapacity.RegistrationDigest(before)
	intent, _, _ := registrationPolicyIntent(original, next, policySHA, strings.Repeat("2", 64), "absent")
	private, _ := json.Marshal(farmcapacity.PrivateRegistrationPolicy{Version: 1, Host: original.Host, Epoch: original.Epoch, Owner: original.Organization, SharedPolicySHA256: policySHA, SettingsSHA256: strings.Repeat("2", 64), Scope: "repo", Repositories: next.RegistrationRepositories})
	return intent, before, private
}
func TestScopeUpdateLostResponseObservationPreservesSharedBytes(t *testing.T) {
	intent, before, private := registrationObservationFixture(t)
	result, err := registrationPolicyObservation(intent, before, before, []byte("null\n"), private)
	if err != nil || result["state"] != "applied_observed" || result["runtimeQualificationProven"] != false || result["replayAllowed"] != false || result["beforeSHA256"] != result["afterSHA256"] || result["beforeRegistrationPolicySHA256"] != "absent" {
		t.Fatal(result, err)
	}
	result, err = registrationPolicyObservation(intent, before, before, []byte("null\n"), []byte("null\n"))
	if err != nil || result["state"] != "inspect_required" {
		t.Fatal(result, err)
	}
	if _, err = registrationPolicyObservation(intent, before, append(before, ' '), []byte("null\n"), private); err == nil {
		t.Fatal("shared byte drift accepted")
	}
}
func TestRegistrationPolicyEvidenceRejectsFIFOAndPublicFile(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "request")
	os.WriteFile(path, []byte("{}"), 0644)
	if _, err := readRegistrationPolicyEvidence(path, uint32(os.Geteuid())); err == nil {
		t.Fatal("public evidence accepted")
	}
	fifo := filepath.Join(root, "fifo")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readRegistrationPolicyEvidence(fifo, uint32(os.Geteuid())); err == nil {
		t.Fatal("FIFO accepted")
	}
}
func TestScopeProposalAndApplyShareExactCanonicalIntentIdentity(t *testing.T) {
	intent, before, _ := registrationObservationFixture(t)
	var owner hostcapacity.Config
	json.Unmarshal(before, &owner)
	next := owner
	next.RegistrationScope = "repo"
	next.RegistrationRepositories = []string{"test-org/first"}
	raw, identity, err := registrationPolicyIntent(owner, next, farmcapacity.RegistrationDigest(before), strings.Repeat("2", 64), "absent")
	if err != nil || string(raw) != string(intent) || identity != farmcapacity.RegistrationDigest(intent) {
		t.Fatal("proposal/apply canonical intent mismatch")
	}
	_, changed, _ := registrationPolicyIntent(owner, next, farmcapacity.RegistrationDigest(before), strings.Repeat("3", 64), "absent")
	if changed == identity {
		t.Fatal("settings drift did not change intent")
	}
}
func TestLabelsOnlySettingsChangeUpdatesCASWithoutInvalidatingAuthority(t *testing.T) {
	intent, before, private := registrationObservationFixture(t)
	_ = intent
	var owner hostcapacity.Config
	json.Unmarshal(before, &owner)
	var retained farmcapacity.PrivateRegistrationPolicy
	json.Unmarshal(private, &retained)
	next := owner
	retained.Apply(&next)
	digest := farmcapacity.RegistrationDigest(private)
	a, err := registrationPolicyProposalData(owner, next, &retained, digest, before, `{"GH_SCOPE":"repo","RUNNER_LABELS":"first"}`)
	if err != nil {
		t.Fatal(err)
	}
	b, err := registrationPolicyProposalData(owner, next, &retained, digest, before, `{"GH_SCOPE":"repo","RUNNER_LABELS":"second","RUNNER_COUNT":"2"}`)
	if err != nil {
		t.Fatal(err)
	}
	if a["changed"] != false || b["changed"] != false || a["expectedRegistrationPolicySHA256"] != b["expectedRegistrationPolicySHA256"] || a["expectedSettingsSHA256"] == b["expectedSettingsSHA256"] {
		t.Fatal("unrelated settings required registration republication", a, b)
	}
}
