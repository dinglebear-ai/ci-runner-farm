package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/actions/scaleset"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/controller"
)

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
