package session

import (
	"container/heap"
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
	queueStarvationAge           = 10 * time.Minute
	minRuntimeSample             = time.Second
	maxRuntimeSample             = 24 * time.Hour
	maxRuntimeHistoryEntries     = 2048
	maxRuntimeHistoryBytes       = 1 << 20
	runtimePersistInterval       = 30 * time.Second
	maxRuntimeIdentityBytes      = 1024
	fastLaneHoldDuration         = 20 * time.Second
	fastLaneLongRuntimeThreshold = 8 * time.Minute
	fastLaneMinHoldDuration      = 5 * time.Second
	fastLaneMaxHoldDuration      = 30 * time.Second
	fastLaneMinLongThreshold     = 4 * time.Minute
	fastLaneMaxLongThreshold     = fastLaneLongRuntimeThreshold
	fastLanePolicySampleSize     = 64
	fastLaneThresholdStep        = 2 * time.Minute
	fastLaneThresholdDeadband    = time.Minute
	fastLaneHoldStep             = 5 * time.Second
	fastLaneHoldDeadband         = 2 * time.Second
	fastLaneMaxReservedSlots     = 4
)

type runtimeDigest [sha256.Size]byte

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
	runtimeKnown     bool
	starved          bool
}

type fastLanePolicy struct {
	longThreshold time.Duration
	holdDuration  time.Duration
	reserveSlots  int
}

type admissionDecision struct {
	requestIDs      []int64
	reserveFastLane bool
	borrowFastLane  bool
	policy          fastLanePolicy
}

func runtimeHistoryPath(store journal.Store) string {
	return filepath.Join(filepath.Dir(store.Path), "runtime-history.json")
}

func loadRuntimeHints(store journal.Store) map[runtimeDigest]runtimeEstimate {
	runtimes, err := loadRuntimeHistory(runtimeHistoryPath(store))
	if err != nil {
		log.Printf("runtime history unavailable, starting cold: %v", err)
		return map[runtimeDigest]runtimeEstimate{}
	}
	return runtimes
}

func parseRuntimeDigest(value string) (runtimeDigest, bool) {
	var digest runtimeDigest
	if len(value) != sha256.Size*2 {
		return digest, false
	}
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) != sha256.Size {
		return digest, false
	}
	copy(digest[:], decoded)
	return digest, true
}

func validRuntimeDigest(digest runtimeDigest) bool {
	return digest != (runtimeDigest{})
}

func loadRuntimeHistory(path string) (map[runtimeDigest]runtimeEstimate, error) {
	out := map[runtimeDigest]runtimeEstimate{}
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
		digest, valid := parseRuntimeDigest(entry.Key)
		if !valid || entry.Samples == 0 ||
			entry.DurationMillis < int64(minRuntimeSample/time.Millisecond) ||
			entry.DurationMillis > int64(maxRuntimeSample/time.Millisecond) {
			return map[runtimeDigest]runtimeEstimate{}, errors.New("invalid_runtime_history_entry")
		}
		duration := time.Duration(entry.DurationMillis) * time.Millisecond
		if _, duplicate := out[digest]; duplicate {
			return map[runtimeDigest]runtimeEstimate{}, errors.New("duplicate_runtime_history_entry")
		}
		out[digest] = runtimeEstimate{duration: duration, samples: entry.Samples}
	}
	return out, nil
}

func saveRuntimeHistory(path string, runtimes map[runtimeDigest]runtimeEstimate) error {
	entries := make([]runtimeHistoryEntry, 0, len(runtimes))
	for digest, estimate := range runtimes {
		if !validRuntimeDigest(digest) || estimate.samples == 0 ||
			estimate.duration < minRuntimeSample || estimate.duration > maxRuntimeSample {
			continue
		}
		entries = append(entries, runtimeHistoryEntry{
			Key: hex.EncodeToString(digest[:]), DurationMillis: estimate.duration.Milliseconds(), Samples: estimate.samples,
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

func runtimeKey(poolID string, metadata crfgithub.JobMetadata) runtimeDigest {
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
		return runtimeDigest{}
	}
	if len(poolID)+len(owner)+len(repository)+len(workflow)+len(name)+4 > maxRuntimeIdentityBytes {
		return runtimeDigest{}
	}
	fields := [...]string{poolID, owner, repository, workflow, name}
	var storage [maxRuntimeIdentityBytes]byte
	identity := storage[:0]
	for fieldIndex, field := range fields {
		if fieldIndex > 0 {
			identity = append(identity, 0)
		}
		for i := 0; i < len(field); i++ {
			value := field[i]
			if value >= 'A' && value <= 'Z' {
				value += 'a' - 'A'
			}
			identity = append(identity, value)
		}
	}
	return sha256.Sum256(identity)
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
		if !validRuntimeDigest(key) || duration < minRuntimeSample || duration > maxRuntimeSample {
			continue
		}
		previous := p.runtimes[key]
		if previous.samples == 0 {
			p.runtimes[key] = runtimeEstimate{duration: duration, samples: 1}
			if len(p.runtimes) > maxRuntimeHistoryEntries {
				p.evictRuntimeLocked()
			}
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
	if changed {
		p.runtimeDirty = true
		p.runtimeGeneration++
	}
	p.mu.Unlock()
	if err := p.persistRuntimeHints(false); err != nil {
		log.Printf("runtime history persistence failed: %v", err)
	}
}

func (p *Poller) evictRuntimeLocked() {
	var victim runtimeDigest
	var estimate runtimeEstimate
	found := false
	for key, candidate := range p.runtimes {
		if !found || candidate.samples < estimate.samples ||
			(candidate.samples == estimate.samples && slices.Compare(key[:], victim[:]) > 0) {
			victim, estimate, found = key, candidate, true
		}
	}
	if found {
		delete(p.runtimes, victim)
	}
}

func (p *Poller) persistRuntimeHints(force bool) error {
	if p.cfg.Store.Path == "" {
		return nil
	}
	p.runtimePersistMu.Lock()
	defer p.runtimePersistMu.Unlock()
	p.mu.Lock()
	if !p.runtimeDirty || (!force && !p.lastRuntimePersist.IsZero() &&
		time.Since(p.lastRuntimePersist) < runtimePersistInterval) {
		p.mu.Unlock()
		return nil
	}
	generation := p.runtimeGeneration
	snapshot := make(map[runtimeDigest]runtimeEstimate, len(p.runtimes))
	for key, estimate := range p.runtimes {
		snapshot[key] = estimate
	}
	p.mu.Unlock()
	if err := saveRuntimeHistory(runtimeHistoryPath(p.cfg.Store), snapshot); err != nil {
		return err
	}
	p.mu.Lock()
	p.lastRuntimePersist = time.Now().UTC()
	if p.runtimeGeneration == generation {
		p.runtimeDirty = false
	}
	p.mu.Unlock()
	return nil
}

func (p *Poller) runtimeSnapshot() map[runtimeDigest]runtimeEstimate {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make(map[runtimeDigest]runtimeEstimate, len(p.runtimes))
	for key, estimate := range p.runtimes {
		out[key] = estimate
	}
	return out
}

func defaultFastLanePolicy() fastLanePolicy {
	return fastLanePolicy{longThreshold: fastLaneLongRuntimeThreshold, holdDuration: fastLaneHoldDuration, reserveSlots: 1}
}

func clampFastLaneDuration(value, minimum, maximum time.Duration) time.Duration {
	if value < minimum {
		return minimum
	}
	if value > maximum {
		return maximum
	}
	return value
}

func stepFastLaneDuration(current, target, step, deadband time.Duration) time.Duration {
	if current <= 0 {
		return target
	}
	delta := target - current
	if delta < 0 {
		if -delta <= deadband {
			return current
		}
		if current-step < target {
			return target
		}
		return current - step
	}
	if delta <= deadband {
		return current
	}
	if current+step > target {
		return target
	}
	return current + step
}

func stabilizeFastLanePolicy(current, target fastLanePolicy) fastLanePolicy {
	if current.longThreshold <= 0 || current.holdDuration <= 0 || current.reserveSlots <= 0 {
		return target
	}
	reserveSlots := current.reserveSlots
	if target.reserveSlots > reserveSlots {
		reserveSlots++
	} else if target.reserveSlots < reserveSlots {
		reserveSlots--
	}
	return fastLanePolicy{
		longThreshold: clampFastLaneDuration(
			stepFastLaneDuration(current.longThreshold, target.longThreshold,
				fastLaneThresholdStep, fastLaneThresholdDeadband),
			fastLaneMinLongThreshold, fastLaneMaxLongThreshold),
		holdDuration: clampFastLaneDuration(
			stepFastLaneDuration(current.holdDuration, target.holdDuration,
				fastLaneHoldStep, fastLaneHoldDeadband),
			fastLaneMinHoldDuration, fastLaneMaxHoldDuration),
		reserveSlots: reserveSlots,
	}
}

func fastLaneReserveSlots(capacity, pressure int) int {
	if capacity < 2 {
		return 0
	}
	reserve := max(1, capacity/4)
	reserve = min(reserve, fastLaneMaxReservedSlots)
	switch {
	case pressure >= capacity*8:
		reserve = 1
	case pressure >= capacity*4:
		reserve = max(1, (reserve+1)/2)
	}
	return min(reserve, capacity-1)
}

func deriveFastLanePolicy(poolID string, jobs []crfgithub.AvailableJob,
	runtimes map[runtimeDigest]runtimeEstimate, totalAvailable, capacity int, now time.Time) fastLanePolicy {
	policy := defaultFastLanePolicy()
	if capacity <= 0 || len(jobs) == 0 {
		return policy
	}

	known := make([]time.Duration, 0, min(fastLanePolicySampleSize, len(jobs)))
	stride := max(1, (len(jobs)+fastLanePolicySampleSize-1)/fastLanePolicySampleSize)
	for i := 0; i < len(jobs) && len(known) < fastLanePolicySampleSize; i += stride {
		candidate := makeRankedCandidate(poolID, jobs[i], runtimes, now)
		if candidate.runtimeKnown && !candidate.starved {
			known = append(known, candidate.estimatedRuntime)
		}
	}
	if len(known) >= 4 {
		sort.Slice(known, func(i, j int) bool { return known[i] < known[j] })
		p75 := known[(3*len(known)-1)/4]
		policy.longThreshold = clampFastLaneDuration(
			p75, fastLaneMinLongThreshold, fastLaneMaxLongThreshold)
	}

	pressure := max(totalAvailable, len(jobs))
	switch {
	case pressure >= capacity*8:
		policy.holdDuration = 10 * time.Second
	case pressure >= capacity*4:
		policy.holdDuration = 15 * time.Second
	case pressure <= capacity:
		policy.holdDuration = 25 * time.Second
	default:
		policy.holdDuration = fastLaneHoldDuration
	}
	policy.holdDuration = clampFastLaneDuration(
		policy.holdDuration, fastLaneMinHoldDuration, fastLaneMaxHoldDuration)
	policy.reserveSlots = fastLaneReserveSlots(capacity, pressure)
	return policy
}

func makeRankedCandidate(poolID string, job crfgithub.AvailableJob, runtimes map[runtimeDigest]runtimeEstimate, now time.Time) rankedCandidate {
	const defaultRuntime = 5 * time.Minute
	estimatedRuntime := defaultRuntime
	estimate, runtimeKnown := runtimes[runtimeKey(poolID, job.Metadata)]
	if runtimeKnown {
		estimatedRuntime = estimate.duration
	}
	age := now.Sub(job.Metadata.QueueTime)
	return rankedCandidate{
		job: job, estimatedRuntime: estimatedRuntime, runtimeKnown: runtimeKnown,
		starved: !job.Metadata.QueueTime.IsZero() && age >= queueStarvationAge,
	}
}

func candidateLess(left, right rankedCandidate) bool {
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
}

func rankCandidates(poolID string, jobs []crfgithub.AvailableJob, runtimes map[runtimeDigest]runtimeEstimate, now time.Time) []rankedCandidate {
	ranked := make([]rankedCandidate, len(jobs))
	for i, job := range jobs {
		ranked[i] = makeRankedCandidate(poolID, job, runtimes, now)
	}
	sort.SliceStable(ranked, func(i, j int) bool { return candidateLess(ranked[i], ranked[j]) })
	return ranked
}

type candidateMaxHeap []rankedCandidate

func (h candidateMaxHeap) Len() int      { return len(h) }
func (h candidateMaxHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h candidateMaxHeap) Less(i, j int) bool {
	return candidateLess(h[j], h[i])
}
func (h *candidateMaxHeap) Push(value any) { *h = append(*h, value.(rankedCandidate)) }
func (h *candidateMaxHeap) Pop() any {
	old := *h
	last := len(old) - 1
	value := old[last]
	*h = old[:last]
	return value
}

func topCandidates(poolID string, jobs []crfgithub.AvailableJob, runtimes map[runtimeDigest]runtimeEstimate, now time.Time, limit int) []rankedCandidate {
	if limit <= 0 || len(jobs) == 0 {
		return nil
	}
	if limit >= len(jobs) {
		return rankCandidates(poolID, jobs, runtimes, now)
	}
	selected := make(candidateMaxHeap, limit)
	for i, job := range jobs[:limit] {
		selected[i] = makeRankedCandidate(poolID, job, runtimes, now)
	}
	heap.Init(&selected)
	for _, job := range jobs[limit:] {
		candidate := makeRankedCandidate(poolID, job, runtimes, now)
		if candidateLess(candidate, selected[0]) {
			selected[0] = candidate
			heap.Fix(&selected, 0)
		}
	}
	sort.SliceStable(selected, func(i, j int) bool { return candidateLess(selected[i], selected[j]) })
	return selected
}

func rankAvailable(poolID string, jobs []crfgithub.AvailableJob, runtimes map[runtimeDigest]runtimeEstimate, now time.Time) []crfgithub.AvailableJob {
	candidates := rankCandidates(poolID, jobs, runtimes, now)
	ranked := make([]crfgithub.AvailableJob, len(candidates))
	for i, candidate := range candidates {
		ranked[i] = candidate.job
	}
	return ranked
}

func fastLaneEligible(candidate rankedCandidate, longThreshold time.Duration) bool {
	if longThreshold <= 0 {
		longThreshold = fastLaneLongRuntimeThreshold
	}
	return candidate.starved || !candidate.runtimeKnown || candidate.estimatedRuntime < longThreshold
}

func (p *Poller) admissionSelectionWithRuntimes(batch crfgithub.MessageBatch, poolID string, capacity int,
	now time.Time, allowBorrow bool, policy fastLanePolicy,
	runtimes map[runtimeDigest]runtimeEstimate) admissionDecision {
	if policy.longThreshold <= 0 || policy.holdDuration <= 0 {
		policy = defaultFastLanePolicy()
	}
	if policy.reserveSlots <= 0 {
		policy.reserveSlots = 1
	}
	if capacity <= 0 {
		return admissionDecision{policy: policy}
	}
	remaining := capacity
	if batch.Statistics != nil {
		switch assigned := batch.Statistics.TotalAssignedJobs; {
		case assigned <= 0:
			remaining = capacity
		case assigned >= capacity:
			remaining = 0
		default:
			remaining = capacity - assigned
		}
	}
	if remaining == 0 {
		return admissionDecision{policy: policy}
	}
	if len(batch.AvailableJobs) == 0 {
		limit := min(remaining, len(batch.Available))
		return admissionDecision{requestIDs: slices.Clone(batch.Available[:limit]), borrowFastLane: allowBorrow, policy: policy}
	}
	limit := min(remaining, len(batch.AvailableJobs))
	ranked := topCandidates(poolID, batch.AvailableJobs, runtimes, now, limit)
	reserveFastLane := false
	selectedLimit := limit
	if !allowBorrow && capacity >= 2 && remaining > 0 && len(batch.AvailableJobs) >= remaining {
		maxReserve := min(policy.reserveSlots, min(fastLaneMaxReservedSlots, remaining))
		reserveCount := 0
		for i := 0; i < maxReserve; i++ {
			candidate := ranked[remaining-1-i]
			if !candidate.runtimeKnown || candidate.starved || candidate.estimatedRuntime < policy.longThreshold {
				break
			}
			reserveCount++
		}
		if reserveCount > 0 {
			selectedLimit -= reserveCount
			reserveFastLane = true
			policy.reserveSlots = reserveCount
			marginal := ranked[remaining-1]
			if marginal.estimatedRuntime >= 2*policy.longThreshold {
				policy.holdDuration = clampFastLaneDuration(
					policy.holdDuration+fastLaneHoldStep, fastLaneMinHoldDuration, fastLaneMaxHoldDuration)
			}
		}
	}
	selected := make([]int64, 0, selectedLimit)
	for _, candidate := range ranked[:selectedLimit] {
		selected = append(selected, candidate.job.RequestID)
	}
	return admissionDecision{requestIDs: selected, reserveFastLane: reserveFastLane,
		borrowFastLane: allowBorrow, policy: policy}
}

func (p *Poller) admissionSelectionWithPolicy(batch crfgithub.MessageBatch, poolID string, capacity int,
	now time.Time, allowBorrow bool, policy fastLanePolicy) admissionDecision {
	return p.admissionSelectionWithRuntimes(batch, poolID, capacity, now, allowBorrow,
		policy, p.runtimeSnapshot())
}

func (p *Poller) admissionSelection(batch crfgithub.MessageBatch, poolID string, capacity int,
	now time.Time, allowBorrow bool) admissionDecision {
	return p.admissionSelectionWithPolicy(batch, poolID, capacity, now, allowBorrow, defaultFastLanePolicy())
}

func (p *Poller) selectedAvailable(batch crfgithub.MessageBatch, poolID string, capacity int, now time.Time) []int64 {
	return p.admissionSelection(batch, poolID, capacity, now, true).requestIDs
}
