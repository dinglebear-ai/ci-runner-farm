package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/actions/scaleset"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/controller"
	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/ipc"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/probe"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

const (
	moduleVersion  = "v0.4.0"
	moduleRevision = "035cda46ea086d5faaa13f4b17953112c1c7f295"
)

func main() {
	if len(os.Args) < 2 {
		fail("usage", "expected version, validate-frame, validate-runtime, request, probe, check-compatibility, compatibility-evidence, or supervise")
	}
	switch os.Args[1] {
	case "version":
		write(map[string]any{"ok": true, "go_version": runtime.Version(), "module_version": moduleVersion, "module_revision": moduleRevision})
	case "validate-frame":
		req, err := protocol.Decode(os.Stdin)
		if err != nil {
			fail("invalid_frame", err.Error())
		}
		write(protocol.Response{SchemaVersion: 1, RequestID: req.RequestID, OK: true})
	case "validate-runtime":
		result, err := validateRuntimeContract(os.Args[2:])
		if err != nil {
			fail("invalid_runtime_config", err.Error())
		}
		write(result)
	case "request":
		request(os.Args[2:])
	case "probe":
		runProbe(os.Args[2:])
	case "check-compatibility":
		flags := flag.NewFlagSet("check-compatibility", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		path := flags.String("path", "", "sealed compatibility record")
		if err := flags.Parse(os.Args[2:]); err != nil || *path == "" || flags.NArg() != 0 {
			fail("invalid_arguments", "check-compatibility requires --path")
		}
		record, err := verifiedCompatibility(*path)
		if err != nil {
			fail("invalid_compatibility_record", err.Error())
		}
		write(map[string]any{"ok": true, "compatibility_record_id": record.CompatibilityRecordID})
	case "compatibility-evidence":
		result, err := compatibilityEvidenceContract(os.Args[2:], time.Now().UTC(), verifiedCompatibilityAt)
		if err != nil {
			fail("invalid_compatibility_record", err.Error())
		}
		write(result)
	case "supervise":
		supervise(os.Args[2:])
	default:
		fail("unknown_command", os.Args[1])
	}
}

type compatibilityEvidenceResult struct {
	OK                      bool            `json:"ok"`
	SchemaVersion           int             `json:"schema_version"`
	RecordID                string          `json:"compatibility_record_id"`
	PluginDigest            string          `json:"plugin_digest"`
	HelperDigest            string          `json:"helper_digest"`
	ModuleRevision          string          `json:"module_revision"`
	GoVersion               string          `json:"go_version"`
	ImageDigest             string          `json:"image_digest"`
	DockerfileDigest        string          `json:"dockerfile_digest"`
	EntrypointDigest        string          `json:"entrypoint_digest"`
	Owner                   string          `json:"owner"`
	APIURL                  string          `json:"api_url"`
	InstallationID          string          `json:"installation_id"`
	HostID                  string          `json:"host_id"`
	RunnerGroupID           int64           `json:"runner_group_id"`
	QuarantineRunnerGroupID int64           `json:"quarantine_runner_group_id"`
	RunnerGroupPolicy       string          `json:"runner_group_policy"`
	Capabilities            map[string]bool `json:"capabilities"`
	TestedAt                time.Time       `json:"tested_at"`
	CleanupComplete         bool            `json:"cleanup_complete"`
}

type compatibilityLoader func(string, time.Time) (probe.Record, error)

func compatibilityEvidenceContract(args []string, now time.Time, load compatibilityLoader) (compatibilityEvidenceResult, error) {
	flags := flag.NewFlagSet("compatibility-evidence", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	path := flags.String("path", "", "absolute mode-0600 sealed compatibility record")
	if err := flags.Parse(args); err != nil || !filepath.IsAbs(*path) || flags.NArg() != 0 {
		return compatibilityEvidenceResult{}, errors.New("compatibility-evidence requires one absolute --path")
	}
	record, err := load(*path, now)
	if err != nil {
		return compatibilityEvidenceResult{}, err
	}
	required := probe.RequiredCapabilities()
	capabilities := make(map[string]bool, len(required))
	for _, name := range required {
		capabilities[name] = record.Capabilities[name]
	}
	return compatibilityEvidenceResult{OK: true, SchemaVersion: record.SchemaVersion,
		RecordID: record.CompatibilityRecordID, PluginDigest: record.PluginDigest,
		HelperDigest: record.HelperDigest, ModuleRevision: record.ModuleRevision,
		GoVersion: record.GoVersion, ImageDigest: record.ImageDigest,
		DockerfileDigest: record.DockerfileDigest, EntrypointDigest: record.EntrypointDigest,
		Owner: record.Owner, APIURL: record.APIURL, InstallationID: record.InstallationID,
		HostID: record.HostID, RunnerGroupID: record.RunnerGroupID,
		QuarantineRunnerGroupID: record.QuarantineRunnerGroupID,
		RunnerGroupPolicy:       record.RunnerGroupPolicy, Capabilities: capabilities,
		TestedAt: record.TestedAt, CleanupComplete: record.Cleanup.Complete}, nil
}

type runtimeValidationResult struct {
	OK                bool   `json:"ok"`
	SchemaVersion     int    `json:"schema_version"`
	ConfigRevision    string `json:"config_revision"`
	OwnershipRevision string `json:"ownership_revision"`
	PoolCount         int    `json:"pool_count"`
}

func validateRuntimeContract(args []string) (runtimeValidationResult, error) {
	flags := flag.NewFlagSet("validate-runtime", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	path := flags.String("runtime-config", "", "mode-0600 runtime configuration")
	if err := flags.Parse(args); err != nil || !filepath.IsAbs(*path) || flags.NArg() != 0 {
		return runtimeValidationResult{}, errors.New("validate-runtime requires --runtime-config")
	}
	cfg, err := controller.LoadRuntimeConfig(*path)
	if err != nil {
		return runtimeValidationResult{}, err
	}
	return runtimeValidationResult{OK: true, SchemaVersion: cfg.SchemaVersion,
		ConfigRevision: cfg.ConfigRevision, OwnershipRevision: cfg.OwnershipRevision,
		PoolCount: len(cfg.Pools)}, nil
}

type probeConfig struct {
	Runtime controller.RuntimeConfig `json:"runtime"`
	Live    probe.LiveConfig         `json:"live"`
}

func loadProbeConfig(path string) (probeConfig, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return probeConfig{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 256<<10 {
		return probeConfig{}, fmt.Errorf("probe_config_permissions_or_size")
	}
	file, err := os.Open(path)
	if err != nil {
		return probeConfig{}, err
	}
	defer func() { _ = file.Close() }()
	dec := json.NewDecoder(file)
	dec.DisallowUnknownFields()
	var cfg probeConfig
	if err := dec.Decode(&cfg); err != nil {
		return probeConfig{}, err
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return probeConfig{}, fmt.Errorf("probe_config_trailing_data")
	}
	if err := cfg.Runtime.Validate(); err != nil {
		return probeConfig{}, fmt.Errorf("invalid_runtime_config: %w", err)
	}
	if cfg.Live.Owner == "" || cfg.Live.Owner != cfg.Runtime.Owner ||
		cfg.Live.RunnerGroupName == "" || cfg.Live.RunnerGroupPolicy == "" {
		return probeConfig{}, fmt.Errorf("probe_identity_required")
	}
	return cfg, nil
}

func runProbe(args []string) {
	flags := flag.NewFlagSet("probe", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	configPath := flags.String("config", "", "mode-0600 live probe configuration")
	output := flags.String("output", "", "mode-0600 compatibility record")
	timeout := flags.Duration("timeout", 10*time.Minute, "live probe timeout")
	if err := flags.Parse(args); err != nil || *configPath == "" || *output == "" ||
		*timeout < time.Minute || *timeout > 30*time.Minute || flags.NArg() != 0 {
		fail("invalid_arguments", "probe requires --config, --output, and a bounded --timeout")
	}
	cfg, err := loadProbeConfig(*configPath)
	if err != nil {
		fail("invalid_probe_config", err.Error())
	}
	cfg.Live.HelperDigest, err = executableDigest()
	if err != nil {
		fail("helper_digest_failed", err.Error())
	}
	cfg.Live.ModuleRevision = moduleRevision
	cfg.Live.GoVersion = runtime.Version()
	api, err := newScaleSetAPI(cfg.Runtime)
	if err != nil {
		fail("github_client_failed", err.Error())
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	record, err := probe.RunLive(ctx, cfg.Live, api)
	if err != nil {
		fail("compatibility_probe_failed", err.Error())
	}
	if err := probe.WriteAtomic(*output, record); err != nil {
		fail("compatibility_record_write_failed", err.Error())
	}
	verified, err := probe.LoadFresh(*output, time.Now().UTC(), 30*24*time.Hour)
	if err != nil {
		fail("compatibility_record_verify_failed", err.Error())
	}
	write(map[string]any{"ok": true, "compatibility_record_id": verified.CompatibilityRecordID,
		"runner_group_id":            verified.RunnerGroupID,
		"quarantine_runner_group_id": verified.QuarantineRunnerGroupID,
		"cleanup_complete":           verified.Cleanup.Complete})
}

func supervise(args []string) {
	paths, err := parseSuperviseContract(args)
	if err != nil {
		fail("invalid_arguments", err.Error())
	}
	record, err := verifiedCompatibility(paths.compatibility)
	if err != nil {
		fail("invalid_compatibility_record", err.Error())
	}
	cfg, err := controller.LoadRuntimeConfig(paths.runtimeConfig)
	if err != nil {
		fail("invalid_runtime_config", err.Error())
	}
	if cfg.Owner != record.Owner || cfg.RunnerGroupID != record.RunnerGroupID ||
		cfg.QuarantineRunnerGroupID != record.QuarantineRunnerGroupID ||
		cfg.InstallationID != record.InstallationID || cfg.HostID != record.HostID ||
		cfg.PluginDigest != record.PluginDigest || cfg.ImageDigest != record.ImageDigest ||
		cfg.DockerfileDigest != record.DockerfileDigest ||
		cfg.EntrypointDigest != record.EntrypointDigest {
		fail("compatibility_identity_mismatch", "runtime package, image, owner, runner group, installation, or host differs from compatibility evidence")
	}
	api, err := newScaleSetAPI(cfg)
	if err != nil {
		fail("github_client_failed", err.Error())
	}
	control, err := controller.New(cfg, api)
	if err != nil {
		fail("controller_failed", err.Error())
	}
	defer control.Close()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := supervisorServer(paths.socket, control.Handle).Serve(ctx); err != nil {
		fail("supervisor_failed", err.Error())
	}
}

type superviseContract struct {
	socket        string
	compatibility string
	runtimeConfig string
}

func parseSuperviseContract(args []string) (superviseContract, error) {
	flags := flag.NewFlagSet("supervise", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	socket := flags.String("socket", "", "same-UID Unix socket")
	compatibility := flags.String("compatibility", "", "sealed compatibility record")
	runtimeConfig := flags.String("runtime-config", "", "mode-0600 runtime configuration")
	if err := flags.Parse(args); err != nil || !filepath.IsAbs(*socket) ||
		!filepath.IsAbs(*compatibility) || !filepath.IsAbs(*runtimeConfig) || flags.NArg() != 0 {
		return superviseContract{}, errors.New("supervise requires absolute --socket, --compatibility, and --runtime-config paths")
	}
	return superviseContract{socket: *socket, compatibility: *compatibility,
		runtimeConfig: *runtimeConfig}, nil
}

func supervisorServer(path string, handler ipc.Handler) *ipc.Server {
	allowedUID := uint32(os.Geteuid())
	return &ipc.Server{Path: path, Handler: handler, AllowedUID: &allowedUID}
}

func request(args []string) {
	flags := flag.NewFlagSet("request", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	socket := flags.String("socket", "", "same-UID Unix socket")
	timeout := flags.Duration("timeout", 30*time.Second, "request timeout")
	if err := flags.Parse(args); err != nil || *socket == "" || *timeout <= 0 ||
		*timeout > 2*time.Minute || flags.NArg() != 0 {
		fail("invalid_arguments", "request requires --socket and an optional bounded --timeout")
	}
	req, err := protocol.Decode(os.Stdin)
	if err != nil {
		fail("invalid_frame", err.Error())
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	response, err := (ipc.Client{Path: *socket}).Call(ctx, req)
	if err != nil {
		fail("request_failed", err.Error())
	}
	write(response)
	if !response.OK {
		os.Exit(2)
	}
}

func privateCredential(path string, max int64, multiline bool) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() <= 0 || info.Size() > max {
		return "", fmt.Errorf("credential_permissions_or_size")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(data))
	if value == "" || strings.ContainsRune(value, '\x00') ||
		(!multiline && strings.ContainsAny(value, "\r\n")) {
		return "", fmt.Errorf("invalid_credential")
	}
	return value, nil
}

type scaleSetClientFactory func(scaleset.SystemInfo) (*scaleset.Client, error)

func scaleSetSystemInfo(subsystem string, scaleSetID int64) scaleset.SystemInfo {
	return scaleset.SystemInfo{System: "ci-runner-farm", Version: moduleVersion,
		CommitSHA: moduleRevision, ScaleSetID: int(scaleSetID), Subsystem: subsystem}
}

func newScaleSetClientFactory(cfg controller.RuntimeConfig) (scaleSetClientFactory, error) {
	if cfg.GitHubConfigURL == "" || cfg.Owner == "" {
		return nil, fmt.Errorf("github_identity_required")
	}
	switch cfg.Auth.Mode {
	case "pat":
		token, err := privateCredential(cfg.Auth.TokenFile, 64<<10, false)
		if err != nil {
			return nil, err
		}
		return func(info scaleset.SystemInfo) (*scaleset.Client, error) {
			return scaleset.NewClientWithPersonalAccessToken(
				scaleset.NewClientWithPersonalAccessTokenConfig{GitHubConfigURL: cfg.GitHubConfigURL,
					PersonalAccessToken: token, SystemInfo: info})
		}, nil
	case "github_app":
		key, err := privateCredential(cfg.Auth.PrivateKeyFile, 64<<10, true)
		if err != nil {
			return nil, err
		}
		if cfg.Auth.AppClientID == "" || cfg.Auth.InstallationID <= 0 {
			return nil, fmt.Errorf("github_app_identity_required")
		}
		auth := scaleset.GitHubAppAuth{ClientID: cfg.Auth.AppClientID,
			InstallationID: cfg.Auth.InstallationID, PrivateKey: key}
		return func(info scaleset.SystemInfo) (*scaleset.Client, error) {
			return scaleset.NewClientWithGitHubApp(scaleset.ClientWithGitHubAppConfig{
				GitHubConfigURL: cfg.GitHubConfigURL, GitHubAppAuth: auth, SystemInfo: info})
		}, nil
	default:
		return nil, fmt.Errorf("unsupported_auth_mode")
	}
}

func newScaleSetAPI(cfg controller.RuntimeConfig) (crfgithub.ScaleSetAPI, error) {
	factory, err := newScaleSetClientFactory(cfg)
	if err != nil {
		return nil, err
	}
	admin, err := factory(scaleSetSystemInfo("controller", 0))
	if err != nil {
		return nil, err
	}
	return crfgithub.NewAdapterWithScaleSetClientFactory(admin, cfg.Owner,
		func(id int64) (*scaleset.Client, error) {
			if id <= 0 {
				return nil, fmt.Errorf("invalid scale set id")
			}
			return factory(scaleSetSystemInfo("listener", id))
		}), nil
}

func verifiedCompatibility(path string) (probe.Record, error) {
	return verifiedCompatibilityAt(path, time.Now().UTC())
}

func verifiedCompatibilityAt(path string, now time.Time) (probe.Record, error) {
	record, err := probe.LoadFresh(path, now, 30*24*time.Hour)
	if err != nil {
		return probe.Record{}, err
	}
	if record.ModuleRevision != moduleRevision || record.GoVersion != runtime.Version() {
		return probe.Record{}, fmt.Errorf("helper_identity_mismatch")
	}
	digest, err := executableDigest()
	if err != nil || digest != record.HelperDigest {
		return probe.Record{}, fmt.Errorf("helper_digest_mismatch")
	}
	return record, nil
}

func executableDigest() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", err
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = file.Close() }()
	sum := sha256.New()
	if _, err := io.Copy(sum, file); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", sum.Sum(nil)), nil
}

func write(v any) {
	if err := json.NewEncoder(os.Stdout).Encode(v); err != nil {
		os.Exit(1)
	}
}
func fail(code, message string) {
	write(map[string]any{"ok": false, "code": code, "error": message})
	os.Exit(2)
}
