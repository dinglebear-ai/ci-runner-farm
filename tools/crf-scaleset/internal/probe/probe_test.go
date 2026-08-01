package probe

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func completeRecord() Record {
	caps := map[string]bool{}
	for _, name := range required {
		caps[name] = true
	}
	return Record{PluginDigest: strings.Repeat("a", 64), HelperDigest: strings.Repeat("b", 64),
		ModuleRevision: "6ce025902cd964747a078c2aabe7340ebc667eca", GoVersion: "go1.25.3",
		ImageDigest: strings.Repeat("c", 64), DockerfileDigest: strings.Repeat("d", 64),
		EntrypointDigest: strings.Repeat("e", 64), Owner: "acme", APIURL: "https://api.github.com",
		InstallationID: "installation", HostID: "host", RunnerGroupID: 42,
		QuarantineRunnerGroupID: 43,
		RunnerGroupPolicy:       "selected_repositories",
		Capabilities:            caps, Cleanup: Cleanup{Complete: true}}
}

func TestLoadFreshRevalidatesSealAgeAndPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "compatibility.json")
	record := completeRecord()
	now := time.Now().UTC().Truncate(time.Second)
	if err := record.Seal(now); err != nil {
		t.Fatal(err)
	}
	data, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadFresh(path, now.Add(time.Hour), 30*24*time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadFresh(path, now.Add(time.Hour), 30*24*time.Hour); err == nil {
		t.Fatal("accepted broad permissions")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadFresh(path, now.Add(31*24*time.Hour), 30*24*time.Hour); err == nil {
		t.Fatal("accepted stale record")
	}
	data[len(data)/2] ^= 1
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadFresh(path, now, 30*24*time.Hour); err == nil {
		t.Fatal("accepted tampered record")
	}
}
func TestSealRequiresEveryGateAndCleanup(t *testing.T) {
	r := completeRecord()
	if err := r.Seal(time.Unix(1, 0)); err != nil {
		t.Fatal(err)
	}
	if len(r.CompatibilityRecordID) != 64 {
		t.Fatal("record is not sealed")
	}
	r = completeRecord()
	r.Capabilities["eligibility_barrier"] = false
	if err := r.Seal(time.Now()); err == nil {
		t.Fatal("accepted missing eligibility barrier")
	}
	r = completeRecord()
	r.Cleanup.IDs = []int64{7}
	if err := r.Seal(time.Now()); err == nil {
		t.Fatal("accepted incomplete cleanup")
	}
	r = completeRecord()
	r.RunnerGroupPolicy = ""
	if err := r.Seal(time.Now()); err == nil {
		t.Fatal("accepted missing runner group policy")
	}
}
