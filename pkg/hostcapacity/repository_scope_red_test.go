package hostcapacity

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestFarmPrivateFieldsNeverEnterSharedHostPolicyJSON(t *testing.T) {
	config := testConfig(testRoot(t))
	before, _ := json.Marshal(config)
	config.RegistrationScope = "repo"
	config.RegistrationRepositories = []string{"test-org/first"}
	after, _ := json.Marshal(config)
	if string(before) != string(after) {
		t.Fatal("Farm routing fields leaked into shared policy")
	}
	var strictReader Config
	decoder := json.NewDecoder(strings.NewReader(string(after)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&strictReader); err != nil {
		t.Fatalf("old strict shared reader rejected common bytes: %v", err)
	}
	var oldReader map[string]json.RawMessage
	if json.Unmarshal(after, &oldReader) != nil {
		t.Fatal("shared JSON")
	}
	if oldReader["registrationScope"] != nil || oldReader["registrationRepositories"] != nil {
		t.Fatal("old strict reader would reject private fields")
	}
}
func TestRepositoryRegistrationPolicyRejectsAmbiguousScope(t *testing.T) {
	for _, raw := range []string{`{"registrationScope":"bad"}`, `{"registrationScope":"repo"}`, `{"registrationScope":"repo","registrationRepositories":["other/repo"]}`, `{"registrationScope":"repo","registrationRepositories":["test-org/a","test-org/a"]}`, `{"registrationScope":"org","registrationRepositories":["test-org/a"]}`} {
		config := testConfig(testRoot(t))
		var input struct {
			Scope        string   `json:"registrationScope"`
			Repositories []string `json:"registrationRepositories"`
		}
		if err := json.Unmarshal([]byte(raw), &input); err != nil {
			t.Fatal(err)
		}
		config.RegistrationScope = input.Scope
		config.RegistrationRepositories = input.Repositories
		if config.Validate("test-host") == nil {
			t.Fatalf("ambiguous registration scope accepted: %s", raw)
		}
	}
	config := testConfig(testRoot(t))
	if err := config.Validate("test-host"); err != nil || config.EffectiveRegistrationScope() != "org" {
		t.Fatal("legacy organization policy changed")
	}
}
