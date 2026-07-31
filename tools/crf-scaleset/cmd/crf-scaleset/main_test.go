package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/controller"
)

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
