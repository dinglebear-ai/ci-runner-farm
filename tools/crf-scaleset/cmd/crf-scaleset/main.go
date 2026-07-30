package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/actions/scaleset"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/ipc"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/probe"
	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

const (
	moduleVersion  = "v0.4.0"
	moduleRevision = "6ce025902cd964747a078c2aabe7340ebc667eca"
)

func main() {
	if len(os.Args) < 2 {
		fail("usage", "expected version, validate-frame, probe, or supervise")
	}
	switch os.Args[1] {
	case "version":
		write(map[string]any{"ok": true, "go_version": runtime.Version(), "module_version": moduleVersion, "module_revision": moduleRevision})
	case "validate-frame":
		req, err := protocol.Decode(os.Stdin)
		if err != nil {
			fail("invalid_frame", err.Error())
		}
		write(protocol.Response{SchemaVersion: 1, RequestID: req.RequestID, OK: true})
	case "probe":
		// Live compatibility requires disposable repo/group credentials and a
		// remotely proven eligibility barrier. Never synthesize green evidence.
		fail("live_probe_not_configured", "provide the tootie probe operation with restricted runner-group and disposable-repository inputs")
	case "supervise":
		supervise(os.Args[2:])
	default:
		fail("unknown_command", os.Args[1])
	}
}

func supervise(args []string) {
	flags := flag.NewFlagSet("supervise", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	socket := flags.String("socket", "", "root-only Unix socket")
	compatibility := flags.String("compatibility", "", "sealed compatibility record")
	if err := flags.Parse(args); err != nil || *socket == "" || *compatibility == "" || flags.NArg() != 0 {
		fail("invalid_arguments", "supervise requires --socket and --compatibility")
	}
	record, err := probe.LoadFresh(*compatibility, time.Now().UTC(), 30*24*time.Hour)
	if err != nil {
		fail("invalid_compatibility_record", err.Error())
	}
	if record.ModuleRevision != moduleRevision || record.GoVersion != runtime.Version() {
		fail("helper_identity_mismatch", "module or Go runtime does not match compatibility evidence")
	}
	digest, err := executableDigest()
	if err != nil || digest != record.HelperDigest {
		fail("helper_digest_mismatch", "running helper does not match compatibility evidence")
	}
	controllerID := "crf-" + record.CompatibilityRecordID[:24]
	handler := func(_ context.Context, request protocol.Request) protocol.Response {
		response := protocol.Response{SchemaVersion: protocol.SchemaVersion, RequestID: request.RequestID}
		if request.ConfigRevision != record.PluginDigest ||
			request.OwnershipRevision != record.CompatibilityRecordID ||
			request.ControllerInstanceID != controllerID {
			response.Code = "identity_mismatch"
			return response
		}
		switch request.Operation {
		case "read_snapshot":
			now := time.Now().UTC()
			response.OK = true
			response.Result = protocol.Snapshot{
				SchemaVersion: protocol.SchemaVersion, ControllerInstanceID: controllerID,
				ConfigRevision: record.PluginDigest, OwnershipRevision: record.CompatibilityRecordID,
				Sequence: request.Sequence, ObservedAt: now, ValidUntil: now.Add(20 * time.Second),
				Pools: []protocol.PoolSnapshot{},
			}
		default:
			response.Code = "sessions_not_applied"
			response.Error = "apply_sessions must configure pools before this operation is available"
		}
		return response
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := (&ipc.Server{Path: *socket, Handler: handler}).Serve(ctx); err != nil {
		fail("supervisor_failed", err.Error())
	}
}

func executableDigest() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", err
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	sum := sha256.New()
	if _, err := io.Copy(sum, file); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", sum.Sum(nil)), nil
}

func write(v any) {
	if err := json.NewEncoder(os.Stdout).Encode(v); err != nil {
		os.Exit(1)
	}
}
func fail(code, message string) {
	write(map[string]any{"ok": false, "code": code, "error": message})
	os.Exit(2)
}

var _ = scaleset.HeaderScaleSetMaxCapacity
