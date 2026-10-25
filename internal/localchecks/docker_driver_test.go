package localchecks

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestDockerNativeRoleInspectRequiresActualHardLimitsAndPrivateInnerDaemon(t *testing.T) {
	id := strings.Repeat("d", 64)
	s := submission()
	object := map[string]any{"Entrypoint": []string{"/bin/bash"}, "Command": workerDaemonArguments(), "ID": id, "Image": "sha256:" + strings.Repeat("e", 64), "Labels": map[string]string{"net.unraid.ci-runner-farm.managed": "true", "net.unraid.ci-runner-farm.role": "local-checks", "net.unraid.ci-runner-farm.request": s.RequestID, "net.unraid.ci-runner-farm.source": s.BundleSHA256}, "Memory": s.MemoryMiB << 20, "NanoCPUs": uint64(s.CPUs) * 1000000000, "Cgroupns": "private", "Privileged": true, "PIDMode": "", "NetworkMode": "bridge", "Running": false, "PID": 0, "Mounts": []map[string]any{{"Type": "bind", "Source": "/configured/source", "Destination": "/workspace/source", "RW": false}, {"Type": "bind", "Source": "/configured/docker", "Destination": "/var/lib/docker", "RW": true}}}
	driver := DockerNativeDriver{Image: object["Image"].(string), SourceRoot: "/configured/source", DockerRoot: "/configured/docker"}
	driver.run = func(context.Context, ...string) ([]byte, error) { return json.Marshal(object) }
	got, err := driver.Inspect(context.Background(), id)
	if err != nil || got.Role != "local-checks" || !got.InnerDocker || got.MemoryMiB != s.MemoryMiB {
		t.Fatal(got, err)
	}
	object["Cgroupns"] = "host"
	if _, err := driver.Inspect(context.Background(), id); err == nil {
		t.Fatal("accepted host cgroup namespace")
	}
	object["Cgroupns"] = "private"
	object["Mounts"] = append(object["Mounts"].([]map[string]any), map[string]any{"Type": "bind", "Source": "/var/run/docker.sock", "Destination": "/var/run/docker.sock", "RW": true})
	if _, err := driver.Inspect(context.Background(), id); err == nil {
		t.Fatal("accepted host Docker socket")
	}
}

func TestDockerNativeRoleRejectsCallerEntrypoint(t *testing.T) {
	id := strings.Repeat("d", 64)
	s := submission()
	object := map[string]any{"ID": id, "Image": "sha256:" + strings.Repeat("e", 64), "Labels": map[string]string{"net.unraid.ci-runner-farm.managed": "true", "net.unraid.ci-runner-farm.role": "local-checks", "net.unraid.ci-runner-farm.request": s.RequestID, "net.unraid.ci-runner-farm.source": s.BundleSHA256}, "Memory": s.MemoryMiB << 20, "NanoCPUs": uint64(s.CPUs) * 1000000000, "Cgroupns": "private", "Privileged": true, "PIDMode": "", "NetworkMode": "bridge", "Running": false, "PID": 0, "Entrypoint": []string{"sh", "-c"}, "Command": []string{"arbitrary command"}, "Mounts": []map[string]any{{"Type": "bind", "Source": "/configured/source", "Destination": "/workspace/source", "RW": false}, {"Type": "bind", "Source": "/configured/docker", "Destination": "/var/lib/docker", "RW": true}}}
	d := DockerNativeDriver{Image: object["Image"].(string), SourceRoot: "/configured/source", DockerRoot: "/configured/docker"}
	d.run = func(context.Context, ...string) ([]byte, error) { return json.Marshal(object) }
	if _, err := d.Inspect(context.Background(), id); err == nil {
		t.Fatal("arbitrary entrypoint accepted as private Docker daemon")
	}
}

func TestInnerDockerReadinessIsBoundedAndRequiresVolumeSubpathVersion(t *testing.T) {
	d := DockerNativeDriver{}
	calls := 0
	d.run = func(_ context.Context, args ...string) ([]byte, error) {
		calls++
		if calls == 1 {
			return nil, errors.New("daemon not ready")
		}
		return []byte("26.1.0\n"), nil
	}
	if err := d.waitReady(context.Background(), strings.Repeat("d", 64)); err != nil || calls != 2 {
		t.Fatal(err, calls)
	}
	calls = 0
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := d.waitReady(ctx, strings.Repeat("d", 64)); err == nil || calls != 0 {
		t.Fatal("cancelled readiness attempted Docker", err, calls)
	}
	d.run = func(context.Context, ...string) ([]byte, error) { return []byte("25.0.0"), nil }
	if err := d.waitReady(context.Background(), strings.Repeat("d", 64)); err == nil {
		t.Fatal("pre-volume-subpath Docker accepted")
	}
}
