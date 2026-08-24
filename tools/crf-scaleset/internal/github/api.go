package github

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/actions/scaleset"
)

var (
	ErrNotFound        = errors.New("scale_set_not_found")
	ErrInvalidResponse = errors.New("invalid_scale_set_response")
)

const (
	maxJSONSafeInteger int64 = 1<<53 - 1
	maxAcquirableJobs        = 10_000
)

type ScaleSet struct {
	ID            int64
	Name          string
	RunnerGroupID int64
	Labels        []string
}
type CreateSpec = ScaleSet
type UpdateSpec = ScaleSet
type RunnerGroup struct {
	ID        int64
	Name      string
	IsDefault bool
}
type Session struct {
	ScaleSetID int64
	ID         string
}
type Statistics struct {
	TotalAvailableJobs     int
	TotalAcquiredJobs      int
	TotalAssignedJobs      int
	TotalRunningJobs       int
	TotalRegisteredRunners int
	TotalBusyRunners       int
	TotalIdleRunners       int
}
type JobMetadata struct {
	OwnerName      string
	RepositoryName string
	JobWorkflowRef string
	JobDisplayName string
	QueueTime      time.Time
}

type AvailableJob struct {
	RequestID int64
	Metadata  JobMetadata
}

type CompletedJob struct {
	Metadata         JobMetadata
	RunnerAssignTime time.Time
	FinishTime       time.Time
}

type MessageBatch struct {
	MessageID       int64
	Statistics      *Statistics
	Available       []int64
	AvailableJobs   []AvailableJob
	CompletedJobs   []CompletedJob
	AssignedHandles []int64
	ReleasedHandles []int64
}
type AcquireRequest struct{ RequestIDs []int64 }
type AcquireResult struct{ AcquiredIDs []int64 }
type JITRequest struct {
	Name       string
	WorkFolder string
}

// JITIssue carries both halves of a just-in-time runner registration: the
// descriptor handed to the runner process, and the GitHub-side runner id that
// must be removed if the runner never claims its job. Without the id an
// unclaimed registration stays in the org forever.
type JITIssue struct {
	Descriptor []byte
	RunnerID   int64
}

type ScaleSetAPI interface {
	CreateRunnerScaleSet(context.Context, CreateSpec) (ScaleSet, error)
	GetRunnerScaleSet(context.Context, int64) (ScaleSet, error)
	GetRunnerScaleSetByName(context.Context, int64, string) (ScaleSet, error)
	UpdateRunnerScaleSet(context.Context, int64, UpdateSpec) (ScaleSet, error)
	DeleteRunnerScaleSet(context.Context, int64) error
	GetRunnerGroupByName(context.Context, string) (RunnerGroup, error)
	CreateMessageSession(context.Context, int64) (Session, error)
	GetMessage(context.Context, Session, int64, int) (MessageBatch, error)
	GetAcquirableJobs(context.Context, int64) ([]AvailableJob, error)
	AcquireJobs(context.Context, Session, AcquireRequest) (AcquireResult, error)
	AcknowledgeMessage(context.Context, Session, int64) error
	GenerateJitRunnerConfig(context.Context, int64, JITRequest) (JITIssue, error)
	RemoveRunner(context.Context, int64) error
}

type ScaleSetClientFactory func(int64) (*scaleset.Client, error)

type Adapter struct {
	client        *scaleset.Client
	owner         string
	clientFactory ScaleSetClientFactory
	closeSession  func(context.Context, *scaleset.MessageSessionClient) error
	mu            sync.Mutex
	sessions      map[int64]*scaleset.MessageSessionClient
}

func NewAdapter(client *scaleset.Client, owner string) *Adapter {
	return NewAdapterWithScaleSetClientFactory(client, owner, nil)
}

func NewAdapterWithScaleSetClientFactory(client *scaleset.Client, owner string, factory ScaleSetClientFactory) *Adapter {
	return &Adapter{client: client, owner: owner, clientFactory: factory,
		sessions: make(map[int64]*scaleset.MessageSessionClient)}
}

func (a *Adapter) adminClient() (*scaleset.Client, error) {
	if a == nil || a.client == nil {
		return nil, errors.New("scale_set_client_required")
	}
	return a.client, nil
}

func (a *Adapter) clientForScaleSet(id int64) (*scaleset.Client, error) {
	if a == nil || id <= 0 {
		return nil, fmt.Errorf("invalid scale set id")
	}
	if a.clientFactory == nil {
		return a.adminClient()
	}
	client, err := a.clientFactory(id)
	if err != nil {
		return nil, err
	}
	if client == nil {
		return nil, errors.New("scale_set_client_required")
	}
	return client, nil
}

func labels(name string, in []string) []scaleset.Label {
	out := make([]scaleset.Label, 0, len(in)+1)
	out = append(out, scaleset.Label{Type: "System", Name: name})
	seen := map[string]bool{strings.ToLower(name): true}
	for _, label := range in {
		key := strings.ToLower(label)
		if seen[key] {
			continue
		}
		out = append(out, scaleset.Label{Type: "System", Name: label})
		seen[key] = true
	}
	return out
}
func fromScaleSet(in *scaleset.RunnerScaleSet) (ScaleSet, error) {
	if in == nil || in.ID <= 0 || strings.TrimSpace(in.Name) == "" || in.RunnerGroupID <= 0 {
		return ScaleSet{}, ErrInvalidResponse
	}
	out := ScaleSet{ID: int64(in.ID), Name: in.Name, RunnerGroupID: int64(in.RunnerGroupID)}
	for _, label := range in.Labels {
		if strings.TrimSpace(label.Name) == "" {
			return ScaleSet{}, ErrInvalidResponse
		}
		out.Labels = append(out.Labels, label.Name)
	}
	return out, nil
}

// LabelsForComparison removes GitHub's implicit canonical name label only when
// callers did not intentionally configure that same value as a routing label.
// Stable routing-name scale sets therefore keep ci-pool-* in the compared
// labels, while opaque probe/legacy names remain invisible to configured-label
// ownership checks.
func LabelsForComparison(actual ScaleSet, expected []string) []string {
	out := slices.Clone(actual.Labels)
	nameExpected := slices.ContainsFunc(expected, func(label string) bool {
		return strings.EqualFold(label, actual.Name)
	})
	if !nameExpected {
		out = slices.DeleteFunc(out, func(label string) bool {
			return strings.EqualFold(label, actual.Name)
		})
	}
	return out
}
func (a *Adapter) CreateRunnerScaleSet(ctx context.Context, spec CreateSpec) (ScaleSet, error) {
	client, err := a.adminClient()
	if err != nil {
		return ScaleSet{}, err
	}
	v, err := client.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{Name: spec.Name, RunnerGroupID: int(spec.RunnerGroupID), Labels: labels(spec.Name, spec.Labels), RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true}})
	if err != nil {
		return ScaleSet{}, err
	}
	return fromScaleSet(v)
}
func (a *Adapter) GetRunnerScaleSet(ctx context.Context, id int64) (ScaleSet, error) {
	client, err := a.adminClient()
	if err != nil {
		return ScaleSet{}, err
	}
	v, err := client.GetRunnerScaleSetByID(ctx, int(id))
	if err != nil {
		if strings.Contains(err.Error(), `status="404`) || strings.Contains(err.Error(), "status code: 404") {
			return ScaleSet{}, ErrNotFound
		}
		return ScaleSet{}, err
	}
	return fromScaleSet(v)
}
func (a *Adapter) GetRunnerScaleSetByName(ctx context.Context, groupID int64, name string) (ScaleSet, error) {
	client, err := a.adminClient()
	if err != nil {
		return ScaleSet{}, err
	}
	v, err := client.GetRunnerScaleSet(ctx, int(groupID), name)
	if err != nil {
		return ScaleSet{}, err
	}
	if v == nil {
		return ScaleSet{}, ErrNotFound
	}
	return fromScaleSet(v)
}
func (a *Adapter) UpdateRunnerScaleSet(ctx context.Context, id int64, spec UpdateSpec) (ScaleSet, error) {
	client, err := a.adminClient()
	if err != nil {
		return ScaleSet{}, err
	}
	v, err := client.UpdateRunnerScaleSet(ctx, int(id), &scaleset.RunnerScaleSet{
		ID: int(id), Name: spec.Name, RunnerGroupID: int(spec.RunnerGroupID),
		Labels: labels(spec.Name, spec.Labels), RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true},
	})
	if err != nil {
		return ScaleSet{}, err
	}
	return fromScaleSet(v)
}
func (a *Adapter) DeleteRunnerScaleSet(ctx context.Context, id int64) error {
	client, err := a.adminClient()
	if err != nil {
		return err
	}
	err = client.DeleteRunnerScaleSet(ctx, int(id))
	if err != nil && (strings.Contains(err.Error(), `status="404`) || strings.Contains(err.Error(), "status code: 404")) {
		return ErrNotFound
	}
	return err
}
func (a *Adapter) GetRunnerGroupByName(ctx context.Context, name string) (RunnerGroup, error) {
	client, err := a.adminClient()
	if err != nil {
		return RunnerGroup{}, err
	}
	v, err := client.GetRunnerGroupByName(ctx, name)
	if err != nil {
		return RunnerGroup{}, err
	}
	return RunnerGroup{ID: int64(v.ID), Name: v.Name, IsDefault: v.IsDefault}, nil
}
func (a *Adapter) CreateMessageSession(ctx context.Context, id int64) (Session, error) {
	client, err := a.clientForScaleSet(id)
	if err != nil {
		return Session{}, err
	}
	v, err := client.MessageSessionClient(ctx, int(id), a.owner)
	if err != nil {
		return Session{}, err
	}
	a.mu.Lock()
	a.sessions[id] = v
	a.mu.Unlock()
	return Session{ScaleSetID: id, ID: v.Session().SessionID.String()}, nil
}
func (a *Adapter) CloseMessageSession(ctx context.Context, session Session) error {
	a.mu.Lock()
	client := a.sessions[session.ScaleSetID]
	a.mu.Unlock()
	if client == nil {
		return nil
	}
	closeSession := a.closeSession
	if closeSession == nil {
		closeSession = func(ctx context.Context, client *scaleset.MessageSessionClient) error {
			return client.Close(ctx)
		}
	}
	if err := closeSession(ctx, client); err != nil {
		return err
	}
	a.mu.Lock()
	if a.sessions[session.ScaleSetID] == client {
		delete(a.sessions, session.ScaleSetID)
	}
	a.mu.Unlock()
	return nil
}
func (a *Adapter) session(s Session) (*scaleset.MessageSessionClient, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	v := a.sessions[s.ScaleSetID]
	if v == nil {
		return nil, fmt.Errorf("unknown session")
	}
	return v, nil
}
func stats(v *scaleset.RunnerScaleSetStatistic) (*Statistics, error) {
	if v == nil {
		return nil, nil
	}
	decoded := &Statistics{v.TotalAvailableJobs, v.TotalAcquiredJobs, v.TotalAssignedJobs, v.TotalRunningJobs, v.TotalRegisteredRunners, v.TotalBusyRunners, v.TotalIdleRunners}
	if err := ValidateStatistics(decoded); err != nil {
		return nil, err
	}
	return decoded, nil
}

func ValidateStatistics(v *Statistics) error {
	if v == nil {
		return nil
	}
	if v.TotalAvailableJobs < 0 || v.TotalAcquiredJobs < 0 || v.TotalAssignedJobs < 0 ||
		v.TotalRunningJobs < 0 || v.TotalRegisteredRunners < 0 || v.TotalBusyRunners < 0 ||
		v.TotalIdleRunners < 0 {
		return ErrInvalidResponse
	}
	return nil
}

func jobHandle(scaleSetID int64, job *scaleset.JobMessageBase) (int64, error) {
	if scaleSetID <= 0 || job == nil {
		return 0, errors.New("invalid_assigned_job_identity")
	}
	identity := ""
	if job.WorkflowRunID > 0 && strings.TrimSpace(job.JobDisplayName) != "" {
		identity = strings.Join([]string{
			"workflow-job",
			strconv.FormatInt(job.WorkflowRunID, 10),
			strings.TrimSpace(job.OwnerName),
			strings.TrimSpace(job.RepositoryName),
			strings.TrimSpace(job.JobWorkflowRef),
			strings.TrimSpace(job.JobDisplayName),
		}, "\x00")
	} else if jobID := strings.TrimSpace(job.JobID); jobID != "" {
		identity = "job-id\x00" + jobID
	}
	if identity == "" {
		return 0, errors.New("invalid_assigned_job_identity")
	}
	sum := sha256.Sum256([]byte(strconv.FormatInt(scaleSetID, 10) + "\x00" + identity))
	handle := int64(binary.BigEndian.Uint64(sum[:8]) & uint64(maxJSONSafeInteger))
	if handle == 0 {
		handle = 1
	}
	return handle, nil
}

func assignedJobHandle(scaleSetID int64, job *scaleset.JobAssigned) (int64, error) {
	if job == nil {
		return 0, errors.New("invalid_assigned_job_identity")
	}
	return jobHandle(scaleSetID, &job.JobMessageBase)
}

func jobMetadata(job *scaleset.JobMessageBase) JobMetadata {
	if job == nil {
		return JobMetadata{}
	}
	return JobMetadata{
		OwnerName:      job.OwnerName,
		RepositoryName: job.RepositoryName,
		JobWorkflowRef: job.JobWorkflowRef,
		JobDisplayName: job.JobDisplayName,
		QueueTime:      job.QueueTime,
	}
}

func decodeAcquirableJobs(jobs []*scaleset.JobAvailable) ([]AvailableJob, error) {
	if len(jobs) > maxAcquirableJobs {
		return nil, ErrInvalidResponse
	}
	out := make([]AvailableJob, 0, len(jobs))
	seen := make(map[int64]bool, len(jobs))
	for _, job := range jobs {
		if job == nil || job.RunnerRequestID <= 0 || seen[job.RunnerRequestID] {
			return nil, ErrInvalidResponse
		}
		seen[job.RunnerRequestID] = true
		out = append(out, AvailableJob{
			RequestID: job.RunnerRequestID, Metadata: jobMetadata(&job.JobMessageBase),
		})
	}
	return out, nil
}

func (a *Adapter) GetAcquirableJobs(ctx context.Context, scaleSetID int64) ([]AvailableJob, error) {
	if scaleSetID <= 0 {
		return nil, ErrInvalidResponse
	}
	client, err := a.adminClient()
	if err != nil {
		return nil, err
	}
	jobs, err := client.GetAcquirableJobs(ctx, int(scaleSetID))
	if err != nil {
		return nil, err
	}
	return decodeAcquirableJobs(jobs)
}

func (a *Adapter) GetMessage(ctx context.Context, s Session, lastMessageID int64, max int) (MessageBatch, error) {
	c, err := a.session(s)
	if err != nil {
		return MessageBatch{}, err
	}
	v, err := c.GetMessage(ctx, int(lastMessageID), max)
	if err != nil || v == nil {
		return MessageBatch{}, err
	}
	statistics, err := stats(v.Statistics)
	if err != nil {
		return MessageBatch{}, err
	}
	out := MessageBatch{MessageID: int64(v.MessageID), Statistics: statistics}
	for _, job := range v.JobAvailableMessages {
		if job == nil || job.RunnerRequestID <= 0 {
			return MessageBatch{}, errors.New("invalid_available_job_identity")
		}
		out.Available = append(out.Available, job.RunnerRequestID)
		out.AvailableJobs = append(out.AvailableJobs, AvailableJob{
			RequestID: job.RunnerRequestID, Metadata: jobMetadata(&job.JobMessageBase),
		})
	}
	for _, job := range v.JobAssignedMessages {
		handle, err := assignedJobHandle(s.ScaleSetID, job)
		if err != nil {
			return MessageBatch{}, err
		}
		out.AssignedHandles = append(out.AssignedHandles, handle)
	}
	for _, job := range v.JobCompletedMessages {
		if job == nil {
			return MessageBatch{}, errors.New("invalid_completed_job_identity")
		}
		handle, err := jobHandle(s.ScaleSetID, &job.JobMessageBase)
		if err != nil {
			return MessageBatch{}, err
		}
		out.CompletedJobs = append(out.CompletedJobs, CompletedJob{
			Metadata: jobMetadata(&job.JobMessageBase), RunnerAssignTime: job.RunnerAssignTime, FinishTime: job.FinishTime,
		})
		out.ReleasedHandles = append(out.ReleasedHandles, handle)
	}
	return out, nil
}
func (a *Adapter) AcquireJobs(ctx context.Context, s Session, req AcquireRequest) (AcquireResult, error) {
	c, err := a.session(s)
	if err != nil {
		return AcquireResult{}, err
	}
	ids, err := c.AcquireJobs(ctx, req.RequestIDs)
	return AcquireResult{AcquiredIDs: ids}, err
}
func (a *Adapter) AcknowledgeMessage(ctx context.Context, s Session, id int64) error {
	c, err := a.session(s)
	if err != nil {
		return err
	}
	return c.DeleteMessage(ctx, int(id))
}
func (a *Adapter) GenerateJitRunnerConfig(ctx context.Context, id int64, req JITRequest) (JITIssue, error) {
	client, err := a.clientForScaleSet(id)
	if err != nil {
		return JITIssue{}, err
	}
	v, err := client.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{Name: req.Name, WorkFolder: req.WorkFolder}, int(id))
	if err != nil {
		return JITIssue{}, err
	}
	if v.Runner == nil || v.Runner.ID <= 0 {
		return JITIssue{}, ErrInvalidResponse
	}
	return JITIssue{Descriptor: []byte(v.EncodedJITConfig), RunnerID: int64(v.Runner.ID)}, nil
}

// RemoveRunner deletes one runner registration. Deleting an already-absent
// runner is reported as ErrNotFound so callers can treat it as success.
func (a *Adapter) RemoveRunner(ctx context.Context, runnerID int64) error {
	if runnerID <= 0 {
		return ErrInvalidResponse
	}
	client, err := a.adminClient()
	if err != nil {
		return err
	}
	err = client.RemoveRunner(ctx, runnerID)
	if err != nil && (strings.Contains(err.Error(), `status="404`) || strings.Contains(err.Error(), "status code: 404")) {
		return ErrNotFound
	}
	return err
}

var _ ScaleSetAPI = (*Adapter)(nil)
