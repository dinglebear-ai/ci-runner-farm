package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/controller"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/probe"
)

func TestCompatibilityEvidenceContractProjectsVerifiedRecord(t *testing.T) {
	now := time.Date(2026, 8, 23, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "compatibility.json")
	record := probe.Record{
		PluginDigest: strings.Repeat("1", 64), HelperDigest: strings.Repeat("2", 64),
		ModuleRevision: "revision", GoVersion: "go1.test", ImageDigest: strings.Repeat("3", 64),
		DockerfileDigest: strings.Repeat("4", 64), EntrypointDigest: strings.Repeat("5", 64),
		Owner: "example", APIURL: "https://api.github.com", InstallationID: "install",
		HostID: "host", RunnerGroupID: 7, QuarantineRunnerGroupID: 8,
		RunnerGroupPolicy: "restricted", Capabilities: map[string]bool{},
		Cleanup: probe.Cleanup{Complete: true, IDs: []int64{}},
	}
	for _, capability := range probe.RequiredCapabilities() {
		record.Capabilities[capability] = true
	}
	if err := record.Seal(now); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := compatibilityEvidenceContract([]string{"--path", path}, now,
		func(path string, now time.Time) (probe.Record, error) {
			return probe.LoadFresh(path, now, 30*24*time.Hour)
		})
	if err != nil {
		t.Fatal(err)
	}
	if !got.OK || got.SchemaVersion != 1 || got.RecordID != record.CompatibilityRecordID ||
		got.TestedAt != now || got.RunnerGroupID != 7 || got.QuarantineRunnerGroupID != 8 ||
		len(got.Capabilities) != len(probe.RequiredCapabilities()) {
		t.Fatalf("unexpected compatibility projection: %#v", got)
	}
}

func TestCompatibilityEvidenceContractRequiresOneAbsolutePath(t *testing.T) {
	loader := func(string, time.Time) (probe.Record, error) { return probe.Record{}, nil }
	for _, args := range [][]string{
		{}, {"--path", "relative.json"}, {"--path", "/absolute.json", "extra"},
		{"--path", "/absolute.json", "--unknown"},
	} {
		if _, err := compatibilityEvidenceContract(args, time.Now(), loader); err == nil {
			t.Fatalf("accepted invalid arguments: %#v", args)
		}
	}
}

func TestSupervisorServerAuthorizesEffectiveUID(t *testing.T) {
	server := supervisorServer(filepath.Join(t.TempDir(), "control.sock"), nil)
	if server.AllowedUID == nil {
		t.Fatal("supervisor server did not bind a peer UID")
	}
	want := uint32(os.Geteuid())
	if got := *server.AllowedUID; got != want {
		t.Fatalf("supervisor server allowed UID %d, want effective UID %d", got, want)
	}
}

func TestScaleSetClientFactoryBindsDistinctClientIdentities(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("secret-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := controller.RuntimeConfig{GitHubConfigURL: "https://github.com/dinglebear-ai",
		Owner: "dinglebear-ai", Auth: controller.AuthConfig{Mode: "pat", TokenFile: path}}
	factory, err := newScaleSetClientFactory(cfg)
	if err != nil {
		t.Fatal(err)
	}
	admin, err := factory(scaleSetSystemInfo("controller", 0))
	if err != nil {
		t.Fatal(err)
	}
	ops, err := factory(scaleSetSystemInfo("listener", 74))
	if err != nil {
		t.Fatal(err)
	}
	rust, err := factory(scaleSetSystemInfo("listener", 70))
	if err != nil {
		t.Fatal(err)
	}
	if admin == ops || admin == rust || ops == rust {
		t.Fatal("scale sets shared one mutable client identity")
	}
	for _, tc := range []struct {
		client    *scaleset.Client
		subsystem string
		id        int
	}{{admin, "controller", 0}, {ops, "listener", 74}, {rust, "listener", 70}} {
		info := tc.client.SystemInfo()
		if info.System != "ci-runner-farm" || info.Subsystem != tc.subsystem || info.ScaleSetID != tc.id {
			t.Fatalf("unexpected client identity: %#v", info)
		}
	}
}

func TestNewScaleSetAPIReadsOnlyPrivateCredentialFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("secret-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := controller.RuntimeConfig{GitHubConfigURL: "https://github.com/dinglebear-ai",
		Owner: "dinglebear-ai", Auth: controller.AuthConfig{Mode: "pat", TokenFile: path}}
	if _, err := newScaleSetAPI(cfg); err != nil {
		t.Fatalf("private token rejected: %v", err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := newScaleSetAPI(cfg); err == nil {
		t.Fatal("broad token permissions accepted")
	}
}

func TestNewScaleSetAPIRejectsMixedOrIncompleteAuth(t *testing.T) {
	cfg := controller.RuntimeConfig{GitHubConfigURL: "https://github.com/dinglebear-ai",
		Owner: "dinglebear-ai", Auth: controller.AuthConfig{Mode: "github_app", AppClientID: "1",
			InstallationID: 2}}
	if _, err := newScaleSetAPI(cfg); err == nil {
		t.Fatal("GitHub App without a private key was accepted")
	}
	cfg.Auth.Mode = "unknown"
	if _, err := newScaleSetAPI(cfg); err == nil {
		t.Fatal("unknown auth mode was accepted")
	}
}

func TestNewScaleSetAPIAcceptsPrivateMultilineGitHubAppKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app.pem")
	key := "-----BEGIN PRIVATE KEY-----\nQUJDRA==\n-----END PRIVATE KEY-----\n"
	if err := os.WriteFile(path, []byte(key), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := controller.RuntimeConfig{GitHubConfigURL: "https://github.com/dinglebear-ai",
		Owner: "dinglebear-ai", Auth: controller.AuthConfig{Mode: "github_app",
			AppClientID: "1", InstallationID: 2, PrivateKeyFile: path}}
	if _, err := newScaleSetAPI(cfg); err != nil {
		t.Fatalf("private multiline app key rejected: %v", err)
	}
}

func TestLoadProbeConfigRejectsTrailingDataAndInvalidRuntime(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "probe.json")
	runtimeCfg := controller.RuntimeConfig{SchemaVersion: 1, ControllerInstanceID: "controller-1",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64),
		PluginDigest: strings.Repeat("1", 64), ImageDigest: strings.Repeat("2", 64),
		DockerfileDigest: strings.Repeat("3", 64), EntrypointDigest: strings.Repeat("4", 64),
		InstallationID: "installation", HostID: "host-1", Owner: "dinglebear-ai",
		RunnerGroupID: 7, QuarantineRunnerGroupID: 8, StateDir: filepath.Join(root, "state"),
		OwnershipPath: filepath.Join(root, "ownership.json"), HeartbeatSeconds: 1,
		Pools: []controller.PoolConfig{{ID: "rust", RoutingLabel: "ci-pool-rust",
			Labels: []string{"self-hosted", "linux", "x64", "ci-pool-rust"}}}}
	cfg := probeConfig{Runtime: runtimeCfg, Live: probe.LiveConfig{Owner: runtimeCfg.Owner,
		RunnerGroupName: "production", RunnerGroupPolicy: "selected_repositories"}}
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(data, []byte(" \n\t")...), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadProbeConfig(path); err != nil {
		t.Fatalf("valid probe config rejected: %v", err)
	}
	for _, suffix := range []string{"{}", "garbage", "["} {
		if err := os.WriteFile(path, append(append([]byte{}, data...), suffix...), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadProbeConfig(path); err == nil {
			t.Fatalf("accepted trailing probe payload %q", suffix)
		}
	}
	cfg.Runtime.Pools[0].Labels = []string{"self-hosted"}
	invalid, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, invalid, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadProbeConfig(path); err == nil {
		t.Fatal("probe accepted runtime config without its routing label")
	}
}

func TestNewScaleSetAPIRejectsSymlinkedCredential(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "token.real")
	link := filepath.Join(root, "token")
	if err := os.WriteFile(target, []byte("secret-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	cfg := controller.RuntimeConfig{GitHubConfigURL: "https://github.com/dinglebear-ai",
		Owner: "dinglebear-ai", Auth: controller.AuthConfig{Mode: "pat", TokenFile: link}}
	if _, err := newScaleSetAPI(cfg); err == nil {
		t.Fatal("symlinked token was accepted")
	}
}

func TestValidateRuntimeContractAcceptsGoldenConfig(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "runtime-config-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "runtime-config.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := validateRuntimeContract([]string{"--runtime-config", path})
	if err != nil {
		t.Fatalf("golden runtime config rejected: %v", err)
	}
	if result.SchemaVersion != 1 || result.PoolCount != 1 ||
		result.ConfigRevision != strings.Repeat("a", 64) ||
		result.OwnershipRevision != strings.Repeat("b", 64) {
		t.Fatalf("unexpected validation result: %#v", result)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"ok":true,"schema_version":1,"config_revision":"` + strings.Repeat("a", 64) +
		`","ownership_revision":"` + strings.Repeat("b", 64) + `","pool_count":1}`
	if string(encoded) != want {
		t.Fatalf("validation JSON = %s, want %s", encoded, want)
	}
}

func TestValidateRuntimeContractRejectsUnknownArguments(t *testing.T) {
	for _, args := range [][]string{
		{},
		{"--runtime-config", "testdata/runtime-config-v1.json", "extra"},
		{"--runtime-config", "testdata/runtime-config-v1.json", "--unknown"},
		{"--runtime-config", "testdata/runtime-config-v1.json"},
	} {
		if _, err := validateRuntimeContract(args); err == nil {
			t.Fatalf("accepted invalid arguments: %#v", args)
		}
	}
}

func TestSuperviseContractRequiresAbsolutePaths(t *testing.T) {
	valid := []string{"--socket", "/run/ci-runner-farm/control.sock", "--compatibility",
		"/var/lib/ci-runner-farm/compatibility.json", "--runtime-config",
		"/var/lib/ci-runner-farm/runtime.json"}
	if _, err := parseSuperviseContract(valid); err != nil {
		t.Fatalf("absolute supervision paths rejected: %v", err)
	}
	for _, pathIndex := range []int{1, 3, 5} {
		args := append([]string(nil), valid...)
		args[pathIndex] = "relative/path"
		if _, err := parseSuperviseContract(args); err == nil {
			t.Fatalf("accepted relative path in arguments: %#v", args)
		}
	}
}
