package farmcapacity

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func privatePolicyFixture(t *testing.T) (*hostcapacity.Config, []byte, PrivateRegistrationPolicy, string) {
	t.Helper()
	c := &hostcapacity.Config{Host: "target", Epoch: strings.Repeat("1", 32), Organization: "test-org"}
	raw, _ := json.Marshal(c)
	p := PrivateRegistrationPolicy{Version: 1, Host: c.Host, Epoch: c.Epoch, Owner: c.Organization, SharedPolicySHA256: RegistrationDigest(raw), SettingsSHA256: strings.Repeat("2", 64), Scope: "repo", Repositories: []string{"test-org/first", "test-org/second"}}
	return c, raw, p, filepath.Join(t.TempDir(), "farm-registration-policy.json")
}
func TestPrivateRoutingPolicyKeepsSharedBytesAndIgnoresUnrelatedSettingsChanges(t *testing.T) {
	c, raw, p, path := privatePolicyFixture(t)
	if err := PublishRegistrationPolicy(path, RegistrationPolicyAbsent, p, c); err != nil {
		t.Fatal(err)
	}
	if err := LoadRegistrationAuthority(path, c, raw); err != nil {
		t.Fatal(err)
	}
	after, _ := json.Marshal(c)
	if string(after) != string(raw) {
		t.Fatal("Farm private authority changed shared JSON")
	}
	// The original public settings digest remains provenance. A labels/count/cache
	// edit does not alter shared bytes or selected registration scope/allowlist.
	if err := LoadRegistrationAuthority(path, c, raw); err != nil || !c.AllowsRegistration(hostcapacity.RegistrationTarget{Scope: "repo", Owner: "test-org", Repository: "second"}) {
		t.Fatal("unrelated settings invalidated registration authority", err)
	}
	if err := LoadRegistrationAuthority(path, c, append(raw, ' ')); err == nil {
		t.Fatal("shared material drift accepted")
	}
}
func TestPrivateRoutingPolicyRequiresExplicitScopeAndExactCAS(t *testing.T) {
	c, _, p, path := privatePolicyFixture(t)
	for _, scope := range []string{"", "other"} {
		p.Scope = scope
		if p.Validate(c) == nil {
			t.Fatal("malformed private scope became organization fallback")
		}
	}
	p.Scope = "repo"
	if err := PublishRegistrationPolicy(path, "absent", p, c); err != nil {
		t.Fatal(err)
	}
	if err := PublishRegistrationPolicy(path, "absent", p, c); err == nil {
		t.Fatal("private policy overwrite ignored stale absence")
	}
	p.Epoch = strings.Repeat("3", 32)
	if p.Validate(c) == nil {
		t.Fatal("foreign epoch policy accepted")
	}
}
func TestMissingPrivatePolicyOnlyDefaultsOrganizationAndCannotStartRepository(t *testing.T) {
	c, raw, _, path := privatePolicyFixture(t)
	if err := LoadRegistrationAuthority(path, c, raw); err != nil {
		t.Fatal(err)
	}
	if c.EffectiveRegistrationScope() != "org" || c.AllowsRegistration(hostcapacity.RegistrationTarget{Scope: "repo", Owner: "test-org", Repository: "first"}) {
		t.Fatal("absent private policy enabled repository work")
	}
}
func TestRetainedRepositoryCleanupDoesNotRequireCurrentPrivatePublication(t *testing.T) {
	c, d, id := fixture(t)
	target := &hostcapacity.RegistrationTarget{Scope: "repo", Owner: "test-org", Repository: "first"}
	d.containers[id].RegistrationTarget = target
	c.RegistrationPolicy = &hostcapacity.Config{Organization: "test-org", RegistrationScope: "repo", RegistrationRepositories: []string{"test-org/first"}}
	if err := c.Start(context.Background(), testName, id); err != nil {
		t.Fatal(err)
	}
	c.RegistrationPolicy.RegistrationRepositories = []string{"test-org/second"}
	c.BeforeStart = func(context.Context) error { return errors.New("current private publication unavailable") }
	actual, err := c.RegistrationTarget(context.Background(), testName, id)
	if err != nil || *actual != *target {
		t.Fatal("retained cleanup identity depended on current publication", err)
	}
}
func TestPrivateRoutingPolicyReaderRefusesSymlinkAndUnknownFields(t *testing.T) {
	c, _, p, path := privatePolicyFixture(t)
	if err := PublishRegistrationPolicy(path, "absent", p, c); err != nil {
		t.Fatal(err)
	}
	link := path + "-link"
	os.Symlink(path, link)
	if _, _, err := ReadRegistrationPolicy(link, c); err == nil {
		t.Fatal("symlink private policy accepted")
	}
	raw, _ := json.Marshal(p)
	raw = append(raw[:len(raw)-1], []byte(`,"unknown":true}`)...)
	os.WriteFile(path, raw, 0600)
	if _, _, err := ReadRegistrationPolicy(path, c); err == nil {
		t.Fatal("unknown private authority field accepted")
	}
}
