package probe

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
)

type WorkloadEvidence struct {
	TotalAssignedJobs        bool `json:"total_assigned_jobs"`
	ZeroToOne                bool `json:"zero_to_one"`
	CancelReassign           bool `json:"cancel_reassign"`
	AckReplay                bool `json:"ack_replay"`
	NestedCgroupCharging     bool `json:"nested_cgroup_charging"`
	ClassicQuarantineBarrier bool `json:"classic_quarantine_barrier"`
}

type LiveConfig struct {
	Owner                     string           `json:"owner"`
	RunnerGroupName           string           `json:"runner_group_name"`
	RunnerGroupID             int64            `json:"runner_group_id"`
	QuarantineRunnerGroupName string           `json:"quarantine_runner_group_name"`
	RunnerGroupPolicy         string           `json:"runner_group_policy"`
	InstallationID            string           `json:"installation_id"`
	HostID                    string           `json:"host_id"`
	PluginDigest              string           `json:"plugin_digest"`
	HelperDigest              string           `json:"helper_digest"`
	ModuleRevision            string           `json:"module_revision"`
	GoVersion                 string           `json:"go_version"`
	ImageDigest               string           `json:"image_digest"`
	DockerfileDigest          string           `json:"dockerfile_digest"`
	EntrypointDigest          string           `json:"entrypoint_digest"`
	Workload                  WorkloadEvidence `json:"workload"`
}

type sessionCloser interface {
	CloseMessageSession(context.Context, crfgithub.Session) error
}

func exactScaleSet(actual crfgithub.ScaleSet, id int64, name string, groupID int64, labels []string) bool {
	if actual.ID != id || actual.Name != name || actual.RunnerGroupID != groupID {
		return false
	}
	got, want := crfgithub.LabelsForComparison(actual, labels), slices.Clone(labels)
	slices.Sort(got)
	slices.Sort(want)
	return slices.Equal(got, want)
}

func RunLive(ctx context.Context, cfg LiveConfig, api crfgithub.ScaleSetAPI) (Record, error) {
	if api == nil || cfg.Owner == "" || cfg.RunnerGroupName == "" ||
		cfg.RunnerGroupID <= 0 ||
		cfg.QuarantineRunnerGroupName == "" ||
		cfg.RunnerGroupPolicy != "selected_repositories" {
		return Record{}, errors.New("invalid_live_probe_config")
	}
	group, err := api.GetRunnerGroupByName(ctx, cfg.RunnerGroupName)
	if err != nil {
		return Record{}, err
	}
	// REVIEW(crf-v3q.13.2, MUST-CHECK): RunnerGroupID is resolved from the
	// GitHub REST runner-groups endpoint only after it proves selected
	// repository visibility. Bind the Actions-service group to that exact
	// REST-observed identity before making any remote mutation. The separate
	// quarantine group is always deny-public and has no repositories.
	if group.ID != cfg.RunnerGroupID || group.IsDefault || group.Name != cfg.RunnerGroupName {
		return Record{}, errors.New("restricted_runner_group_required")
	}
	quarantineGroup, err := api.GetRunnerGroupByName(ctx, cfg.QuarantineRunnerGroupName)
	if err != nil {
		return Record{}, err
	}
	if quarantineGroup.ID <= 0 || quarantineGroup.IsDefault ||
		quarantineGroup.Name != cfg.QuarantineRunnerGroupName ||
		quarantineGroup.ID == group.ID {
		return Record{}, errors.New("quarantine_runner_group_required")
	}
	nonce := fmt.Sprintf("%x", time.Now().UTC().UnixNano())
	if len(nonce) > 16 {
		nonce = nonce[len(nonce)-16:]
	}
	name := "crf-probe-" + nonce
	initialLabels := []string{"crf-probe-ineligible-" + nonce, "crf-probe-multi-" + nonce}
	created, err := api.CreateRunnerScaleSet(ctx, crfgithub.CreateSpec{
		Name: name, RunnerGroupID: quarantineGroup.ID, Labels: initialLabels,
	})
	if err != nil {
		return Record{}, err
	}
	remaining := []int64{created.ID}
	var session crfgithub.Session
	cleanup := func() error {
		var cleanupErr error
		if session.ID != "" {
			closer, ok := api.(sessionCloser)
			if !ok {
				cleanupErr = errors.New("message_session_cleanup_unsupported")
			} else if err := closer.CloseMessageSession(ctx, session); err != nil {
				cleanupErr = err
			}
		}
		if created.ID > 0 {
			if err := api.DeleteRunnerScaleSet(ctx, created.ID); err != nil && cleanupErr == nil {
				cleanupErr = err
			} else if err == nil {
				remaining = nil
			}
		}
		return cleanupErr
	}
	failWithCleanup := func(cause error) (Record, error) {
		if cleanupErr := cleanup(); cleanupErr != nil {
			return Record{}, fmt.Errorf("%w; cleanup: %v", cause, cleanupErr)
		}
		return Record{}, cause
	}
	if created.ID <= 0 {
		return failWithCleanup(errors.New("invalid_created_scale_set"))
	}
	fetched, err := api.GetRunnerScaleSet(ctx, created.ID)
	if err != nil || !exactScaleSet(fetched, created.ID, name, quarantineGroup.ID, initialLabels) {
		return failWithCleanup(errors.New("create_get_mismatch"))
	}
	_, err = api.UpdateRunnerScaleSet(ctx, created.ID, crfgithub.UpdateSpec{
		Name: name, RunnerGroupID: group.ID, Labels: initialLabels,
	})
	if err != nil {
		return failWithCleanup(errors.New("eligibility_update_failed"))
	}
	updated, err := api.GetRunnerScaleSet(ctx, created.ID)
	if err != nil || !exactScaleSet(updated, created.ID, name, group.ID, initialLabels) {
		return failWithCleanup(fmt.Errorf(
			"eligibility_update_mismatch: id=%d want=%d name=%q want=%q group=%d want=%d labels=%v want=%v",
			updated.ID, created.ID, updated.Name, name, updated.RunnerGroupID, group.ID,
			updated.Labels, initialLabels,
		))
	}
	session, err = api.CreateMessageSession(ctx, created.ID)
	if err != nil || session.ID == "" {
		return failWithCleanup(errors.New("message_session_failed"))
	}
	for _, capacity := range []int{0, 1} {
		batch, pollErr := api.GetMessage(ctx, session, 0, capacity)
		if pollErr != nil {
			return failWithCleanup(pollErr)
		}
		if batch.MessageID > 0 {
			if batch.Statistics == nil {
				return failWithCleanup(errors.New("statistics_missing"))
			}
			if err := api.AcknowledgeMessage(ctx, session, batch.MessageID); err != nil {
				return failWithCleanup(err)
			}
		}
	}
	jit, err := api.GenerateJitRunnerConfig(ctx, created.ID,
		crfgithub.JITRequest{Name: "crf-probe-runner-" + nonce, WorkFolder: "_work"})
	if err != nil || len(jit) == 0 || len(jit) > 64<<10 {
		return failWithCleanup(errors.New("jit_probe_failed"))
	}
	workload := cfg.Workload
	if !workload.TotalAssignedJobs || !workload.ZeroToOne || !workload.CancelReassign ||
		!workload.AckReplay || !workload.NestedCgroupCharging ||
		!workload.ClassicQuarantineBarrier {
		return failWithCleanup(errors.New("workload_evidence_incomplete"))
	}
	if err := cleanup(); err != nil || len(remaining) != 0 {
		return Record{}, fmt.Errorf("exact_cleanup_failed: %w", err)
	}
	capabilities := map[string]bool{
		"create_get_update_delete":   true,
		"restricted_group":           true,
		"multiple_labels":            len(initialLabels) > 1,
		"total_assigned_jobs":        workload.TotalAssignedJobs,
		"jit_current_image":          len(jit) > 0,
		"zero_to_one":                workload.ZeroToOne,
		"cancel_reassign":            workload.CancelReassign,
		"ack_replay":                 workload.AckReplay,
		"dynamic_capacity":           true,
		"eligibility_barrier":        quarantineGroup.ID != group.ID,
		"nested_cgroup_charging":     workload.NestedCgroupCharging,
		"classic_quarantine_barrier": workload.ClassicQuarantineBarrier,
		"exact_cleanup":              true,
	}
	record := Record{PluginDigest: cfg.PluginDigest, HelperDigest: cfg.HelperDigest,
		ModuleRevision: cfg.ModuleRevision, GoVersion: cfg.GoVersion,
		ImageDigest: cfg.ImageDigest, DockerfileDigest: cfg.DockerfileDigest,
		EntrypointDigest: cfg.EntrypointDigest, Owner: cfg.Owner, APIURL: "https://api.github.com",
		InstallationID: cfg.InstallationID, HostID: cfg.HostID, RunnerGroupID: group.ID,
		QuarantineRunnerGroupID: quarantineGroup.ID,
		RunnerGroupPolicy:       cfg.RunnerGroupPolicy, Capabilities: capabilities,
		Cleanup: Cleanup{Complete: true, IDs: []int64{}}}
	if err := record.Seal(time.Now().UTC()); err != nil {
		return Record{}, err
	}
	if strings.TrimSpace(record.CompatibilityRecordID) == "" {
		return Record{}, errors.New("compatibility_record_not_sealed")
	}
	return record, nil
}
