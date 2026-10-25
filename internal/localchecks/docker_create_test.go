package localchecks

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestCreateWorkerIsInertPinnedAndNeverRetriesUncertainDockerEffect(t *testing.T) {
	s := submission()
	d := DockerNativeDriver{Image: "sha256:" + strings.Repeat("e", 64), SourceRoot: "/configured/source", DockerRoot: "/configured/docker"}
	id := strings.Repeat("d", 64)
	var calls [][]string
	d.run = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, append([]string(nil), args...))
		return []byte(id + "\n"), nil
	}
	got, err := d.Create(context.Background(), s)
	if err != nil || got != id || len(calls) != 1 {
		t.Fatal(got, err, calls)
	}
	args := calls[0]
	if !reflect.DeepEqual(args[:2], []string{"container", "create"}) {
		t.Fatal(args)
	}
	joined := strings.Join(args, " ")
	for _, want := range []string{"--pull never", "--cgroupns private", "--memory-swap ", "--restart no", "--entrypoint /bin/bash", "/usr/local/bin/unraid-cgroup-bootstrap.sh", "--host=unix:///var/run/docker.sock", "readonly", "net.unraid.ci-runner-farm.role=local-checks", d.Image} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in %v", want, args)
		}
	}
	if strings.Contains(joined, "docker.sock,") || strings.Contains(joined, "--env") || strings.Contains(joined, "container start") {
		t.Fatal(args)
	}
	calls = nil
	d.run = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, args)
		return nil, errors.New("timeout after daemon may have created")
	}
	if _, err = d.Create(context.Background(), s); !errors.Is(err, ErrNativeCreateUncertain) || len(calls) != 1 {
		t.Fatal(err, calls)
	}
}

func TestCreateWorkerRejectsInvalidBindingsBeforeDocker(t *testing.T) {
	d := DockerNativeDriver{Image: "mutable:latest", SourceRoot: "/source", DockerRoot: "/docker"}
	d.run = func(context.Context, ...string) ([]byte, error) {
		t.Fatal("invalid binding reached Docker")
		return nil, nil
	}
	if _, err := d.Create(context.Background(), submission()); err == nil {
		t.Fatal("mutable image accepted")
	}
}

func TestDaemonShellPreservesExactFixedDockerdArguments(t *testing.T) {
	fixture := filepath.Join(t.TempDir(), "dockerd")
	if err := os.WriteFile(fixture, []byte("#!/bin/sh\nprintf '<%s>\\n' \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	args := workerDaemonArguments()
	args[1] = strings.Replace(args[1], "/usr/local/bin/unraid-cgroup-bootstrap.sh", ":", 1)
	args[1] = strings.Replace(args[1], "exec dockerd", "exec "+strconv.Quote(fixture), 1)
	out, err := exec.Command("/bin/bash", args...).CombinedOutput()
	var want strings.Builder
	for _, arg := range args[3:] {
		want.WriteString("<" + arg + ">\n")
	}
	if err != nil || string(out) != want.String() {
		t.Fatalf("daemon argument transport changed: %q %v", out, err)
	}
}
