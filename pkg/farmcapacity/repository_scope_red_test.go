package farmcapacity

import (
	"context"
	"encoding/json"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// RED acceptance case: a pinned repository owner must never query its parent
// organization's runner namespace, even when numeric runner IDs coincide.
func TestRepositoryPinnedOwnerUsesRepositoryRunnerNamespace(t *testing.T) {
	var observed []string
	owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
		observed = append(observed, request.URL.Path)
		return ownerResponse(http.StatusOK, `{"id":123,"name":"owned-runner","status":"online","busy":false}`), nil
	})
	if err := json.Unmarshal([]byte(`{"registrationTarget":{"scope":"repo","owner":"test-org","repository":"first"}}`), owner); err != nil {
		t.Fatal(err)
	}
	if _, err := owner.RemoteIdle(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(observed) != 1 || observed[0] != "/repos/test-org/first/actions/runners/123" {
		t.Fatalf("scope escaped pinned repository: %v", observed)
	}
}

func TestRepositoryOwnerAllAPIsUseExactPinnedTargetWithoutFallback(t *testing.T) {
	target := &hostcapacity.RegistrationTarget{Scope: "repo", Owner: "test-org", Repository: "first"}
	for _, operation := range []string{"labels", "delete", "scope-absence", "unregistered-list"} {
		t.Run(operation, func(t *testing.T) {
			var paths []string
			owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
				paths = append(paths, request.Method+" "+request.URL.Path)
				if !strings.HasPrefix(request.URL.Path, "/repos/test-org/first/actions/runners") {
					t.Fatalf("cross-scope request: %s", request.URL)
				}
				if operation == "scope-absence" {
					if request.URL.Query().Get("per_page") == "1" {
						return ownerResponse(http.StatusOK, `{"total_count":0,"runners":[]}`), nil
					}
					return ownerResponse(http.StatusNotFound, `{}`), nil
				}
				if operation == "unregistered-list" {
					return ownerResponse(http.StatusOK, `{"total_count":0,"runners":[]}`), nil
				}
				if request.Method == http.MethodDelete {
					return ownerResponse(http.StatusNoContent, ``), nil
				}
				return ownerResponse(http.StatusOK, `{"id":123,"name":"owned-runner","status":"offline","busy":false}`), nil
			})
			owner.RegistrationTarget = target
			var err error
			switch operation {
			case "labels":
				err = owner.replaceRouting(context.Background(), []string{"smoke"})
			case "delete":
				err = owner.WithdrawRemote(context.Background())
			case "scope-absence":
				_, err = owner.RemoteGone(context.Background())
			case "unregistered-list":
				owner.Unregistered = true
				owner.RunnerID = 0
				owner.Name = testName
				owner.RunnerName = "host-" + testName
				_, err = owner.RemoteGone(context.Background())
			}
			if err != nil || len(paths) == 0 {
				t.Fatalf("operation failed: %v, %v", err, paths)
			}
		})
	}
}
func TestRepositoryTargetCapturedBeforeStartAndSurvivesAllowlistChanges(t *testing.T) {
	c, d, id := fixture(t)
	target := &hostcapacity.RegistrationTarget{Scope: "repo", Owner: "test-org", Repository: "first"}
	d.containers[id].RegistrationTarget = target
	c.RegistrationPolicy = &hostcapacity.Config{Organization: "test-org", RegistrationScope: "repo", RegistrationRepositories: []string{"test-org/first", "test-org/second"}}
	if err := c.Start(context.Background(), testName, id); err != nil {
		t.Fatal(err)
	}
	for _, repositories := range [][]string{{"test-org/second", "test-org/first"}, {"test-org/second"}} {
		c.RegistrationPolicy.RegistrationRepositories = repositories
		actual, err := c.RegistrationTarget(context.Background(), testName, id)
		if err != nil || *actual != *target {
			t.Fatalf("retained target changed: %v %v", actual, err)
		}
	}
	d.containers[id].RegistrationTarget = &hostcapacity.RegistrationTarget{Scope: "repo", Owner: "test-org", Repository: "second"}
	if err := c.Start(context.Background(), testName, id); err == nil {
		t.Fatal("mutable target replaced retained owner")
	}
}
func TestRepositoryPolicyRejectsForeignTargetBeforeStarting(t *testing.T) {
	c, d, id := fixture(t)
	d.containers[id].RegistrationTarget = &hostcapacity.RegistrationTarget{Scope: "repo", Owner: "test-org", Repository: "foreign"}
	c.RegistrationPolicy = &hostcapacity.Config{Organization: "test-org", RegistrationScope: "repo", RegistrationRepositories: []string{"test-org/first"}}
	if err := c.Start(context.Background(), testName, id); err == nil || d.starts != 0 {
		t.Fatal("unapproved target started")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 0 {
		t.Fatalf("unapproved target charged: %v", err)
	}
}

func TestRepositoryRegistrationIdentityPinsLiveAndExitedURL(t *testing.T) {
	for _, state := range []string{testRunningStatus, testExitedStatus} {
		t.Run(state, func(t *testing.T) {
			id := strings.Repeat("a", 64)
			expected := "host-" + testName
			target := hostcapacity.RegistrationTarget{Scope: "repo", Owner: testRegistrationOrganization, Repository: "first"}
			directory := installExitedRegistrationFixture(t, id, state, state == testRunningStatus, 0, expected, testRegistrationOrganization+"/first", expected)
			inspectedPath := filepath.Join(directory, "inspect")
			raw, err := os.ReadFile(inspectedPath)
			if err != nil {
				t.Fatal(err)
			}
			var inspected []map[string]any
			if json.Unmarshal(raw, &inspected) != nil {
				t.Fatal("inspect fixture")
			}
			config := inspected[0]["Config"].(map[string]any)
			config["Env"] = []string{"RUNNER_NAME=" + expected, "RUNNER_SCOPE=repo", "REPO_URL=" + target.URL()}
			raw, _ = json.Marshal(inspected)
			if err = os.WriteFile(inspectedPath, raw, 0o600); err != nil {
				t.Fatal(err)
			}
			if state == testRunningStatus {
				identity, _ := json.Marshal(map[string]any{"agentId": 123, "agentName": expected, "gitHubUrl": target.URL()})
				identityPath := filepath.Join(directory, "identity.json")
				if err = os.WriteFile(identityPath, identity, 0o600); err != nil {
					t.Fatal(err)
				}
				script := "#!/bin/sh\ncase \"$1\" in ps) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "listing")) + ";; inspect) exec /bin/cat " + strconv.Quote(inspectedPath) + ";; exec) exec /bin/cat " + strconv.Quote(identityPath) + ";; *) exit 1;; esac\n"
				if err = os.WriteFile(filepath.Join(directory, "docker"), []byte(script), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			runnerID, name, err := RegistrationForTarget(context.Background(), id, target, testName)
			if err != nil || runnerID != 123 || name != expected {
				t.Fatalf("exact repo identity refused: %d %q %v", runnerID, name, err)
			}
			target.Repository = "second"
			if _, _, err = RegistrationForTarget(context.Background(), id, target, testName); err == nil {
				t.Fatal("cross-repository identity accepted")
			}
		})
	}
}
