package nativebackend

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/githubapp"
)

// InstallationIdentity comes from this plugin's Core-compiled bundle, never a
// browser form or archive-byte claim. The daemon separately verifies its actual
// executable. The source archive remains identified by the staging receipt.
type InstallationIdentity struct {
	Protocol       string `json:"protocol"`
	Version        string `json:"version"`
	TreeSHA256     string `json:"treeSHA256"`
	ManifestSHA256 string `json:"manifestSHA256"`
	BackendSHA256  string `json:"backendSHA256"`
	Files          uint32 `json:"files"`
	Bytes          uint64 `json:"bytes"`
}
type installationReceipt struct {
	InstallationIdentity
	ObservedAt time.Time `json:"observedAt"`
}

var installationDigest = regexp.MustCompile(`\A[0-9a-f]{64}\z`)
var installationVersion = regexp.MustCompile(`\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?\z`)

func (i InstallationIdentity) valid() bool {
	return i.Protocol == "farm-native-installation/v1" && len(i.Version) <= 128 && installationVersion.MatchString(i.Version) && installationDigest.MatchString(i.TreeSHA256) && installationDigest.MatchString(i.ManifestSHA256) && installationDigest.MatchString(i.BackendSHA256) && i.Files >= 3 && i.Files <= 128 && i.Bytes > 0 && i.Bytes <= 64<<20
}
func actualInstallationHelper() (string, error) {
	f, err := os.Open("/proc/self/exe")
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(f, (64<<20)+1))
	if err != nil || n > 64<<20 {
		return "", errors.New("installation_helper_unavailable")
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func readInstallation(path string) (installationReceipt, error) {
	var r installationReceipt
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return r, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 8192 {
		return r, errors.New("installation_receipt_unsafe")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return r, errors.New("installation_receipt_unsafe")
	}
	raw, err := io.ReadAll(io.LimitReader(f, 8193))
	if err != nil || len(raw) > 8192 {
		return r, errors.New("installation_receipt_unsafe")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&r) != nil || d.Decode(new(any)) != io.EOF || !r.InstallationIdentity.valid() || r.ObservedAt.IsZero() {
		return r, errors.New("installation_receipt_invalid")
	}
	return r, nil
}

func (s *Service) remoteInstallation(request Request) Response {
	if len(request.Args) != 0 || len(request.Values) != 0 || request.Kind != "" || len(request.Value) > 8192 || (request.Action == "remote-installation-status" && request.Value != "") {
		return fail("invalid_installation_identity_request")
	}
	helper, err := actualInstallationHelper()
	if err != nil {
		return fail("installation_helper_unavailable")
	}
	if CheckDirectory(s.config, uint32(os.Geteuid())) != nil {
		return fail("installation_storage_unavailable")
	}
	root := filepath.Join(s.config, "native-onboarding")
	if request.Action == "remote-installation-status" {
		if CheckDirectory(root, uint32(os.Geteuid())) != nil {
			return fail("installation_receipt_unavailable")
		}
		record, err := readInstallation(filepath.Join(root, "current-installation.json"))
		if err != nil || record.BackendSHA256 != helper {
			return fail("installation_identity_missing_or_changed")
		}
		return success(record)
	}
	var identity InstallationIdentity
	d := json.NewDecoder(bytes.NewBufferString(request.Value))
	d.DisallowUnknownFields()
	if d.Decode(&identity) != nil || d.Decode(new(any)) != io.EOF || !identity.valid() || identity.BackendSHA256 != helper {
		return fail("installation_identity_mismatch")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.accepting || s.active != nil {
		return fail("backend_busy")
	}
	if err = os.Mkdir(root, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return fail("installation_storage_unavailable")
	}
	if CheckDirectory(root, uint32(os.Geteuid())) != nil {
		return fail("installation_storage_unavailable")
	}
	ctx, cancel := context.WithTimeout(s.ctx, 2*time.Second)
	defer cancel()
	release, err := githubapp.AcquireCredentialLease(ctx, filepath.Join(root, "installation"))
	if err != nil {
		return fail("installation_inventory_busy")
	}
	defer release()
	path := filepath.Join(root, "installation-"+identity.TreeSHA256+".json")
	record, readErr := readInstallation(path)
	if readErr == nil {
		if record.InstallationIdentity != identity {
			return fail("installation_identity_changed_inspect")
		}
	} else {
		if !errors.Is(readErr, os.ErrNotExist) {
			return fail("installation_receipt_unsafe")
		}
		entries, e := os.ReadDir(root)
		if e != nil || len(entries) >= 66 {
			return fail("installation_inventory_limit")
		}
		record = installationReceipt{InstallationIdentity: identity, ObservedAt: time.Now().UTC()}
		raw, _ := json.Marshal(record)
		f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return fail("installation_receipt_existing_inspect")
		}
		_, w := f.Write(raw)
		sync := f.Sync()
		close := f.Close()
		if errors.Join(w, sync, close, syncParent(path)) != nil {
			return fail("installation_receipt_uncertain")
		}
	}
	current := filepath.Join(root, "current-installation.json")
	if info, e := os.Lstat(current); e == nil && (!info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0) {
		return fail("installation_pointer_unsafe")
	}
	raw, _ := json.Marshal(record)
	if atomicWrite(current, raw, 0600) != nil {
		return fail("installation_pointer_uncertain")
	}
	return success(record)
}
