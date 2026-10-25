package remotehost

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

const maxPackageBytes = 8 << 20
const maxPackageExpandedBytes = 64 << 20

type PackageView struct {
	SHA256         string `json:"sha256"`
	Bytes          int64  `json:"bytes"`
	Version        string `json:"version"`
	ManifestSHA256 string `json:"manifestSHA256"`
	TreeSHA256     string `json:"treeSHA256"`
	BackendSHA256  string `json:"backendSHA256"`
}

// InspectPackage checks byte identity and closed Farm package shape before any
// transfer. It never substitutes for the target Core installer permission review.
func InspectPackage(raw []byte) (PackageView, error) {
	var view PackageView
	if len(raw) == 0 || len(raw) > maxPackageBytes {
		return view, errors.New("remote_package_size_invalid")
	}
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return view, errors.New("remote_package_archive_invalid")
	}
	defer gz.Close()
	reader := tar.NewReader(io.LimitReader(gz, maxPackageExpandedBytes+1))
	hashes := map[string]string{}
	executables := map[string]bool{}
	var manifest []byte
	total := int64(0)
	for count := 0; ; count++ {
		h, e := reader.Next()
		if errors.Is(e, io.EOF) {
			break
		}
		if e != nil || count >= 128 {
			return view, errors.New("remote_package_archive_invalid")
		}
		name := strings.TrimPrefix(h.Name, "./")
		if name == "" || name == "." {
			if h.Typeflag == tar.TypeDir {
				continue
			}
			return view, errors.New("remote_package_entry_invalid")
		}
		if strings.HasPrefix(name, "/") || path.Clean(name) != strings.TrimSuffix(name, "/") || strings.Contains(name, "\\") || h.Size < 0 || h.Size > maxPackageExpandedBytes || (h.Typeflag != tar.TypeDir && h.Typeflag != tar.TypeReg) {
			return view, errors.New("remote_package_entry_invalid")
		}
		for _, part := range strings.Split(name, "/") {
			if part == ".." {
				return view, errors.New("remote_package_entry_invalid")
			}
		}
		if h.Typeflag == tar.TypeDir {
			continue
		}
		if _, duplicate := hashes[name]; duplicate {
			return view, errors.New("remote_package_duplicate_entry")
		}
		total += h.Size
		if total > maxPackageExpandedBytes {
			return view, errors.New("remote_package_expanded_size_invalid")
		}
		hash := sha256.New()
		var data bytes.Buffer
		target := io.Writer(hash)
		if name == "manifest.json" {
			if h.Size > 128<<10 {
				return view, errors.New("remote_package_manifest_invalid")
			}
			target = io.MultiWriter(hash, &data)
		}
		if _, err = io.Copy(target, reader); err != nil {
			return view, errors.New("remote_package_archive_invalid")
		}
		hashes[name] = hex.EncodeToString(hash.Sum(nil))
		executables[name] = h.Mode&0111 != 0
		if name == "manifest.json" {
			manifest = data.Bytes()
		}
	}
	var m struct {
		ID, Version string
		Native      struct {
			Helpers []struct{ ID, Path, SHA256 string }
		}
	}
	if json.Unmarshal(manifest, &m) != nil || m.ID != "ci-runner-farm" || len(m.Version) == 0 || len(m.Version) > 128 || len(m.Native.Helpers) != 2 {
		return view, errors.New("remote_package_farm_manifest_required")
	}
	ids := map[string]bool{}
	for _, h := range m.Native.Helpers {
		if (h.ID != "backend" && h.ID != "observer") || ids[h.ID] || !referenceDigest.MatchString(h.SHA256) || hashes[h.Path] != h.SHA256 {
			return view, errors.New("remote_package_helper_identity_invalid")
		}
		ids[h.ID] = true
	}
	sum := sha256.Sum256(raw)
	var backend string
	for _, helper := range m.Native.Helpers {
		if helper.ID == "backend" {
			backend = helper.SHA256
		}
	}
	return PackageView{SHA256: hex.EncodeToString(sum[:]), Bytes: int64(len(raw)), Version: m.Version, ManifestSHA256: hashes["manifest.json"], TreeSHA256: packageTreeDigest(hashes, executables), BackendSHA256: backend}, nil
}

// Package tree v1 binds all regular-file bytes and executable bits, independently
// of compression, tar order, ownership and extraction timestamps. Length-prefixed
// raw names avoid separator ambiguity. Core retains install approval authority.
func packageTreeDigest(hashes map[string]string, executables map[string]bool) string {
	names := make([]string, 0, len(hashes))
	for name := range hashes {
		names = append(names, name)
	}
	sort.Strings(names)
	hash := sha256.New()
	_, _ = hash.Write([]byte("farm-package-tree/v1\x00"))
	for _, name := range names {
		var length [4]byte
		binary.BigEndian.PutUint32(length[:], uint32(len(name)))
		_, _ = hash.Write(length[:])
		_, _ = hash.Write([]byte(name))
		mode := byte(0)
		if executables[name] {
			mode = 1
		}
		_, _ = hash.Write([]byte{mode})
		digest, _ := hex.DecodeString(hashes[name])
		_, _ = hash.Write(digest)
	}
	return hex.EncodeToString(hash.Sum(nil))
}
func packageActorDirectory(root, actor string) string { return actorDirectory(root, actor) }
func StorePackage(root, actor string, raw []byte) (PackageView, error) {
	if err := validateActor(root, actor); err != nil {
		return PackageView{}, err
	}
	if err := inspectPrivate(root, true); err != nil {
		return PackageView{}, err
	}
	view, err := InspectPackage(raw)
	if err != nil {
		return view, err
	}
	release, err := connectionInventoryLease(root, actor)
	if err != nil {
		return view, err
	}
	defer release()
	dir := packageActorDirectory(root, actor)
	if err = os.Mkdir(dir, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return view, err
	}
	if err = inspectPrivate(dir, true); err != nil {
		return view, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) >= 16 {
		return view, errors.New("remote_package_inventory_limit")
	}
	p := filepath.Join(dir, view.SHA256+".tgz")
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return view, errors.New("remote_package_exists_inspect_before_upload")
	}
	_, writeErr := f.Write(raw)
	syncErr := f.Sync()
	closeErr := f.Close()
	if errors.Join(writeErr, syncErr, closeErr) != nil {
		return view, errors.New("remote_package_store_uncertain")
	}
	return view, nil
}
func LoadPackage(root, actor, digest string) (string, PackageView, error) {
	if err := validateActor(root, actor); err != nil {
		return "", PackageView{}, err
	}
	if !referenceDigest.MatchString(digest) {
		return "", PackageView{}, errors.New("remote_package_identity_invalid")
	}
	dir := packageActorDirectory(root, actor)
	for _, p := range []string{root, dir} {
		if err := inspectPrivate(p, true); err != nil {
			return "", PackageView{}, err
		}
	}
	p := filepath.Join(dir, digest+".tgz")
	info, err := os.Lstat(p)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > maxPackageBytes {
		return "", PackageView{}, errors.New("remote_package_unavailable")
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		return "", PackageView{}, err
	}
	view, err := InspectPackage(raw)
	if err != nil || view.SHA256 != digest {
		return "", view, errors.New("remote_package_identity_changed")
	}
	return p, view, nil
}

// ListPackages exposes only validated identities in the authenticated actor's
// inventory. It preserves incomplete files for inspection rather than deleting.
func ListPackages(root, actor string) ([]PackageView, error) {
	if err := validateActor(root, actor); err != nil {
		return nil, err
	}
	if err := inspectPrivate(root, true); err != nil {
		return nil, err
	}
	release, err := connectionInventoryLease(root, actor)
	if err != nil {
		return nil, err
	}
	defer release()
	dir := packageActorDirectory(root, actor)
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return []PackageView{}, nil
	}
	if err != nil || len(entries) > 16 {
		return nil, errors.New("remote_package_inventory_unavailable")
	}
	if err = inspectPrivate(dir, true); err != nil {
		return nil, err
	}
	views := make([]PackageView, 0, len(entries))
	for _, entry := range entries {
		digest := strings.TrimSuffix(entry.Name(), ".tgz")
		if entry.Name() != digest+".tgz" || !referenceDigest.MatchString(digest) {
			return nil, errors.New("remote_package_inventory_invalid")
		}
		_, view, e := LoadPackage(root, actor, digest)
		if e != nil {
			return nil, e
		}
		views = append(views, view)
	}
	return views, nil
}
