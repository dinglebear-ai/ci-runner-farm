package farmcapacity

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// A Docker read-only parent bind may still contain writable recursive mounts.
// Prove the effective cache view in the observer's live mount namespace too.
func proveReadOnlyCacheObserver(ctx context.Context, id, root string, mount nativeCacheMount) error {
	host, err := exec.CommandContext(ctx, "docker", "inspect", "--format", "{{json .HostConfig}}", id).Output()
	if err != nil {
		return err
	}
	if err = verifyCacheObserverPrivileges(host); err != nil {
		return err
	}
	target, err := cacheObserverTarget(root, mount)
	if err != nil {
		return err
	}
	readPID := func() (string, error) {
		raw, e := exec.CommandContext(ctx, "docker", "inspect", "--format", "{{.State.Pid}}", id).Output()
		if e != nil {
			return "", e
		}
		value := strings.TrimSpace(string(raw))
		n, e := strconv.Atoi(value)
		if e != nil || n <= 0 || strconv.Itoa(n) != value {
			return "", errors.New("read-only cache observer has no live PID proof")
		}
		return value, nil
	}
	pid, err := readPID()
	if err != nil {
		return err
	}
	nsPath := "/proc/" + pid + "/ns/mnt"
	before, err := os.Readlink(nsPath)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile("/proc/" + pid + "/mountinfo")
	if err != nil {
		return err
	}
	if err = verifyReadOnlyCacheView(target, string(raw)); err != nil {
		return err
	}
	after, err := os.Readlink(nsPath)
	if err != nil {
		return err
	}
	current, err := readPID()
	if err != nil {
		return err
	}
	again, err := os.ReadFile("/proc/" + pid + "/mountinfo")
	if err != nil {
		return err
	}
	if before != after || current != pid || !bytes.Equal(raw, again) {
		return errors.New("read-only cache observer namespace changed")
	}
	return nil
}

// Privileged observers can remount their own view after the read-only snapshot.
func verifyCacheObserverPrivileges(raw []byte) error {
	var host struct {
		Privileged *bool           `json:"Privileged"`
		CapAdd     json.RawMessage `json:"CapAdd"`
	}
	if err := json.Unmarshal(raw, &host); err != nil {
		return err
	}
	if host.Privileged == nil || *host.Privileged || len(host.CapAdd) == 0 {
		return errors.New("cache observer privileges are unsafe or unknown")
	}
	var caps []string
	if err := json.Unmarshal(host.CapAdd, &caps); err != nil {
		return err
	}
	for _, cap := range caps {
		value := strings.TrimPrefix(strings.ToUpper(cap), "CAP_")
		if value == "ALL" || value == "SYS_ADMIN" {
			return errors.New("cache observer can remount its read-only view")
		}
	}
	return nil
}

func cacheObserverTarget(root string, mount nativeCacheMount) (string, error) {
	for _, path := range []string{root, mount.Source, mount.Destination} {
		if !filepath.IsAbs(path) || filepath.Clean(path) != path {
			return "", errors.New("read-only cache observer path is uncertain")
		}
	}
	if mount.RW == nil || *mount.RW || !overlapsCache(root, mount.Source) {
		return "", errors.New("cache observer is not explicitly read-only")
	}
	if root == mount.Source || strings.HasPrefix(mount.Source, root+"/") {
		return mount.Destination, nil
	}
	relative, err := filepath.Rel(mount.Source, root)
	if err != nil {
		return "", err
	}
	return filepath.Join(mount.Destination, relative), nil
}

func verifyReadOnlyCacheView(target, inventory string) error {
	if !filepath.IsAbs(target) || filepath.Clean(target) != target {
		return errors.New("invalid cache observer target")
	}
	best := -1
	readonly := false
	seen := map[string]bool{}
	decode := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, "\\")
	for _, line := range strings.Split(inventory, "\n") {
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 10 || !strings.Contains(line, " - ") {
			return errors.New("unknown cache observer mount inventory")
		}
		point := decode.Replace(fields[4])
		if !filepath.IsAbs(point) || filepath.Clean(point) != point {
			return errors.New("invalid cache observer mountpoint")
		}
		options := "," + fields[5] + ","
		ro := strings.Contains(options, ",ro,")
		rw := strings.Contains(options, ",rw,")
		if ro == rw {
			return errors.New("unknown cache observer mount access")
		}
		ancestor := point == "/" || target == point || strings.HasPrefix(target, point+"/")
		descendant := point == target || strings.HasPrefix(point, target+"/")
		if ancestor || descendant {
			if seen[point] {
				return errors.New("ambiguous cache observer overmount")
			}
			seen[point] = true
		}
		if ancestor && len(point) > best {
			best = len(point)
			readonly = ro
		}
		if descendant && !ro {
			return errors.New("read-only cache observer contains a writable cache submount")
		}
	}
	if best < 0 || !readonly {
		return errors.New("cache observer has no proven read-only covering mount")
	}
	return nil
}
