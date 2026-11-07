package farmcapacity

import "testing"

func TestReadOnlyCacheViewRejectsWritableRecursiveMount(t *testing.T) {
	const root = "1 0 0:1 / / rw - rootfs rootfs rw\n"
	const ro = "2 1 0:2 / /mnt ro - tmpfs tmpfs ro\n"
	target := "/mnt/artifacts/runner/docker/ci-runner-build-large-1"
	for _, tc := range []struct {
		name, extra string
		pass        bool
	}{
		{"recursive-ro", "3 2 0:3 / /mnt/artifacts ro - zfs pool rw\n", true},
		{"writable-parent", "3 2 0:3 / /mnt/artifacts rw - zfs pool rw\n", false},
		{"writable-child", "3 2 0:3 / " + target + "/buildkit rw - tmpfs tmpfs rw\n", false},
		{"duplicate-cover", "3 2 0:3 / /mnt rw - tmpfs tmpfs rw\n", false},
		{"unrelated-writer", "3 2 0:3 / /other rw - tmpfs tmpfs rw\n", true},
		{"unknown", "broken\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := verifyReadOnlyCacheView(target, root+ro+tc.extra)
			if (err == nil) != tc.pass {
				t.Fatalf("error=%v pass=%v", err, tc.pass)
			}
		})
	}
	if verifyReadOnlyCacheView(target, root+"3 1 0:3 / /mnt rw - tmpfs tmpfs rw\n"+ro) == nil {
		t.Fatal("reverse stacked mount accepted")
	}
	if verifyReadOnlyCacheView(target, root) == nil || verifyReadOnlyCacheView(target, "") == nil {
		t.Fatal("unproved view accepted")
	}
}
func TestReadOnlyCacheObserverTarget(t *testing.T) {
	ro := false
	rw := true
	root := "/mnt/artifacts/runner/docker/ci-runner-build-large-1"
	target, err := cacheObserverTarget(root, nativeCacheMount{Source: "/mnt", Destination: "/host", RW: &ro})
	if err != nil || target != "/host/artifacts/runner/docker/ci-runner-build-large-1" {
		t.Fatal(target, err)
	}
	for _, mount := range []nativeCacheMount{{Source: "/mnt", Destination: "/host"}, {Source: "/mnt", Destination: "/host", RW: &rw}, {Source: "/mnt", Destination: "", RW: &ro}} {
		if _, err := cacheObserverTarget(root, mount); err == nil {
			t.Fatal("uncertain observer accepted")
		}
	}
}

func TestCacheObserverPrivilegesFailClosed(t *testing.T) {
	for _, raw := range []string{`{}`, `{"Privileged":false}`, `{"Privileged":true,"CapAdd":null}`, `{"Privileged":false,"CapAdd":["SYS_ADMIN"]}`, `{"Privileged":false,"CapAdd":["CAP_SYS_ADMIN"]}`, `{"Privileged":false,"CapAdd":["ALL"]}`, `{"Privileged":false,"CapAdd":"unknown"}`} {
		if verifyCacheObserverPrivileges([]byte(raw)) == nil {
			t.Fatal("unsafe observer accepted", raw)
		}
	}
	for _, raw := range []string{`{"Privileged":false,"CapAdd":null}`, `{"Privileged":false,"CapAdd":[]}`, `{"Privileged":false,"CapAdd":["NET_ADMIN"]}`} {
		if err := verifyCacheObserverPrivileges([]byte(raw)); err != nil {
			t.Fatal(err)
		}
	}
}
