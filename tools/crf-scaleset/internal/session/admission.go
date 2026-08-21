package session

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
	"github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/journal"
)

const (
	queueStarvationAge       = 10 * time.Minute
	minRuntimeSample         = time.Second
	maxRuntimeSample         = 24 * time.Hour
	maxRuntimeHistoryEntries = 2048
	maxRuntimeHistoryBytes   = 1 << 20
	runtimePersistInterval   = 30 * time.Second
	maxRuntimeIdentityBytes  = 1024
)

type runtimeEstimate struct {
	duration time.Duration
	samples  uint32
}

type runtimeHistoryEntry struct {
	Key            string `json:"key"`
	DurationMillis int64  `json:"duration_millis"`
	Samples        uint32 `json:"samples"`
}

type runtimeHistoryFile struct {
	SchemaVersion int                   `json:"schema_version"`
	Entries       []runtimeHistoryEntry `json:"entries"`
}

type rankedCandidate struct {
	job              crfgithub.AvailableJob
	estimatedRuntime time.Duration
	starved          bool
}

func runtimeHistoryPath(store journal.Store) string {
	return filepath.Join(filepath.Dir(store.Path), "runtime-history.json")
}

func loadRuntimeHints(store journal.Store) map[string]runtimeEstimate {
	runtimes, err := loadRuntimeHistory(runtimeHistoryPath(store))
	if err != nil {
		log.Printf("runtime history unavailable, starting cold: %v", err)
		return map[string]runtimeEstimate{}
	}
	return runtimes
}

func loadRuntimeHistory(path string) (map[string]runtimeEstimate, error) {
	out := map[string]runtimeEstimate{}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return out, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > maxRuntimeHistoryBytes {
		return out, errors.New("invalid_runtime_history_file")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return out, err
	}
	var history runtimeHistoryFile
	if err := json.Unmarshal(data, &history); err != nil {
		return out, err
	}
	if history.SchemaVersion != 1 || len(history.Entries) > maxRuntimeHistoryEntries {
		return out, errors.New("invalid_runtime_history_schema")
	}
	for _, entry := range history.Entries {
		if !validRuntimeDigest(entry.Key) || entry.Samples == 0 ||
			entry.DurationMillis < int64(minRuntimeSample/time.Millisecond) ||
			entry.DurationMillis > int64(maxRuntimeSample/time.Millisecond) {
			return map[string]runtimeEstimate{}, errors.New("invalid_runtime_history_entry")
		}
		duration := time.Duration(entry.DurationMillis) * time.Millisecond
		if _, duplicate := out[entry.Key]; duplicate {
			return map[string]runtimeEstimate{}, errors.New("duplicate_runtime_history_entry")
		}
		out[entry.Key] = runtimeEstimate{duration: duration, samples: entry.Samples}
	}
	return out, nil
}

func saveRuntimeHistory(path string, runtimes map[string]runtimeEstimate) error {
	entries := make([]runtimeHistoryEntry, 0, len(runtimes))
	for key, estimate := range runtimes {
		if !validRuntimeDigest(key) || estimate.samples == 0 ||
			estimate.duration < minRuntimeSample || estimate.duration > maxRuntimeSample {
			continue
		}
		entries = append(entries, runtimeHistoryEntry{
			Key: key, DurationMillis: estimate.duration.Milliseconds(), Samples: estimate.samples,
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Samples != entries[j].Samples {
			return entries[i].Samples > entries[j].Samples
		}
		return entries[i].Key < entries[j].Key
	})
	if len(entries) > maxRuntimeHistoryEntries {
		entries = entries[:maxRuntimeHistoryEntries]
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".runtime-history.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := json.NewEncoder(tmp).Encode(runtimeHistoryFile{SchemaVersion: 1, Entries: entries}); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	info, err := os.Lstat(name)
	if err != nil || info.Size() > maxRuntimeHistoryBytes {
		return errors.New("runtime_history_capacity_exhausted")
	}
	return os.Rename(name, path)
}

func validRuntimeDigest(key string) bool {
	if len(key) != sha256.Size*2 {
		return false
	}
	for i := range len(key) {
		if key[i] < '0' || key[i] > '9' {
			if key[i] < 'a' || key[i] > 'f' {
				return false
			}
		}
	}
	return true
}

func runtimeKey(poolID string, metadata crfgithub.JobMetadata) string {
	poolID = strings.TrimSpace(poolID)
	owner := strings.TrimSpace(metadata.OwnerName)
	repository := strings.TrimSpace(metadata.RepositoryName)
	workflow := strings.TrimSpace(metadata.JobWorkflowRef)
	if before, _, ok := strings.Cut(workflow, "@"); ok {
		workflow = before
	}
	workflow = strings.TrimSpace(workflow)
	name := strings.TrimSpace(metadata.JobDisplayName)
	if poolID == "" || owner == "" || repository == "" || workflow == "" || name == "" {
		return ""
	}
	if len(poolID)+len(owner)+len(repository)+len(workflow)+len(name)+4 > maxRuntimeIdentityBytes {
		return ""
	}
	identity := strings.ToLower(poolID) + "\x00" + strings.ToLower(owner) + "\x00" +
		strings.ToLower(repository) + "\x00" + strings.ToLower(workflow) + "\x00" + strings.ToLower(name)
	digest := sha256.Sum256([]byte(identity))
	return hex.EncodeToString(digest[:])
}

func (p *Poller) observeCompleted(poolID string, jobs []crfgithub.CompletedJob) {
	if len(jobs) == 0 {
		return
	}
	changed := false
	p.mu.Lock()
	for _, job := range jobs {
		key := runtimeKey(poolID, job.Metadata)
		duration := job.FinishTime.Sub(job.RunnerAssignTime)
		if key == "" || duration < minRuntimeSample || duration > maxRuntimeSample {
			continue
		}
		previous := p.runtimes[key]
		if previous.samples == 0 {
			p.runtimes[key] = runtimeEstimate{duration: duration, samples: 1}
			changed = true
			continue
		}
		samples := previous.samples
		if samples < ^uint32(0) {
			samples++
		}
		p.runtimes[key] = runtimeEstimate{
			duration: (3*previous.duration + duration) / 4,
			samples:  samples,
		}
		changed = true
	}
	now := time.Now().UTC()
	shouldPersist := changed && p.cfg.Store.Path != "" &&
		(p.lastRuntimePersist.IsZero() || now.Sub(p.lastRuntimePersist) >= runtimePersistInterval)
	snapshot := make(map[string]runtimeEstimate, len(p.runtimes))
	if shouldPersist {
		for key, estimate := range p.runtimes {
			snapshot[key] = estimate
		}
		p.lastRuntimePersist = now
	}
	p.mu.Unlock()
	if shouldPersist {
		if err := saveRuntimeHistory(runtimeHistoryPath(p.cfg.Store), snapshot); err != nil {
			log.Printf("runtime history persistence failed: %v", err)
		}
	}
}

func (p *Poller) runtimeSnapshot() map[string]runtimeEstimate {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make(map[string]runtimeEstimate, len(p.runtimes))
	for key, estimate := range p.runtimes {
		out[key] = estimate
	}
	return out
}

func rankCandidates(poolID string, jobs []crfgithub.AvailableJob, runtimes map[string]runtimeEstimate, now time.Time) []rankedCandidate {
	const defaultRuntime = 5 * time.Minute
	ranked := make([]rankedCandidate, len(jobs))
	for i, job := range jobs {
		estimatedRuntime := defaultRuntime
		if estimate, known := runtimes[runtimeKey(poolID, job.Metadata)]; known {
			estimatedRuntime = estimate.duration
		}
		age := now.Sub(job.Metadata.QueueTime)
		ranked[i] = rankedCandidate{
			job: job, estimatedRuntime: estimatedRuntime,
			starved: !job.Metadata.QueueTime.IsZero() && age >= queueStarvationAge,
		}
	}
	sort.SliceStable(ranked, func(i, j int) bool {
		left, right := ranked[i], ranked[j]
		if left.starved != right.starved {
			return left.starved
		}
		if left.starved && !left.job.Metadata.QueueTime.Equal(right.job.Metadata.QueueTime) {
			return left.job.Metadata.QueueTime.Before(right.job.Metadata.QueueTime)
		}
		if left.estimatedRuntime != right.estimatedRuntime {
			return left.estimatedRuntime < right.estimatedRuntime
		}
		if !left.job.Metadata.QueueTime.Equal(right.job.Metadata.QueueTime) {
			if left.job.Metadata.QueueTime.IsZero() {
				return false
			}
			if right.job.Metadata.QueueTime.IsZero() {
				return true
			}
			return left.job.Metadata.QueueTime.Before(right.job.Metadata.QueueTime)
		}
		return left.job.RequestID < right.job.RequestID
	})
	return ranked
}

func rankAvailable(poolID string, jobs []crfgithub.AvailableJob, runtimes map[string]runtimeEstimate, now time.Time) []crfgithub.AvailableJob {
	candidates := rankCandidates(poolID, jobs, runtimes, now)
	ranked := make([]crfgithub.AvailableJob, len(candidates))
	for i, candidate := range candidates {
		ranked[i] = candidate.job
	}
	return ranked
}

func (p *Poller) selectedAvailable(batch crfgithub.MessageBatch, poolID string, capacity int, now time.Time) []int64 {
	if capacity <= 0 {
		return nil
	}
	remaining := capacity
	if batch.Statistics != nil {
		remaining = max(0, capacity-batch.Statistics.TotalAssignedJobs)
	}
	if remaining == 0 {
		return nil
	}
	if len(batch.AvailableJobs) == 0 {
		limit := min(remaining, len(batch.Available))
		return slices.Clone(batch.Available[:limit])
	}
	ranked := rankCandidates(poolID, batch.AvailableJobs, p.runtimeSnapshot(), now)
	limit := min(remaining, len(ranked))
	selected := make([]int64, 0, limit)
	for _, candidate := range ranked[:limit] {
		selected = append(selected, candidate.job.RequestID)
	}
	return selected
}
