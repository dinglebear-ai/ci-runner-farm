package localchecks

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// DockerNativeDriver inspects only the configured immutable worker image and
// exact source/DinD mounts. It does not register a GitHub runner or expose the
// host Docker socket to a checks workload.
type DockerNativeDriver struct {
	Image, SourceRoot, DockerRoot string
	run                           func(context.Context, ...string) ([]byte, error)
}

type WorkerBinding struct {
	Image      string `json:"image"`
	SourceRoot string `json:"sourceRoot"`
	DockerRoot string `json:"dockerRoot"`
}

func (d DockerNativeDriver) Binding() WorkerBinding {
	return WorkerBinding{Image: d.Image, SourceRoot: d.SourceRoot, DockerRoot: d.DockerRoot}
}
func (b WorkerBinding) Validate() error {
	if !strings.HasPrefix(b.Image, "sha256:") || !bundleID.MatchString(strings.TrimPrefix(b.Image, "sha256:")) || !filepath.IsAbs(b.SourceRoot) || !filepath.IsAbs(b.DockerRoot) || filepath.Clean(b.SourceRoot) != b.SourceRoot || filepath.Clean(b.DockerRoot) != b.DockerRoot || b.SourceRoot == "/" || b.DockerRoot == "/" || b.SourceRoot == b.DockerRoot {
		return errors.New("local_checks_driver_configuration_invalid")
	}
	return nil
}

const workerInspectTemplate = `{"ID":{{json .Id}},"Image":{{json .Image}},"Labels":{{json .Config.Labels}},"Entrypoint":{{json .Config.Entrypoint}},"Command":{{json .Config.Cmd}},"Memory":{{.HostConfig.Memory}},"NanoCPUs":{{.HostConfig.NanoCpus}},"Cgroupns":{{json .HostConfig.CgroupnsMode}},"Privileged":{{.HostConfig.Privileged}},"PIDMode":{{json .HostConfig.PidMode}},"NetworkMode":{{json .HostConfig.NetworkMode}},"Running":{{.State.Running}},"PID":{{.State.Pid}},"Mounts":{{json .Mounts}}}`

func (d DockerNativeDriver) command(ctx context.Context, args ...string) ([]byte, error) {
	if d.run != nil {
		return d.run(ctx, args...)
	}
	bounded, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(bounded, "docker", args...)
	// Ambient Docker routing and auth overrides are deliberately not inherited.
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent", "DOCKER_HOST=unix:///var/run/docker.sock"}
	var output boundedOutput
	cmd.Stdout = &output
	var diagnostic dockerDiagnostic
	cmd.Stderr = &diagnostic
	if err := cmd.Run(); err != nil {
		code := classifyDockerDiagnostic(diagnostic.data)
		if bounded.Err() != nil {
			code = "deadline"
		}
		return nil, dockerOperationFailure{code: code}
	}
	return output.Bytes(), nil
}
func (d DockerNativeDriver) Inspect(ctx context.Context, id string) (NativeContainer, error) {
	var result NativeContainer
	if !immutableContainerID.MatchString(id) || !strings.HasPrefix(d.Image, "sha256:") || !bundleID.MatchString(strings.TrimPrefix(d.Image, "sha256:")) || !filepath.IsAbs(d.SourceRoot) || !filepath.IsAbs(d.DockerRoot) || filepath.Clean(d.SourceRoot) != d.SourceRoot || filepath.Clean(d.DockerRoot) != d.DockerRoot || d.SourceRoot == "/" || d.DockerRoot == "/" || d.SourceRoot == d.DockerRoot {
		return result, errors.New("local_checks_driver_configuration_invalid")
	}
	raw, err := d.command(ctx, "container", "inspect", "--format", workerInspectTemplate, id)
	if err != nil {
		ids, listErr := d.command(ctx, "container", "ls", "--all", "--quiet", "--no-trunc", "--filter", "id="+id)
		if listErr == nil && strings.TrimSpace(string(ids)) == "" {
			alive, infoErr := d.command(ctx, "info", "--format", "{{.ID}}")
			if infoErr == nil && strings.TrimSpace(string(alive)) != "" {
				return result, ErrNativeContainerMissing
			}
		}
		return result, errors.New("local_checks_container_inspection_unavailable")
	}
	var item struct {
		ID, Image, Cgroupns, PIDMode, NetworkMode string
		Labels                                    map[string]string
		Entrypoint, Command                       []string
		Memory, NanoCPUs                          uint64
		Running, Privileged                       bool
		PID                                       uint64
		Mounts                                    []struct {
			Type, Source, Destination string
			RW                        bool
		}
	}
	if err := json.Unmarshal(raw, &item); err != nil {
		return result, errors.New("local_checks_container_inspection_invalid")
	}
	if !slices.Equal(item.Entrypoint, []string{"/bin/bash"}) || !slices.Equal(item.Command, workerDaemonArguments()) {
		return result, errors.New("local_checks_worker_entrypoint_invalid")
	}
	if item.ID != id || item.Image != d.Image || item.Cgroupns != "private" || !item.Privileged || item.PIDMode != "" || item.NetworkMode == "host" || item.Memory == 0 || item.Memory%(1<<20) != 0 || item.NanoCPUs == 0 || item.NanoCPUs%1000000000 != 0 || item.NanoCPUs/1000000000 > 128 {
		return result, errors.New("local_checks_container_isolation_invalid")
	}
	source, docker := false, false
	for _, mount := range item.Mounts {
		switch mount.Destination {
		case "/workspace/source":
			if source || mount.Type != "bind" || mount.Source != d.SourceRoot || mount.RW {
				return result, errors.New("local_checks_source_mount_invalid")
			}
			source = true
		case "/var/lib/docker":
			if docker || mount.Type != "bind" || mount.Source != d.DockerRoot || !mount.RW {
				return result, errors.New("local_checks_dind_mount_invalid")
			}
			docker = true
		default:
			return result, errors.New("local_checks_unexpected_worker_mount")
		}
	}
	if !source || !docker {
		return result, errors.New("local_checks_worker_mounts_missing")
	}
	const label = "net.unraid.ci-runner-farm."
	result = NativeContainer{Managed: item.Labels[label+"managed"] == "true", ID: item.ID, Role: item.Labels[label+"role"], RequestID: item.Labels[label+"request"], SourceDigest: item.Labels[label+"source"], CPUs: uint32(item.NanoCPUs / 1000000000), MemoryMiB: item.Memory >> 20, PrivateCgroup: true, InnerDocker: true, Running: item.Running, Stopped: !item.Running && item.PID == 0}
	if !result.Managed || result.Role != "local-checks" || !identifier.MatchString(result.RequestID) || !bundleID.MatchString(result.SourceDigest) {
		return NativeContainer{}, errors.New("local_checks_worker_role_invalid")
	}
	return result, nil
}
func (d DockerNativeDriver) Start(ctx context.Context, id string) error {
	item, err := d.Inspect(ctx, id)
	if err != nil {
		return err
	}
	if item.Running || !item.Stopped {
		return errors.New("local_checks_worker_not_inert")
	}
	_, err = d.command(ctx, "container", "start", id)
	if err != nil {
		return err
	}
	return d.waitReady(ctx, id)
}
func (d DockerNativeDriver) Remove(ctx context.Context, id string) error {
	item, err := d.Inspect(ctx, id)
	if err != nil {
		return err
	}
	if item.Running || !item.Stopped {
		return errors.New("local_checks_worker_not_stopped")
	}
	_, err = d.command(ctx, "container", "rm", id)
	return err
}

// waitReady runs only after the charged worker is started. Failure never drops
// its charge; the native start journal remains uncertain until stopped proof.
func (d DockerNativeDriver) waitReady(ctx context.Context, id string) error {
	bounded, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	for attempt := 0; attempt < 6; attempt++ {
		if err := bounded.Err(); err != nil {
			return errors.New("local_checks_native_docker_readiness_unproven")
		}
		raw, err := d.command(bounded, "exec", "--env", "DOCKER_HOST=unix:///var/run/docker.sock", id, "docker", "info", "--format", "{{.ServerVersion}}")
		if err == nil {
			version := strings.SplitN(strings.TrimSpace(string(raw)), ".", 2)
			major, parseErr := strconv.Atoi(version[0])
			if parseErr != nil || len(version) != 2 || major < 26 {
				return errors.New("local_checks_native_docker_version_unsupported")
			}
			return nil
		}
		if attempt == 5 {
			break
		}
		timer := time.NewTimer(500 * time.Millisecond)
		select {
		case <-bounded.Done():
			timer.Stop()
			return errors.New("local_checks_native_docker_readiness_unproven")
		case <-timer.C:
		}
	}
	return errors.New("local_checks_native_docker_readiness_unproven")
}

// Only fixed classifications cross the Docker boundary. Raw daemon messages can
// contain host paths or credentials and are never returned or persisted.
type dockerOperationFailure struct{ code string }

func (e dockerOperationFailure) Error() string { return "local_checks_docker_" + e.code }

type dockerDiagnostic struct{ data []byte }

func (d *dockerDiagnostic) Write(p []byte) (int, error) {
	count := len(p)
	if available := 8192 - len(d.data); available > 0 {
		if len(p) > available {
			p = p[:available]
		}
		d.data = append(d.data, p...)
	}
	return count, nil
}
func classifyDockerDiagnostic(data []byte) string {
	text := strings.ToLower(string(data))
	for _, item := range []struct{ match, code string }{
		{"no such image", "image_missing"},
		{"invalid mount config", "mount_invalid"},
		{"permission denied", "permission_denied"},
		{"is already in use", "name_conflict"},
		{"cannot connect to the docker daemon", "daemon_unavailable"},
		{"no space left on device", "storage_full"},
	} {
		if strings.Contains(text, item.match) {
			return item.code
		}
	}
	return "operation_failed"
}
