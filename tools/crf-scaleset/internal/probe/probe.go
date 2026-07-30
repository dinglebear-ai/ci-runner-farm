package probe

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

type Record struct {
	SchemaVersion         int             `json:"schema_version"`
	CompatibilityRecordID string          `json:"compatibility_record_id"`
	PluginDigest          string          `json:"plugin_digest"`
	HelperDigest          string          `json:"helper_digest"`
	ModuleRevision        string          `json:"module_revision"`
	GoVersion             string          `json:"go_version"`
	ImageDigest           string          `json:"image_digest"`
	DockerfileDigest      string          `json:"dockerfile_digest"`
	EntrypointDigest      string          `json:"entrypoint_digest"`
	Owner                 string          `json:"owner"`
	APIURL                string          `json:"api_url"`
	InstallationID        string          `json:"installation_id"`
	HostID                string          `json:"host_id"`
	RunnerGroupID         int64           `json:"runner_group_id"`
	Capabilities          map[string]bool `json:"capabilities"`
	TestedAt              time.Time       `json:"tested_at"`
	Cleanup               Cleanup         `json:"cleanup"`
}
type Cleanup struct {
	Complete bool    `json:"complete"`
	IDs      []int64 `json:"ids"`
}

var required = []string{
	"create_get_update_delete", "restricted_group", "multiple_labels",
	"total_assigned_jobs", "jit_current_image", "zero_to_one",
	"cancel_reassign", "ack_replay", "dynamic_capacity",
	"eligibility_barrier", "nested_cgroup_charging", "exact_cleanup",
}

func (r *Record) Seal(now time.Time) error {
	if !r.Cleanup.Complete || len(r.Cleanup.IDs) != 0 {
		return errors.New("cleanup_incomplete")
	}
	for _, name := range required {
		if !r.Capabilities[name] {
			return errors.New("capability_missing:" + name)
		}
	}
	r.SchemaVersion = 1
	r.TestedAt = now.UTC()
	r.CompatibilityRecordID = ""
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	r.CompatibilityRecordID = hex.EncodeToString(sum[:])
	return nil
}

func WriteAtomic(path string, record Record) error {
	if err := record.Seal(time.Now()); err != nil {
		return err
	}
	data, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".compatibility.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
