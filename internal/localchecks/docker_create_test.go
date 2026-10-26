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
	args[1] = "set -Eeuo pipefail;" + strings.SplitN(args[1], "/usr/local/bin/unraid-cgroup-bootstrap.sh;", 2)[1]
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

func TestDaemonSelectsNftInsideWorkerBeforeDockerd(t *testing.T) {
	args := workerDaemonArguments()
	for _, required := range []string{"/usr/sbin/iptables-nft", "/usr/sbin/ip6tables-nft", "update-alternatives --set iptables /usr/sbin/iptables-nft", "update-alternatives --set ip6tables /usr/sbin/ip6tables-nft"} {
		if !strings.Contains(args[1], required) {
			t.Fatalf("missing worker-local nft selection: %s", required)
		}
	}
	if strings.Index(args[1], "update-alternatives --set") > strings.Index(args[1], "exec dockerd") {
		t.Fatal("nft selected after daemon")
	}
}

func TestDaemonNftSelectionExecutesAndRefusesFailures(t *testing.T) {
	for _, failure := range []string{"", "alternatives", "version"} {
		t.Run(failure, func(t *testing.T) {
			root := t.TempDir()
			write := func(name, body string) string {
				p := filepath.Join(root, name)
				if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), 0700); err != nil {
					t.Fatal(err)
				}
				return p
			}
			log := filepath.Join(root, "calls")
			write("update-alternatives", "printf '%s\\n' \"$*\" >> \"$CALLS\"\n[ \"$FAILURE\" != alternatives ]\n")
			nft := write("nft", "if [ \"$FAILURE\" = version ]; then echo 'iptables (legacy)'; else echo 'iptables (nf_tables)'; fi\n")
			bootstrap := write("bootstrap", "echo bootstrap >> \"$CALLS\"\n")
			daemon := write("dockerd", "echo daemon >> \"$CALLS\"\n")
			args := workerDaemonArguments()
			for _, path := range []string{"/usr/sbin/iptables-nft", "/usr/sbin/ip6tables-nft", "/usr/sbin/iptables", "/usr/sbin/ip6tables"} {
				args[1] = strings.ReplaceAll(args[1], path, nft)
			}
			args[1] = strings.ReplaceAll(args[1], "/usr/local/bin/unraid-cgroup-bootstrap.sh", bootstrap)
			args[1] = strings.ReplaceAll(args[1], "exec dockerd", "exec "+daemon)
			cmd := exec.Command("/bin/bash", args...)
			cmd.Env = append(os.Environ(), "PATH="+root+":"+os.Getenv("PATH"), "CALLS="+log, "FAILURE="+failure)
			out, err := cmd.CombinedOutput()
			data, _ := os.ReadFile(log)
			if failure == "" {
				if err != nil || !strings.HasSuffix(string(data), "bootstrap\ndaemon\n") {
					t.Fatalf("%s %s %v", out, data, err)
				}
			} else if err == nil || strings.Contains(string(data), "bootstrap") || strings.Contains(string(data), "daemon") {
				t.Fatalf("failed nft setup reached daemon: %s %v", data, err)
			}
		})
	}
}

func TestDockerCreationFailureRetainsSafeClassificationWithoutRawStderr(t *testing.T) {
	root := t.TempDir()
	docker := filepath.Join(root, "docker")
	if err := os.WriteFile(docker, []byte("#!/bin/sh\necho 'Error response from daemon: No such image: SECRET/private' >&2\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", root)
	d := DockerNativeDriver{Image: "sha256:" + strings.Repeat("e", 64), SourceRoot: "/source", DockerRoot: "/docker"}
	_, err := d.Create(context.Background(), submission())
	if !errors.Is(err, ErrNativeCreateUncertain) || !strings.Contains(err.Error(), "image_missing") || strings.Contains(err.Error(), "SECRET") {
		t.Fatal(err)
	}
}

func TestPinnedImageAvailabilityRequiresExactDockerImageIdentity(t *testing.T) {
	for _, mode := range []string{"present", "missing", "wrong-image", "invalid-binding"} {
		t.Run(mode, func(t *testing.T) {
			d := DockerNativeDriver{Image: "sha256:" + strings.Repeat("e", 64)}
			if mode == "invalid-binding" {
				d.Image = "mutable:latest"
			}
			calls := 0
			d.run = func(_ context.Context, args ...string) ([]byte, error) {
				calls++
				if !reflect.DeepEqual(args, []string{"image", "inspect", "--format", "{{.Id}}", d.Image}) {
					t.Fatal(args)
				}
				if mode == "missing" {
					return nil, errors.New("missing")
				}
				if mode == "wrong-image" {
					return []byte("sha256:" + strings.Repeat("a", 64)), nil
				}
				return []byte(d.Image + "\n"), nil
			}
			if d.ImageAvailable(context.Background()) != (mode == "present") {
				t.Fatal(mode)
			}
			if mode == "invalid-binding" && calls != 0 {
				t.Fatal("mutable image inspected")
			}
		})
	}
}
