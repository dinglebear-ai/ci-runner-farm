package localchecks

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
)

const NativeProtocol = "farm-local-checks-worker/v1"

type WorkerContract struct {
	Protocol                   string `json:"protocol"`
	Role                       string `json:"role"`
	QueueOwner                 string `json:"queueOwner"`
	PackManifest               string `json:"packManifest"`
	RequiresInheritedFleetLock bool   `json:"requiresInheritedFleetLock"`
	RuntimeQualified           bool   `json:"runtimeQualified"`
}

// NativeWorkerContract describes the source protocol, never appliance readiness.
func NativeWorkerContract() WorkerContract {
	return WorkerContract{Protocol: NativeProtocol, Role: "local-checks", QueueOwner: "existing-coordinator", PackManifest: "two-pack-canonical-json-sha256/v1", RequiresInheritedFleetLock: true}
}

type NativeCommand struct {
	Protocol    string      `json:"protocol"`
	Action      string      `json:"action"`
	Epoch       string      `json:"epoch"`
	RequestID   string      `json:"requestID,omitempty"`
	ContainerID string      `json:"containerID,omitempty"`
	Submission  *Submission `json:"submission,omitempty"`
}

var nativeEpoch = regexp.MustCompile(`\A[0-9a-f]{32}\z`)

func DecodeNativeCommand(reader io.Reader) (NativeCommand, error) {
	var command NativeCommand
	data, err := io.ReadAll(io.LimitReader(reader, 16385))
	if err != nil || len(data) > 16384 {
		return command, errors.New("local_checks_native_command_invalid")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&command); err != nil {
		return command, errors.New("local_checks_native_command_invalid")
	}
	if decoder.Decode(new(any)) != io.EOF || command.Protocol != NativeProtocol || !nativeEpoch.MatchString(command.Epoch) {
		return command, errors.New("local_checks_native_command_invalid")
	}
	switch command.Action {
	case "create-admit", "qualify":
		if command.Submission == nil || command.Submission.Validate() != nil || command.RequestID != "" || command.ContainerID != "" {
			return command, errors.New("local_checks_native_command_invalid")
		}
	case "admit-start":
		if command.Submission == nil || command.Submission.Validate() != nil || command.RequestID != "" || !immutableContainerID.MatchString(command.ContainerID) {
			return command, errors.New("local_checks_native_command_invalid")
		}
	case "execute", "complete", "cancel":
		if command.Submission != nil || command.ContainerID != "" || !identifier.MatchString(command.RequestID) {
			return command, errors.New("local_checks_native_command_invalid")
		}
	default:
		return command, errors.New("local_checks_native_command_invalid")
	}
	return command, nil
}

// NativeConfiguration is supplied by the native plugin's protected binding,
// not by coordinator requests. No caller-selected path/daemon/image is accepted.
type NativeConfiguration struct {
	ConfigPath, Epoch, Image, SnapshotRoot, DockerRoot, Host, EvidenceRoot string
	SecretEnvironment                                                      []string // In-memory delivery from the protected credential owner only.
}

func HandleNativeCommand(ctx context.Context, configuration NativeConfiguration, command NativeCommand) (NativeReceipt, error) {
	var receipt NativeReceipt
	raw, marshalErr := json.Marshal(command)
	if marshalErr != nil {
		return receipt, errors.New("local_checks_native_command_invalid")
	}
	if _, err := DecodeNativeCommand(bytes.NewReader(raw)); err != nil {
		return receipt, err
	}
	if command.Protocol != NativeProtocol || command.Epoch != configuration.Epoch || !nativeEpoch.MatchString(configuration.Epoch) {
		return receipt, errors.New("local_checks_native_owner_changed")
	}
	driver := DockerNativeDriver{Image: configuration.Image, SourceRoot: filepath.Join(configuration.SnapshotRoot, "repo"), DockerRoot: configuration.DockerRoot}
	err := WithNativeWorker(ctx, configuration.ConfigPath, configuration.Epoch, driver, func(worker NativeJob) error {
		switch command.Action {
		case "create-admit", "admit-start", "qualify":
			if command.Submission == nil {
				return errors.New("local_checks_native_command_invalid")
			}
			s := *command.Submission
			if err := verifyNativeSnapshot(ctx, configuration, s); err != nil {
				return err
			}
			var operationErr error
			if command.Action == "qualify" {
				if err := validateQualificationSubmission(s); err != nil {
					return err
				}
				if err := availableScratch(configuration.SnapshotRoot, s.ScratchMiB); err != nil {
					return err
				}
				if err := preparePrivateDockerRoot(configuration.SnapshotRoot, configuration.DockerRoot, 0); err != nil {
					return err
				}
				receipt, operationErr = worker.Qualify(ctx, s)
			} else if command.Action == "create-admit" {
				if err := preparePrivateDockerRoot(configuration.SnapshotRoot, configuration.DockerRoot, 0); err != nil {
					return err
				}
				receipt, operationErr = worker.CreateAndAdmit(ctx, s)
			} else {
				receipt, operationErr = worker.AdmitStart(ctx, s, command.ContainerID)
			}
			return operationErr
		case "execute":
			_, operationErr := worker.ExecuteChecks(ctx, command.RequestID, configuration.Host, configuration.EvidenceRoot, configuration.SecretEnvironment)
			if native, ok := worker.(*nativeWorker); ok {
				receipt, _ = native.load(command.RequestID)
			}
			return operationErr
		case "cancel":
			return worker.Cancel(ctx, command.RequestID)
		case "complete":
			return worker.Complete(ctx, command.RequestID)
		default:
			return errors.New("local_checks_native_command_invalid")
		}
	})
	return receipt, err
}

func verifyNativeSnapshot(ctx context.Context, configuration NativeConfiguration, s Submission) error {
	manifestPath := filepath.Join(configuration.SnapshotRoot, "intent.json")
	info, err := os.Lstat(manifestPath)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 8192 {
		return errors.New("local_checks_pack_manifest_invalid")
	}
	file, err := os.Open(manifestPath)
	if err != nil {
		return errors.New("local_checks_pack_manifest_invalid")
	}
	snapshot, err := DecodeFleetSnapshot(file)
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return errors.New("local_checks_pack_manifest_invalid")
	}
	if snapshot.Commit != s.Commit || snapshot.Base != s.Base || snapshot.Digest() != s.BundleSHA256 {
		return errors.New("local_checks_pack_manifest_identity_mismatch")
	}
	if err := snapshot.VerifyPacks(ctx, configuration.SnapshotRoot); err != nil {
		return err
	}
	root := filepath.Join(configuration.SnapshotRoot, "repo")
	canonical, resolveErr := filepath.EvalSymlinks(root)
	if resolveErr != nil || canonical != root {
		return errors.New("local_checks_canonical_checkout_required")
	}
	origin, originErr := gitRead(ctx, root, "remote", "get-url", "origin")
	if originErr != nil || (origin != "https://github.com/unraid/core.git" && origin != "https://github.com/unraid/core" && origin != "git@github.com:unraid/core.git") {
		return errors.New("local_checks_repository_mismatch")
	}
	for _, check := range []struct {
		args     []string
		expected string
	}{{[]string{"rev-parse", "--show-toplevel"}, root}, {[]string{"rev-parse", "HEAD"}, snapshot.Commit}, {[]string{"merge-base", snapshot.Commit, snapshot.Base}, snapshot.MergeBase}, {[]string{"status", "--porcelain", "--untracked-files=all"}, ""}} {
		out, err := gitRead(ctx, root, check.args...)
		if err != nil || out != check.expected {
			return errors.New("local_checks_checkout_identity_mismatch")
		}
	}
	return nil
}
