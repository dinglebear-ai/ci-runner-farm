package nativebackend

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestDockerfileLoadMatchesClassicFallbackOrderAndPreservesCustomFile(t *testing.T) {
	root, config := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "default.github.Dockerfile"), []byte("FROM shipped"), 0600); err != nil {
		t.Fatal(err)
	}
	e := &Engine{Root: root}
	s := New(e, config, t.TempDir())
	defer s.Shutdown()
	assertRead := func(want string) {
		t.Helper()
		r := s.Handle(Request{Action: "get-dockerfile"})
		if !r.OK || r.Data != want {
			t.Fatal("classic fallback mismatch", r)
		}
	}
	assertRead("FROM shipped")
	original := []byte("FROM custom-legacy")
	if err := os.WriteFile(filepath.Join(config, "Dockerfile"), original, 0600); err != nil {
		t.Fatal(err)
	}
	assertRead(string(original))
	if err := os.WriteFile(filepath.Join(config, "Dockerfile.github"), []byte("FROM custom-current"), 0600); err != nil {
		t.Fatal(err)
	}
	assertRead("FROM custom-current")
	got, _ := os.ReadFile(filepath.Join(config, "Dockerfile"))
	if string(got) != string(original) {
		t.Fatal("load mutated legacy custom file")
	}
}
func TestDockerfileSupportsClassicTwoMiBBoundAndRejectsInvalidInput(t *testing.T) {
	for _, tc := range []struct {
		body  string
		valid bool
	}{{strings.Repeat("x", 2<<20), true}, {strings.Repeat("x", (2<<20)+1), false}, {" \t\n", false}, {"FROM x\x00", false}} {
		s := New(&fakeRunner{}, t.TempDir(), t.TempDir())
		r := s.Handle(Request{Action: "save-dockerfile", Value: tc.body})
		if !r.OK {
			t.Fatal(r)
		}
		s.wg.Wait()
		b, err := os.ReadFile(filepath.Join(s.config, "Dockerfile.github"))
		if tc.valid && (err != nil || string(b) != tc.body) {
			t.Fatal("classic supported Dockerfile rejected", err)
		}
		if !tc.valid && err == nil {
			t.Fatal("invalid Dockerfile saved")
		}
		s.Shutdown()
	}
}

func TestDefaultsPreviewUsesOriginalEngineAndPreservesSavedSettingsAndCache(t *testing.T) {
	root := t.TempDir()
	e := &Engine{Root: filepath.Join(root, "engine"), Config: t.TempDir(), Runtime: t.TempDir(), CapacityRoot: t.TempDir(), Executable: "/bin/false", BoundCache: "/mnt/existing/farm"}
	if err := e.Extract(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(e.Config, "ci-runner-farm.cfg")
	original := []byte("RUNNER_COUNT=\"7\"\nGH_OWNER=\"original-owner\"\n")
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	s := New(e, e.Config, e.Runtime)
	defer s.Shutdown()
	r := s.Handle(Request{Action: "settings-defaults"})
	if !r.OK {
		t.Fatal(r)
	}
	values, ok := r.Data.(map[string]string)
	if !ok || values["RUNNER_COUNT"] != "4" || values["CACHE_ROOT"] != e.BoundCache {
		t.Fatal(values)
	}
	got, _ := os.ReadFile(path)
	if string(got) != string(original) {
		t.Fatal("defaults preview changed saved settings")
	}
}
func TestCredentialStatusReturnsPresenceOnlyAndNeverFollowsSymlinks(t *testing.T) {
	s := New(&fakeRunner{}, t.TempDir(), t.TempDir())
	defer s.Shutdown()
	if err := os.WriteFile(filepath.Join(s.config, "token"), []byte("private-dummy-token"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(s.config, "token"), filepath.Join(s.config, "registry-token")); err != nil {
		t.Fatal(err)
	}
	r := s.Handle(Request{Action: "credential-status"})
	status, ok := r.Data.(map[string]bool)
	if !r.OK || !ok || !status["github-token"] || status["registry-token"] || status["github-app-key"] {
		t.Fatal(r)
	}
}
func TestToolchainEditsMatchClassicBlocksAndNeverSaveOrBuild(t *testing.T) {
	s := New(&fakeRunner{}, t.TempDir(), t.TempDir())
	defer s.Shutdown()
	for _, kind := range []string{"rust", "python", "node", "android"} {
		original := "FROM debian\nCMD [\"bash\"]\n"
		r := s.Handle(Request{Action: "toggle-toolchain", Kind: kind, Value: original})
		if !r.OK {
			t.Fatal(r)
		}
		edited := r.Data.(string)
		start := "# >>> ci-runner-farm toolchain: " + kind + " >>>"
		if strings.Count(edited, start) != 1 || strings.Index(edited, start) > strings.Index(edited, "CMD ") {
			t.Fatal("toolchain not inserted before final CMD")
		}
		r = s.Handle(Request{Action: "toggle-toolchain", Kind: kind, Value: edited})
		if !r.OK || strings.Contains(r.Data.(string), start) {
			t.Fatal("toolchain removal failed", r)
		}
	}
	if s.Handle(Request{Action: "toggle-toolchain", Kind: "arbitrary-shell", Value: "FROM x"}).OK {
		t.Fatal("unknown toolchain accepted")
	}
	if s.Handle(Request{Action: "toggle-toolchain", Kind: "rust", Value: "# >>> ci-runner-farm toolchain: rust >>>"}).OK {
		t.Fatal("ambiguous partial block accepted")
	}
	entries, _ := os.ReadDir(s.config)
	if len(entries) != 0 {
		t.Fatal("toolchain preview wrote files")
	}
}
func TestSaveAndBuildUsesNewSavedDockerfileInOneOwnedJob(t *testing.T) {
	config := t.TempDir()
	calls := 0
	runner := recoveryRunner{call: func(action string, _ []string) (string, error) {
		calls++
		if action != "build-image" {
			t.Fatal(action)
		}
		b, err := os.ReadFile(filepath.Join(config, "Dockerfile.github"))
		if err != nil || string(b) != "FROM edited" {
			t.Fatal("build preceded save", err)
		}
		return "built", nil
	}}
	s := New(runner, config, t.TempDir())
	defer s.Shutdown()
	if !s.Handle(Request{Action: "save-build-image", Value: "FROM edited"}).OK {
		t.Fatal("save/build refused")
	}
	s.wg.Wait()
	if calls != 1 {
		t.Fatal("build missing/duplicated")
	}
}

func TestDisabledNativeDashboardDoesNotRequireDocker(t *testing.T) {
	e := &Engine{Root: t.TempDir(), Config: t.TempDir(), Runtime: t.TempDir(), CapacityRoot: t.TempDir(), Executable: "/bin/false"}
	if err := e.Extract(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(e.Config, "ci-runner-farm.cfg"), []byte("DASHBOARD_WIDGET_ENABLE=\"false\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	out, err := e.Run(t.Context(), "dashboard-json", nil, "")
	if err != nil || strings.TrimSpace(out) != `{"enabled":false}` {
		t.Fatal("disabled dashboard still inspected fleet", out, err)
	}
}

func TestSocketParserSupportsWorstCaseClassicDockerfileAndKeepsHardBound(t *testing.T) {
	request := Request{Action: "save-dockerfile", Value: strings.Repeat("\x01", 2<<20)}
	wire, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := decodeRequest(bytes.NewReader(wire))
	if err != nil || parsed.Value != request.Value {
		t.Fatal("classic size cannot traverse actual socket parser", err)
	}
	oversized := []byte(`{"action":"save-dockerfile","value":"` + strings.Repeat("x", maxRequestBytes) + `"}`)
	if _, err := decodeRequest(bytes.NewReader(oversized)); err == nil {
		t.Fatal("socket request bound bypassed")
	}
	if _, err := decodeRequest(strings.NewReader(`{"action":"settings","arbitrary":true}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}
func TestToolchainProjectionMatchesActualClassicAuthoring(t *testing.T) {
	source, err := os.ReadFile("../../src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page")
	if err != nil {
		t.Fatal(err)
	}
	pattern := regexp.MustCompile(`(?s)\$crfi_tc\['([a-z]+)'\] = <<<'DFBLOCK'\n(.*?)\nDFBLOCK;`)
	var projected map[string]string
	if err := json.Unmarshal(toolchainProjection, &projected); err != nil {
		t.Fatal(err)
	}
	matches := pattern.FindAllStringSubmatch(string(source), -1)
	if len(matches) != 4 || len(projected) != 4 {
		t.Fatal("toolchain source contract changed")
	}
	for _, match := range matches {
		if projected[match[1]] != match[2] {
			t.Fatal("stale toolchain projection", match[1])
		}
	}
}

func TestGitHubPATSaveAcceptsOrdinaryPasteWhitespaceLikeClassic(t *testing.T) {
	s := New(&fakeRunner{}, t.TempDir(), t.TempDir())
	defer s.Shutdown()
	token := "ghp_abcdefghijklmnopqrstuvwxyz123456"
	if _, err := s.writeCredential(Request{Kind: "github-token", Value: " \t" + token + "\r\n"}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(s.config, "token"))
	if err != nil || string(got) != token {
		t.Fatal("pasted token normalization differs", err)
	}
	if _, err := s.writeCredential(Request{Kind: "github-token", Value: token + "\x00"}); err == nil {
		t.Fatal("NUL token accepted")
	}
}
