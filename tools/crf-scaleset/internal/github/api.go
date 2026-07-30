package github

import (
	"context"
	"fmt"
	"sync"

	"github.com/actions/scaleset"
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
type MessageBatch struct {
	MessageID  int64
	Statistics *Statistics
	Assigned   []int64
}
type AcquireRequest struct{ RequestIDs []int64 }
type AcquireResult struct{ AcquiredIDs []int64 }
type JITRequest struct {
	Name       string
	WorkFolder string
}

type ScaleSetAPI interface {
	CreateRunnerScaleSet(context.Context, CreateSpec) (ScaleSet, error)
	GetRunnerScaleSet(context.Context, int64) (ScaleSet, error)
	UpdateRunnerScaleSet(context.Context, int64, UpdateSpec) (ScaleSet, error)
	DeleteRunnerScaleSet(context.Context, int64) error
	GetRunnerGroupByName(context.Context, string) (RunnerGroup, error)
	CreateMessageSession(context.Context, int64) (Session, error)
	GetMessage(context.Context, Session, int) (MessageBatch, error)
	AcquireJobs(context.Context, Session, AcquireRequest) (AcquireResult, error)
	AcknowledgeMessage(context.Context, Session, int64) error
	GenerateJitRunnerConfig(context.Context, int64, JITRequest) ([]byte, error)
}

type Adapter struct {
	client   *scaleset.Client
	owner    string
	mu       sync.Mutex
	sessions map[int64]*scaleset.MessageSessionClient
}

func NewAdapter(client *scaleset.Client, owner string) *Adapter {
	return &Adapter{client: client, owner: owner, sessions: make(map[int64]*scaleset.MessageSessionClient)}
}

func labels(in []string) []scaleset.Label {
	out := make([]scaleset.Label, 0, len(in))
	for _, label := range in {
		out = append(out, scaleset.Label{Type: "System", Name: label})
	}
	return out
}
func fromScaleSet(in *scaleset.RunnerScaleSet) ScaleSet {
	out := ScaleSet{ID: int64(in.ID), Name: in.Name, RunnerGroupID: int64(in.RunnerGroupID)}
	for _, label := range in.Labels {
		out.Labels = append(out.Labels, label.Name)
	}
	return out
}
func (a *Adapter) CreateRunnerScaleSet(ctx context.Context, spec CreateSpec) (ScaleSet, error) {
	v, err := a.client.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{Name: spec.Name, RunnerGroupID: int(spec.RunnerGroupID), Labels: labels(spec.Labels), RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true}})
	if err != nil {
		return ScaleSet{}, err
	}
	return fromScaleSet(v), nil
}
func (a *Adapter) GetRunnerScaleSet(ctx context.Context, id int64) (ScaleSet, error) {
	v, err := a.client.GetRunnerScaleSetByID(ctx, int(id))
	if err != nil {
		return ScaleSet{}, err
	}
	return fromScaleSet(v), nil
}
func (a *Adapter) UpdateRunnerScaleSet(ctx context.Context, id int64, spec UpdateSpec) (ScaleSet, error) {
	v, err := a.client.UpdateRunnerScaleSet(ctx, int(id), &scaleset.RunnerScaleSet{Name: spec.Name, RunnerGroupID: int(spec.RunnerGroupID), Labels: labels(spec.Labels), RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true}})
	if err != nil {
		return ScaleSet{}, err
	}
	return fromScaleSet(v), nil
}
func (a *Adapter) DeleteRunnerScaleSet(ctx context.Context, id int64) error {
	return a.client.DeleteRunnerScaleSet(ctx, int(id))
}
func (a *Adapter) GetRunnerGroupByName(ctx context.Context, name string) (RunnerGroup, error) {
	v, err := a.client.GetRunnerGroupByName(ctx, name)
	if err != nil {
		return RunnerGroup{}, err
	}
	return RunnerGroup{ID: int64(v.ID), Name: v.Name, IsDefault: v.IsDefault}, nil
}
func (a *Adapter) CreateMessageSession(ctx context.Context, id int64) (Session, error) {
	v, err := a.client.MessageSessionClient(ctx, int(id), a.owner)
	if err != nil {
		return Session{}, err
	}
	a.mu.Lock()
	a.sessions[id] = v
	a.mu.Unlock()
	return Session{ScaleSetID: id, ID: v.Session().SessionID.String()}, nil
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
func stats(v *scaleset.RunnerScaleSetStatistic) *Statistics {
	if v == nil {
		return nil
	}
	return &Statistics{v.TotalAvailableJobs, v.TotalAcquiredJobs, v.TotalAssignedJobs, v.TotalRunningJobs, v.TotalRegisteredRunners, v.TotalBusyRunners, v.TotalIdleRunners}
}
func (a *Adapter) GetMessage(ctx context.Context, s Session, max int) (MessageBatch, error) {
	c, err := a.session(s)
	if err != nil {
		return MessageBatch{}, err
	}
	v, err := c.GetMessage(ctx, 0, max)
	if err != nil || v == nil {
		return MessageBatch{}, err
	}
	out := MessageBatch{MessageID: int64(v.MessageID), Statistics: stats(v.Statistics)}
	for _, job := range v.JobAssignedMessages {
		out.Assigned = append(out.Assigned, job.RunnerRequestID)
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
func (a *Adapter) GenerateJitRunnerConfig(ctx context.Context, id int64, req JITRequest) ([]byte, error) {
	v, err := a.client.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{Name: req.Name, WorkFolder: req.WorkFolder}, int(id))
	if err != nil {
		return nil, err
	}
	return []byte(v.EncodedJITConfig), nil
}

var _ ScaleSetAPI = (*Adapter)(nil)
