package localchecks

import (
	"context"
	"errors"
	"strconv"
	"strings"
)

// ErrNativeCreateUncertain means Docker may have created an inert object. The
// caller must retain its durable creation intent and reconcile by exact name;
// it must never retry creation or assume that no effect occurred.
var ErrNativeCreateUncertain = errors.New("local_checks_native_create_uncertain")

// Create constructs only an inert Farm-owned worker. The native lifecycle owner
// must persist its intent before calling and journal the immutable ID before
// admission/start. No GitHub entrypoint, host socket, token or caller command is
// accepted. The pinned image must provide the qualified dockerd binary.
func (d DockerNativeDriver) Create(ctx context.Context, s Submission) (string, error) {
	if err := s.Validate(); err != nil {
		return "", err
	}
	if err := d.Binding().Validate(); err != nil {
		return "", err
	}
	if strings.ContainsAny(d.SourceRoot+d.DockerRoot, ",\n\r\x00") {
		return "", errors.New("local_checks_driver_configuration_invalid")
	}
	name := "farm-local-checks-" + s.RequestID
	if len(name) > 128 {
		return "", errors.New("local_checks_worker_name_invalid")
	}
	const label = "net.unraid.ci-runner-farm."
	memory := strconv.FormatUint(s.MemoryMiB, 10) + "m"
	args := []string{"container", "create", "--name", name, "--pull", "never", "--restart", "no", "--privileged", "--cgroupns", "private", "--network", "bridge", "--cpus", strconv.FormatUint(uint64(s.CPUs), 10), "--memory", memory, "--memory-swap", memory, "--pids-limit", "4096", "--label", label + "managed=true", "--label", label + "role=local-checks", "--label", label + "request=" + s.RequestID, "--label", label + "source=" + s.BundleSHA256, "--mount", "type=bind,src=" + d.SourceRoot + ",dst=/workspace/source,readonly", "--mount", "type=bind,src=" + d.DockerRoot + ",dst=/var/lib/docker", "--entrypoint", "/bin/bash", d.Image}
	args = append(args, workerDaemonArguments()...)
	output, err := d.command(ctx, args...)
	if err != nil {
		return "", ErrNativeCreateUncertain
	}
	id := strings.TrimSpace(string(output))
	if !immutableContainerID.MatchString(id) {
		return "", ErrNativeCreateUncertain
	}
	return id, nil
}

func workerDaemonArguments() []string {
	return []string{"-c", `set -Eeuo pipefail; /usr/local/bin/unraid-cgroup-bootstrap.sh; exec dockerd "$@"`, "farm-local-checks-daemon", "--host=unix:///var/run/docker.sock", "--data-root=/var/lib/docker", "--exec-root=/run/farm-docker", "--pidfile=/run/farm-docker.pid"}
}
