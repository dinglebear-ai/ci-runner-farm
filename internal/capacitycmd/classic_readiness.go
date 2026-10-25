package capacitycmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"time"

	"github.com/unraid/ci-runner-farm/internal/localchecks"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// WriteClassicLocalChecksReadiness observes the existing protected classic owner.
// It shares the policy lease and reads the existing ledger without initializing
// it. No native service, job history, new grant or fallback runner is fabricated.
func WriteClassicLocalChecksReadiness(arguments []string, output io.Writer) (result error) {
	if os.Geteuid() != 0 || len(arguments) != 1 || arguments[0] != "local-checks-readiness" {
		return errors.New("classic_local_checks_readiness_closed_root_command_required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	lease, err := hostcapacity.Acquire(ctx, hostcapacity.ConfigPath, false)
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, lease.Close()) }()
	return writeClassicReadiness(lease.Config, output, localchecks.WriteRuntimeReadiness, func(config *hostcapacity.Config) (sharedcapacity.Diagnostics, error) {
		broker := sharedcapacity.Broker{Path: config.LedgerPath}
		return broker.Diagnose(&config.Policy)
	})
}

func writeClassicReadiness(config *hostcapacity.Config, output io.Writer, readiness func(string, io.Writer) error, diagnose func(*hostcapacity.Config) (sharedcapacity.Diagnostics, error)) error {
	var raw bytes.Buffer
	if err := readiness(ClassicLocalChecksBinding, &raw); err != nil {
		return err
	}
	var value struct {
		Protocol         string `json:"protocol"`
		RuntimeQualified bool   `json:"runtimeQualified"`
		Host             string `json:"host"`
		Epoch            string `json:"epoch"`
		Image            string `json:"image"`
		Reason           string `json:"reason"`
	}
	if err := json.Unmarshal(raw.Bytes(), &value); err != nil {
		return err
	}
	if value.Protocol != localchecks.NativeProtocol || value.Host != config.Host || value.Epoch != config.Epoch || config.Mode != "active" {
		return errors.New("classic_local_checks_owner_changed")
	}
	admission, err := diagnose(config)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(struct {
		Protocol  string                     `json:"protocol"`
		Transport string                     `json:"transport"`
		Readiness any                        `json:"readiness"`
		Admission sharedcapacity.Diagnostics `json:"admission"`
	}{"farm-classic-capabilities/v1", "classic", value, admission})
}

// ReviewClassicLocalChecksQualification uses the existing evidence reviewer and
// fixed classic binding. It only proposes a record; it never promotes one.
func ReviewClassicLocalChecksQualification(arguments []string, output io.Writer) error {
	if os.Geteuid() != 0 || len(arguments) != 3 || arguments[0] != "local-checks-qualification-review" {
		return errors.New("classic_local_checks_review_closed_root_command_required")
	}
	return localchecks.ReviewRuntimeQualification(ClassicLocalChecksBinding, arguments[1], arguments[2], output)
}
