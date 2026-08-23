package probe

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"time"

	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/durable"
)

type Record struct {
	SchemaVersion           int             `json:"schema_version"`
	CompatibilityRecordID   string          `json:"compatibility_record_id"`
	PluginDigest            string          `json:"plugin_digest"`
	HelperDigest            string          `json:"helper_digest"`
	ModuleRevision          string          `json:"module_revision"`
	GoVersion               string          `json:"go_version"`
	ImageDigest             string          `json:"image_digest"`
	DockerfileDigest        string          `json:"dockerfile_digest"`
	EntrypointDigest        string          `json:"entrypoint_digest"`
	Owner                   string          `json:"owner"`
	APIURL                  string          `json:"api_url"`
	InstallationID          string          `json:"installation_id"`
	HostID                  string          `json:"host_id"`
	RunnerGroupID           int64           `json:"runner_group_id"`
	QuarantineRunnerGroupID int64           `json:"quarantine_runner_group_id"`
	RunnerGroupPolicy       string          `json:"runner_group_policy"`
	Capabilities            map[string]bool `json:"capabilities"`
	TestedAt                time.Time       `json:"tested_at"`
	Cleanup                 Cleanup         `json:"cleanup"`
}
type Cleanup struct {
	Complete bool    `json:"complete"`
	IDs      []int64 `json:"ids"`
}

var required = []string{
	"create_get_update_delete", "restricted_group", "multiple_labels",
	"total_assigned_jobs", "jit_current_image", "zero_to_one",
	"cancel_reassign", "ack_replay", "dynamic_capacity",
	"eligibility_barrier", "nested_cgroup_charging", "classic_quarantine_barrier",
	"exact_cleanup",
}

var digest = regexp.MustCompile(`^[0-9a-f]{64}$`)

func (r *Record) Seal(now time.Time) error {
	if !r.Cleanup.Complete || len(r.Cleanup.IDs) != 0 {
		return errors.New("cleanup_incomplete")
	}
	if r.RunnerGroupID <= 0 || r.QuarantineRunnerGroupID <= 0 ||
		r.QuarantineRunnerGroupID == r.RunnerGroupID || r.RunnerGroupPolicy == "" {
		return errors.New("compatibility_record_identity")
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
	return durable.Replace(path, ".compatibility.*", 0o600, 64<<10,
		func(w io.Writer) error {
			_, err := w.Write(data)
			return err
		})
}

func LoadFresh(path string, now time.Time, maxAge time.Duration) (Record, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return Record{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 64<<10 {
		return Record{}, errors.New("compatibility_record_permissions_or_size")
	}
	file, err := os.Open(path)
	if err != nil {
		return Record{}, err
	}
	defer func() { _ = file.Close() }()
	dec := json.NewDecoder(io.LimitReader(file, 64<<10))
	dec.DisallowUnknownFields()
	var record Record
	if err := dec.Decode(&record); err != nil {
		return Record{}, fmt.Errorf("decode compatibility record: %w", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		return Record{}, errors.New("compatibility_record_trailing_data")
	}
	if record.SchemaVersion != 1 || !record.Cleanup.Complete || len(record.Cleanup.IDs) != 0 {
		return Record{}, errors.New("compatibility_record_incomplete")
	}
	for _, name := range required {
		if !record.Capabilities[name] {
			return Record{}, errors.New("capability_missing:" + name)
		}
	}
	if maxAge <= 0 || record.TestedAt.After(now.Add(5*time.Minute)) ||
		now.Sub(record.TestedAt) > maxAge {
		return Record{}, errors.New("compatibility_record_stale")
	}
	for name, value := range map[string]string{
		"plugin": record.PluginDigest, "helper": record.HelperDigest, "image": record.ImageDigest,
		"dockerfile": record.DockerfileDigest, "entrypoint": record.EntrypointDigest,
	} {
		if !digest.MatchString(value) {
			return Record{}, errors.New("invalid_" + name + "_digest")
		}
	}
	if record.ModuleRevision == "" || record.GoVersion == "" || record.Owner == "" ||
		record.APIURL == "" || record.InstallationID == "" || record.HostID == "" ||
		record.RunnerGroupID <= 0 || record.QuarantineRunnerGroupID <= 0 ||
		record.QuarantineRunnerGroupID == record.RunnerGroupID ||
		record.RunnerGroupPolicy == "" {
		return Record{}, errors.New("compatibility_record_identity")
	}
	sealedID := record.CompatibilityRecordID
	record.CompatibilityRecordID = ""
	data, err := json.Marshal(record)
	if err != nil {
		return Record{}, err
	}
	sum := sha256.Sum256(data)
	if !bytes.Equal([]byte(sealedID), []byte(hex.EncodeToString(sum[:]))) {
		return Record{}, errors.New("compatibility_record_seal")
	}
	record.CompatibilityRecordID = sealedID
	return record, nil
}
