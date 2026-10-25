package localchecks

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
)

// FleetSnapshot is the existing four-host coordinator's exact pack manifest.
// This bridge does not replace its queue, transfer or Git reconstruction owner.
type FleetSnapshot struct {
	Commit    string                  `json:"commit"`
	Base      string                  `json:"base"`
	MergeBase string                  `json:"merge_base"`
	Files     map[string]PackArtifact `json:"files"`
}
type PackArtifact struct {
	Bytes  uint64 `json:"bytes"`
	SHA256 string `json:"sha256"`
}

func DecodeFleetSnapshot(reader io.Reader) (FleetSnapshot, error) {
	var result FleetSnapshot
	data, err := io.ReadAll(io.LimitReader(reader, 8193))
	if err != nil || len(data) > 8192 {
		return result, errors.New("local_checks_pack_manifest_invalid")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return result, errors.New("local_checks_pack_manifest_invalid")
	}
	if decoder.Decode(new(any)) != io.EOF {
		return result, errors.New("local_checks_pack_manifest_invalid")
	}
	return result, result.Validate()
}
func (s FleetSnapshot) Validate() error {
	if !commitID.MatchString(s.Commit) || !commitID.MatchString(s.Base) || !commitID.MatchString(s.MergeBase) || len(s.Files) != 2 {
		return errors.New("local_checks_pack_manifest_invalid")
	}
	var total uint64
	for _, name := range []string{"history.pack", "snapshots.pack"} {
		artifact, ok := s.Files[name]
		if !ok || artifact.Bytes == 0 || artifact.Bytes > (1<<30)-total || !bundleID.MatchString(artifact.SHA256) {
			return errors.New("local_checks_pack_manifest_invalid")
		}
		total += artifact.Bytes
	}
	return nil
}

// CanonicalBytes uses compact JSON with lexicographically sorted object keys,
// ASCII-only values and no trailing newline. Python producers can use
// json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True).
func (s FleetSnapshot) CanonicalBytes() ([]byte, error) {
	if err := s.Validate(); err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{"commit": s.Commit, "base": s.Base, "merge_base": s.MergeBase, "files": s.Files})
}
func (s FleetSnapshot) Digest() string {
	data, err := s.CanonicalBytes()
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func (s FleetSnapshot) VerifyPacks(ctx context.Context, root string) error {
	if err := s.Validate(); err != nil {
		return err
	}
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil || !filepath.IsAbs(root) || filepath.Clean(root) != root || canonical != root {
		return errors.New("local_checks_pack_root_invalid")
	}
	for _, name := range []string{"history.pack", "snapshots.pack"} {
		if err := ctx.Err(); err != nil {
			return err
		}
		artifact := s.Files[name]
		path := filepath.Join(root, name)
		before, err := os.Lstat(path)
		if err != nil || !before.Mode().IsRegular() || uint64(before.Size()) != artifact.Bytes {
			return errors.New("local_checks_pack_identity_mismatch")
		}
		file, err := os.Open(path)
		if err != nil {
			return errors.New("local_checks_pack_unavailable")
		}
		opened, statErr := file.Stat()
		if statErr != nil || !os.SameFile(before, opened) {
			file.Close()
			return errors.New("local_checks_pack_identity_mismatch")
		}
		hash := sha256.New()
		buffer := make([]byte, 1<<20)
		var copied uint64
		for {
			if err = ctx.Err(); err != nil {
				break
			}
			var n int
			n, err = file.Read(buffer)
			if n > 0 {
				copied += uint64(n)
				if copied > artifact.Bytes {
					err = errors.New("pack grew")
					break
				}
				_, _ = hash.Write(buffer[:n])
			}
			if err != nil {
				break
			}
		}
		after, afterErr := file.Stat()
		closeErr := file.Close()
		if err != io.EOF || afterErr != nil || closeErr != nil || !os.SameFile(before, after) || after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) || copied != artifact.Bytes || hex.EncodeToString(hash.Sum(nil)) != artifact.SHA256 {
			return errors.New("local_checks_pack_identity_mismatch")
		}
	}
	return ctx.Err()
}
