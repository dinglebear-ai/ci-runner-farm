package nativebackend

import (
	"strings"
	"testing"

	"github.com/unraid/ci-runner-farm/internal/remotehost"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestAppliedProposalRequiresExactSavedSettingsPolicyAndInstalledTree(t *testing.T) {
	p := remotehost.SetupProposal{Version: 1, OperationID: strings.Repeat("a", 32), StageOperationID: strings.Repeat("b", 32), PackageSHA256: strings.Repeat("c", 64), Owner: "dinglebear-ai", Repository: "labby", MemoryMiB: 12288, VCPUs: 2, RunnerCount: 1}
	installed := InstallationIdentity{Protocol: "farm-native-installation/v1", Version: "0.1.0-test", TreeSHA256: strings.Repeat("d", 64), ManifestSHA256: strings.Repeat("e", 64), BackendSHA256: strings.Repeat("f", 64), Files: 12, Bytes: 1024}
	pkg := remotehost.PackageView{SHA256: p.PackageSHA256, Version: installed.Version, TreeSHA256: installed.TreeSHA256, ManifestSHA256: installed.ManifestSHA256, BackendSHA256: installed.BackendSHA256}
	resources := sharedcapacity.Resources{MemoryMiB: p.MemoryMiB, VCPUs: p.VCPUs}
	policy := hostcapacity.Config{Schema: 1, Host: "target", Epoch: strings.Repeat("1", 32), Organization: p.Owner, Mode: "active", LedgerPath: "/cache/native-capacity/ledger.db", ReceiptRoot: "/cache/native-capacity/receipts", TokenPath: "/config/token", LockPath: "/runtime/owner.lock", ScanRepositories: []string{"dinglebear-ai/labby"}, Policy: sharedcapacity.Policy{AgingSeconds: 30, Budget: resources, Pools: map[string]sharedcapacity.Pool{"build": {Cost: resources, Minimum: 1, Maximum: 1}}}}
	settings := map[string]string{"CI_PROVIDER": "github", "GH_SCOPE": "repo", "RUNNER_MODE": "single", "GH_OWNER": p.Owner, "GH_REPOS": "dinglebear-ai/labby", "RUNNER_COUNT": "1", "CACHE_ROOT": "/cache"}
	ledger := sharedcapacity.Diagnostics{PolicyMatches: true, Policy: policy.Policy, ActivePolicyDigest: strings.Repeat("2", 64), LedgerPolicyDigest: strings.Repeat("2", 64)}
	if _, err := verifyAppliedSetup(p, pkg, installed, settings, &policy, ledger, "/cache", "target"); err != nil {
		t.Fatal(err)
	}
	// A matching ledger badge alone cannot prove any requested configuration.
	for _, field := range []string{"repository", "mode", "cache", "tree", "package", "budget", "epoch", "policy", "scope", "extra-pool"} {
		q := policy
		q.Policy = policy.Policy
		s := map[string]string{}
		for k, v := range settings {
			s[k] = v
		}
		i := installed
		artifact := pkg
		d := ledger
		switch field {
		case "repository":
			s["GH_REPOS"] = "foreign/repo"
		case "mode":
			s["RUNNER_MODE"] = "scaleset"
		case "cache":
			s["CACHE_ROOT"] = "/foreign"
		case "tree":
			i.TreeSHA256 = strings.Repeat("0", 64)
		case "package":
			artifact.SHA256 = strings.Repeat("0", 64)
		case "budget":
			q.Policy.Budget.MemoryMiB++
		case "epoch":
			q.Epoch = ""
		case "policy":
			d.PolicyMatches = false
		case "extra-pool":
			q.Policy.Pools = map[string]sharedcapacity.Pool{"build": policy.Policy.Pools["build"], "extra": {Cost: sharedcapacity.Resources{MemoryMiB: 1024, VCPUs: 1}, Maximum: 1}}
			q.Consumers = map[string]hostcapacity.Consumer{"extra-owner": {Pools: []string{"extra"}}}
			d.Policy = q.Policy
			if err := q.Validate("target"); err != nil {
				t.Fatal("extra-pool fixture must be valid host policy", err)
			}
		case "scope":
			s["GH_SCOPE"] = "org"
		}
		if _, err := verifyAppliedSetup(p, artifact, i, s, &q, d, "/cache", "target"); err == nil {
			t.Fatal("false configured receipt", field)
		}
	}
}
