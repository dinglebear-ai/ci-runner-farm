package main

import (
	"encoding/json"
	"os"
	"runtime"

	"github.com/actions/scaleset"
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
		fail("supervisor_not_configured", "supervisor requires an applied, fresh compatibility record")
	default:
		fail("unknown_command", os.Args[1])
	}
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
