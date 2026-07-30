package probe

import (
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
		Capabilities: caps, Cleanup: Cleanup{Complete: true}}
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
}
