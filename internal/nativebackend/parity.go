package nativebackend

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Classic precedence: provider-specific save, legacy GitHub save, shipped default.
// A present but unreadable/oversized saved file is an error, never a silent reset.
func (s *Service) queryDockerfile(action string) Response {
	e, ok := s.engine.(*Engine)
	if !ok {
		return fail("engine_unavailable")
	}
	paths := []string{filepath.Join(e.Root, "default.github.Dockerfile")}
	if action == "get-dockerfile" {
		paths = append([]string{filepath.Join(s.config, "Dockerfile.github"), filepath.Join(s.config, "Dockerfile")}, paths...)
	}
	for _, path := range paths {
		b, err := readBounded(path, 2<<20)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return fail("dockerfile_unavailable")
		}
		return success(string(b))
	}
	return fail("dockerfile_unavailable")
}
func (s *Service) queryDefaults(ctx context.Context) Response {
	// Parse an empty task-owned candidate through the original default/parser
	// contract. Loading defaults is a preview and never changes retained settings.
	f, err := os.CreateTemp(s.runtime, ".defaults-preview-")
	if err != nil {
		return fail("defaults_unavailable")
	}
	defer os.Remove(f.Name())
	if err = f.Close(); err != nil {
		return fail("defaults_unavailable")
	}
	out, err := s.engine.Run(ctx, "native-config-json", nil, f.Name())
	if err != nil {
		return fail("defaults_unavailable")
	}
	var data map[string]string
	if json.Unmarshal([]byte(out), &data) != nil {
		return fail("defaults_unavailable")
	}
	if e, ok := s.engine.(*Engine); ok {
		data["CACHE_ROOT"] = e.BoundCache
	}
	return success(data)
}
func (s *Service) credentialStatus() Response {
	status := map[string]bool{}
	for kind, name := range map[string]string{"github-token": "token", "github-app-key": "github-app-key.pem", "registry-token": "registry-token"} {
		info, err := os.Lstat(filepath.Join(s.config, name))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return fail("credential_status_unavailable")
		}
		status[kind] = err == nil && info.Mode().IsRegular() && info.Size() > 0
	}
	return success(status)
}

//go:embed toolchains.json
var toolchainProjection []byte

func (s *Service) toggleToolchain(r Request) Response {
	var blocks map[string]string
	if json.Unmarshal(toolchainProjection, &blocks) != nil {
		return fail("toolchains_unavailable")
	}
	block, ok := blocks[r.Kind]
	if !ok || len(r.Value) > 2<<20 || strings.ContainsRune(r.Value, 0) {
		return fail("invalid_toolchain_edit")
	}
	start := "# >>> ci-runner-farm toolchain: " + r.Kind + " >>>"
	end := "# <<< ci-runner-farm toolchain: " + r.Kind + " <<<"
	text := r.Value
	if strings.Contains(text, start) {
		if !strings.Contains(text, end) {
			return fail("toolchain_marker_incomplete_repair_editor")
		}
		pattern := regexp.MustCompile(`(?s)\n?` + regexp.QuoteMeta(start) + `.*?` + regexp.QuoteMeta(end) + `\n?`)
		if !pattern.MatchString(text) {
			return fail("toolchain_marker_incomplete_repair_editor")
		}
		text = pattern.ReplaceAllString(text, "\n")
	} else {
		lines := strings.Split(text, "\n")
		index := -1
		for i := len(lines) - 1; i >= 0; i-- {
			if strings.HasPrefix(lines[i], "CMD ") {
				index = i
				break
			}
		}
		if index < 0 {
			text = strings.TrimRight(text, "\n") + "\n\n" + block + "\n"
		} else {
			lines = append(lines[:index], append([]string{block}, lines[index:]...)...)
			text = strings.Join(lines, "\n")
		}
	}
	if len(text) > 2<<20 {
		return fail("dockerfile_too_large")
	}
	return success(text)
}
