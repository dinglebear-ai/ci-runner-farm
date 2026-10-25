package nativebackend

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/unraid/ci-runner-farm/internal/localchecks"
	"github.com/unraid/ci-runner-farm/pkg/githubapp"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
)

type Request struct {
	Action  string            `json:"action"`
	Args    []string          `json:"args,omitempty"`
	Values  map[string]string `json:"values,omitempty"`
	Value   string            `json:"value,omitempty"`
	Kind    string            `json:"kind,omitempty"`
	Confirm bool              `json:"confirm,omitempty"`
}
type Response struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	Data  any    `json:"data,omitempty"`
}
type Job struct {
	ID         string     `json:"id"`
	Action     string     `json:"action"`
	Status     string     `json:"status"`
	Output     string     `json:"output"`
	StartedAt  time.Time  `json:"startedAt"`
	FinishedAt *time.Time `json:"finishedAt,omitempty"`
	cancel     context.CancelFunc
	secrets    []string
}
type Runner interface {
	Run(context.Context, string, []string, string) (string, error)
}
type Service struct {
	mu              sync.Mutex
	engine          Runner
	config, runtime string
	active          *Job
	history         []Job
	accepting       bool
	quiescing       atomic.Bool
	wg              sync.WaitGroup
	ctx             context.Context
	cancel          context.CancelFunc
}

func New(engine Runner, config, runtime string) *Service {
	ctx, cancel := context.WithCancel(context.Background())
	return &Service{engine: engine, config: config, runtime: runtime, accepting: true, ctx: ctx, cancel: cancel}
}
func fail(code string) Response { return Response{Error: code} }
func success(data any) Response { return Response{OK: true, Data: data} }

var slotPattern = regexp.MustCompile(`^ci-runner(?:-[a-z][a-z0-9-]{0,23})?-[1-9][0-9]?$`)
var tokenPattern = regexp.MustCompile(`^[A-Za-z0-9_]{20,255}$`)
var githubToken = regexp.MustCompile(`(?:github_pat_[A-Za-z0-9_]{10,}|gh[pousr]_[A-Za-z0-9_]{10,})`)
var numberPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)

// ValidateOperation is a closed typed command interface, never a shell command string.
func ValidateOperation(r Request) (string, []string, error) {
	if len(r.Args) > 2 {
		return "", nil, errors.New("invalid_arguments")
	}
	switch r.Action {
	case "start", "stop", "restart", "validate", "build-image", "reconcile-config", "reconcile-network", "prune-cache", "cache-clear-pkg", "credential-clear-github-token", "credential-clear-registry-token":
		if len(r.Args) != 0 {
			return "", nil, errors.New("invalid_arguments")
		}
		if (r.Action == "stop" || r.Action == "restart" || r.Action == "cache-clear-pkg" || r.Action == "prune-cache" || strings.HasPrefix(r.Action, "credential-clear-")) && !r.Confirm {
			return "", nil, errors.New("confirmation_required")
		}
		return r.Action, nil, nil
	case "scale":
		if len(r.Args) != 1 || !numberPattern.MatchString(r.Args[0]) || len(r.Args[0]) > 2 {
			return "", nil, errors.New("invalid_scale")
		}
		var n int
		fmt.Sscanf(r.Args[0], "%d", &n)
		if n > 64 {
			return "", nil, errors.New("invalid_scale")
		}
		return "scale", r.Args, nil
	case "recycle":
		if len(r.Args) != 1 || !slotPattern.MatchString(r.Args[0]) || !r.Confirm {
			return "", nil, errors.New("invalid_slot_or_confirmation")
		}
		return "recycle", r.Args, nil
	case "prune-completed-docker":
		if len(r.Args) != 1 || (r.Args[0] != "--dry-run" && r.Args[0] != "--apply") || r.Args[0] == "--apply" && !r.Confirm {
			return "", nil, errors.New("invalid_prune")
		}
		return r.Action, r.Args, nil
	case "prune-retired-docker":
		return r.Action, []string{"--dry-run"}, nil
	}
	return "", nil, errors.New("unsupported_operation")
}

func (s *Service) Handle(r Request) Response {
	switch r.Action {
	case "remote-host-list", "remote-host-create", "remote-host-status", "remote-package-upload", "remote-package-list", "remote-package-stage", "remote-package-observe":
		return s.remoteHosts(r)
	case "local-checks-contract":
		return success(localchecks.NativeWorkerContract())
	case "local-checks":
		if _, err := localchecks.DecodeNativeCommand(strings.NewReader(r.Value)); err != nil {
			return fail("local_checks_native_command_invalid")
		}
		if len(r.Args) != 0 || r.Kind != "" || len(r.Values) > 1 {
			return fail("local_checks_native_command_invalid")
		}
		for name := range r.Values {
			if name != "dependencyCredential" {
				return fail("local_checks_native_command_invalid")
			}
		}
		engine, ok := s.engine.(*Engine)
		if !ok {
			return fail("local_checks_native_engine_required")
		}
		return s.launch(r, func(ctx context.Context) (string, error) {
			return engine.RunLocalChecks(ctx, r.Value, r.Values["dependencyCredential"])
		})
	case "job-status":
		s.mu.Lock()
		defer s.mu.Unlock()
		var active any
		if s.active != nil {
			copy := *s.active
			if b, err := readBounded(filepath.Join(s.runtime, "native-operation.log"), 512<<10); err == nil {
				copy.Output = tail(redactValues(s.redact(string(b)), s.active.secrets), 32768)
			}
			active = copy
		}
		return success(map[string]any{"active": active, "history": append([]Job(nil), s.history...), "accepting": s.accepting})
	case "cancel":
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.active == nil {
			return fail("no_active_job")
		}
		if !r.Confirm {
			return fail("confirmation_required")
		}
		s.active.cancel()
		return success(map[string]string{"status": "cancellation_requested", "warning": "Partial effects may remain; inspect results before retrying."})
	case "abort-unload":
		s.mu.Lock()
		defer s.mu.Unlock()
		s.accepting = true
		s.quiescing.Store(false)
		return success(nil)
	case "prepare-unload":
		return s.prepareUnload()
	case "settings", "settings-defaults", "credential-status", "toggle-toolchain", "admission-status", "dashboard-json", "fleet-overview-json", "status-json", "recommendations-json", "image-info-json", "queued-json", "stats-json", "cache-usage-json", "farm-log", "build-log", "runner-log", "get-dockerfile", "get-default-dockerfile":
		return s.query(r)
	case "complete-migration":
		if !r.Confirm {
			return fail("confirmation_required")
		}
		return s.launch(r, func(ctx context.Context) (string, error) { return s.completeMigration(ctx, r.Values) })
	case "recover-admission":
		if !r.Confirm {
			return fail("confirmation_required")
		}
		return s.launch(r, func(ctx context.Context) (string, error) { return s.recoverAdmission(ctx) })
	case "initialize-admission":
		if !r.Confirm {
			return fail("confirmation_required")
		}
		return s.launch(r, func(ctx context.Context) (string, error) { return s.initializeAdmission(ctx, r.Values) })
	case "set-config":
		return s.launch(r, func(ctx context.Context) (string, error) { return s.saveConfig(ctx, r.Values) })
	case "set-credential":
		return s.launch(r, func(ctx context.Context) (string, error) { return s.writeCredential(r) })
	case "save-dockerfile", "save-build-image":
		return s.launch(r, func(ctx context.Context) (string, error) {
			if strings.TrimSpace(r.Value) == "" || strings.ContainsRune(r.Value, 0) || len(r.Value) > 2<<20 {
				return "", errors.New("invalid_dockerfile")
			}
			if err := atomicWrite(filepath.Join(s.config, "Dockerfile.github"), []byte(r.Value), 0600); err != nil {
				return "", err
			}
			if r.Action == "save-build-image" {
				return s.engine.Run(ctx, "build-image", nil, "")
			}
			return "Dockerfile saved; build separately.", nil
		})
	default:
		action, args, err := ValidateOperation(r)
		if err != nil {
			return fail(err.Error())
		}
		return s.launch(r, func(ctx context.Context) (string, error) { return s.engine.Run(ctx, action, args, "") })
	}
}

func (s *Service) launch(r Request, run func(context.Context) (string, error)) Response {
	if s.quiescing.Load() {
		return fail("backend_quiesced")
	}
	if !s.mu.TryLock() {
		return fail("backend_busy")
	}
	defer s.mu.Unlock()
	if !s.accepting || s.quiescing.Load() {
		return fail("backend_quiesced")
	}
	if s.active != nil {
		return fail("backend_busy")
	}
	// Observe scheduling authority under the same gate as operator admission.
	// A tick observed before Stop cannot execute after Stop has revoked intent.
	if strings.HasPrefix(r.Action, "scheduled-") {
		if _, err := os.Stat(filepath.Join(s.config, "native-fleet.enabled")); err != nil {
			return fail("fleet_maintenance_disabled")
		}
	}
	if r.Action == "stop" || r.Action == "restart" || (r.Action == "scale" && len(r.Args) == 1 && r.Args[0] == "0") {
		if err := s.disableMaintenance(); err != nil {
			return fail("maintenance_revocation_failed")
		}
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return fail("random_unavailable")
	}
	budget := 15 * time.Minute
	if r.Action == "local-checks" {
		budget = 24*time.Hour + time.Minute
	}
	if r.Action == "scheduled-boot-autostart" {
		budget = 25 * time.Minute
	}
	if r.Action == "build-image" || r.Action == "save-build-image" {
		budget = time.Hour
	}
	if r.Action == "build-image" || r.Action == "save-build-image" {
		if err := atomicWrite(filepath.Join(s.runtime, "native-build.log"), nil, 0600); err != nil {
			return fail("build_log_unavailable")
		}
	}
	ctx, cancel := context.WithTimeout(s.ctx, budget)
	secrets := s.secretValues()
	if r.Action == "local-checks" && r.Values["dependencyCredential"] != "" {
		secrets = append(secrets, r.Values["dependencyCredential"])
	}
	job := &Job{ID: hex.EncodeToString(id), Action: r.Action, Status: "running", StartedAt: time.Now().UTC(), cancel: cancel, secrets: secrets}
	// Never expose a previous operation's raw progress as the new job.
	if err := atomicWrite(filepath.Join(s.runtime, "native-operation.log"), nil, 0600); err != nil {
		cancel()
		return fail("operation_log_unavailable")
	}
	s.active = job
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer cancel()
		var out string
		err := ctx.Err()
		if err == nil {
			out, err = run(ctx)
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		job.Output = redactValues(s.redact(out), secrets)
		now := time.Now().UTC()
		job.Output = tail(job.Output, 32768)
		job.FinishedAt = &now
		job.Status = "passed"
		if err != nil {
			job.Status = "failed"
			job.Output += "\nOperation failed: " + redactValues(s.redact(err.Error()), secrets) + "; partial effects may remain."
		}
		if ctx.Err() != nil {
			job.Status = "cancelled"
			job.Output += "\nCancellation or deadline: inspect and reconcile existing ownership before retrying."
		}
		if err == nil && ctx.Err() == nil {
			switch r.Action {
			case "start", "restart":
				err = atomicWrite(filepath.Join(s.config, "native-fleet.enabled"), []byte("enabled\n"), 0600)
			case "scale":
				if len(r.Args) == 1 && r.Args[0] == "0" {
					err = os.Remove(filepath.Join(s.config, "native-fleet.enabled"))
					if errors.Is(err, os.ErrNotExist) {
						err = nil
					}
				} else {
					err = atomicWrite(filepath.Join(s.config, "native-fleet.enabled"), []byte("enabled\n"), 0600)
				}
			case "stop":
				err = os.Remove(filepath.Join(s.config, "native-fleet.enabled"))
				if errors.Is(err, os.ErrNotExist) {
					err = nil
				}
			}
		}
		if err != nil && job.Status == "passed" {
			job.Status = "failed"
			job.Output += "\nFleet changed but startup preference could not be persisted; inspect before retrying."
		}
		for _, name := range []string{"native-operation.log", "native-build.log"} {
			if raw, readErr := readBounded(filepath.Join(s.runtime, name), 512<<10); readErr == nil {
				_ = atomicWrite(filepath.Join(s.runtime, name), []byte(redactValues(s.redact(string(raw)), secrets)), 0600)
			}
		}

		job.secrets = nil
		s.history = append([]Job{*job}, s.history...)
		if len(s.history) > 10 {
			s.history = s.history[:10]
		}
		s.active = nil
	}()
	return success(map[string]string{"jobId": job.ID})
}

func (s *Service) disableMaintenance() error {
	path := filepath.Join(s.config, "native-fleet.enabled")
	if err := os.Remove(path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	return syncParent(path)
}

func (s *Service) query(r Request) Response {
	if s.quiescing.Load() {
		return fail("backend_quiesced")
	}
	if !s.mu.TryLock() {
		return fail("backend_busy")
	}
	defer s.mu.Unlock()
	if s.active != nil && r.Action != "build-log" {
		return fail("backend_busy")
	}
	ctx, cancel := context.WithTimeout(s.ctx, 10*time.Second)
	defer cancel()
	if r.Action == "get-dockerfile" || r.Action == "get-default-dockerfile" {
		return s.queryDockerfile(r.Action)
	}
	if r.Action == "toggle-toolchain" {
		return s.toggleToolchain(r)
	}
	if r.Action == "credential-status" {
		return s.credentialStatus()
	}
	if r.Action == "settings-defaults" {
		return s.queryDefaults(ctx)
	}
	if r.Action == "build-log" {
		b, err := readBounded(filepath.Join(s.runtime, "native-build.log"), 512<<10)
		if err != nil {
			return fail("build_log_unavailable")
		}
		if len(b) > 512<<10 {
			b = b[len(b)-(512<<10):]
		}
		out := s.redact(string(b))
		if s.active != nil {
			out = redactValues(out, s.active.secrets)
		}
		return success(out)
	}
	action := r.Action
	if action == "admission-status" {
		action = "native-admission-status"
	}
	args := []string{}
	if action == "settings" {
		action = "native-config-json"
	}
	if action == "runner-log" {
		if len(r.Args) != 1 || !slotPattern.MatchString(r.Args[0]) {
			return fail("invalid_slot")
		}
		action = "logs-tail"
		args = []string{r.Args[0], "150"}
	}
	out, err := s.engine.Run(ctx, action, args, "")
	if err != nil {
		return fail("engine_query_failed")
	}
	out = s.redact(out)
	if strings.HasSuffix(action, "-json") || action == "native-admission-status" {
		var data any
		if json.Unmarshal([]byte(out), &data) != nil {
			return fail("invalid_engine_response")
		}
		return success(data)
	}
	return success(out)
}

func (s *Service) prepareUnload() Response {
	// Close admission before acquiring observation ownership. Never wait behind
	// an expired socket request and then launch its delayed inspection.
	s.quiescing.Store(true)
	if !s.mu.TryLock() {
		return fail("inspection_prevents_unload")
	}
	defer s.mu.Unlock()
	s.accepting = false
	if s.active != nil {
		return fail("active_job_prevents_unload")
	}
	ctx, cancel := context.WithTimeout(s.ctx, 10*time.Second)
	defer cancel()
	out, err := s.engine.Run(ctx, "native-unload-inventory", nil, "")
	if err != nil {
		return fail("fleet_state_unavailable")
	}
	var state struct {
		Schema     string `json:"schema"`
		Containers *int   `json:"containers"`
		Grants     *int   `json:"grants"`
		Pending    *int   `json:"pending"`
		Consumers  *int   `json:"consumers"`
	}
	if json.Unmarshal([]byte(out), &state) != nil || state.Schema != "native-unload-v1" || state.Containers == nil || state.Grants == nil || state.Pending == nil || state.Consumers == nil || *state.Consumers < 0 || *state.Containers < 0 || *state.Grants < 0 || *state.Pending < 0 {
		return fail("fleet_state_unavailable")
	}
	if *state.Consumers != 0 {
		return fail("shared_consumers_require_fenced_handoff")
	}
	if *state.Containers != 0 || *state.Grants != 0 || *state.Pending != 0 {
		return fail("running_fleet_prevents_unload")
	}
	return success(nil)
}
func (s *Service) Shutdown() {
	s.cancel()
	s.mu.Lock()
	s.accepting = false
	s.mu.Unlock()
	s.wg.Wait()
}

func (s *Service) saveConfig(ctx context.Context, values map[string]string) (string, error) {
	if e, ok := s.engine.(*Engine); ok && (e.BoundCache == "" || values["CACHE_ROOT"] != e.BoundCache) {
		return "", errors.New("config_cache_must_match_core_binding")
	}
	out, err := s.engine.Run(ctx, "native-config-json", nil, "")
	if err != nil {
		return "", err
	}
	var defaults map[string]string
	if json.Unmarshal([]byte(out), &defaults) != nil {
		return "", errors.New("config_schema_unavailable")
	}
	for k, v := range values {
		if _, ok := defaults[k]; !ok || len(v) > 16384 || strings.ContainsAny(v, "\x00\r\n\"'") {
			return "", errors.New("invalid_config_field")
		}
		defaults[k] = v
	}
	keys := make([]string, 0, len(defaults))
	for k := range defaults {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString("CI_PROVIDER=\"github\"\n")
	for _, k := range keys {
		fmt.Fprintf(&b, "%s=\"%s\"\n", k, defaults[k])
	}
	candidate, err := os.CreateTemp(s.config, ".native-config-")
	if err != nil {
		return "", err
	}
	p := candidate.Name()
	defer os.Remove(p)
	if err = candidate.Chmod(0600); err != nil {
		candidate.Close()
		return "", err
	}
	_, err = candidate.WriteString(b.String())
	if err == nil {
		err = candidate.Sync()
	}
	closeErr := candidate.Close()
	if err != nil {
		return "", err
	}
	if closeErr != nil {
		return "", closeErr
	}
	checked, err := s.engine.Run(ctx, "native-config-check", nil, p)
	if err != nil {
		return checked, err
	}
	roundTrip, err := s.engine.Run(ctx, "native-config-json", nil, p)
	if err != nil {
		return "", err
	}
	var parsed map[string]string
	if json.Unmarshal([]byte(roundTrip), &parsed) != nil {
		return "", errors.New("invalid_config_round_trip")
	}
	for key, want := range defaults {
		if parsed[key] != want {
			return "", errors.New("config_value_rejected_by_engine")
		}
	}
	if err = os.Rename(p, filepath.Join(s.config, "ci-runner-farm.cfg")); err != nil {
		return "", err
	}
	// Same engine handles idle-preserving configuration migration; the native
	// owner schedules its foreground drain rather than a detached shell worker.
	return s.engine.Run(ctx, "reconcile-config", nil, "")
}
func (s *Service) writeCredential(r Request) (string, error) {
	var name string
	switch r.Kind {
	case "github-token":
		r.Value = strings.Trim(r.Value, " \t\r\n")
		if !tokenPattern.MatchString(r.Value) {
			return "", errors.New("invalid_github_token")
		}
		name = "token"
	case "registry-token":
		if len(r.Value) == 0 || len(r.Value) > 8192 || strings.IndexFunc(r.Value, func(r rune) bool { return r < 32 || r == unicode.MaxASCII }) >= 0 {
			return "", errors.New("invalid_registry_token")
		}
		name = "registry-token"
	case "github-app-key":
		if len(r.Value) > 32768 || githubapp.ValidatePrivateKey([]byte(r.Value)) != nil {
			return "", errors.New("invalid_app_key")
		}
		name = "github-app-key.pem"
	default:
		return "", errors.New("unsupported_credential")
	}
	return "Credential saved; its value is never returned.", atomicWrite(filepath.Join(s.config, name), []byte(r.Value), 0600)
}
func (s *Service) redact(out string) string {
	for _, name := range []string{"token", "registry-token", "github-app-key.pem"} {
		if b, err := os.ReadFile(filepath.Join(s.config, name)); err == nil && len(b) >= 4 {
			out = strings.ReplaceAll(out, strings.TrimRight(string(b), "\n"), "[REDACTED]")
		}
	}
	return githubToken.ReplaceAllString(out, "[REDACTED_GITHUB_TOKEN]")
}
func atomicWrite(path string, b []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".native-write-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	return syncParent(path)
}

func redactValues(out string, values []string) string {
	for _, secret := range values {
		if len(secret) >= 4 {
			out = strings.ReplaceAll(out, secret, "[REDACTED]")
		}
	}
	return out
}

func (s *Service) secretValues() []string {
	var values []string
	for _, name := range []string{"token", "registry-token", "github-app-key.pem"} {
		if b, err := readBounded(filepath.Join(s.config, name), 32768); err == nil && len(b) >= 4 {
			values = append(values, strings.TrimRight(string(b), "\n"))
		}
	}
	return values
}
func readBounded(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, errors.New("file_exceeds_bound")
	}
	return b, nil
}

func tail(value string, limit int) string {
	if len(value) > limit {
		return value[len(value)-limit:]
	}
	return value
}

func syncParent(path string) error {
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
