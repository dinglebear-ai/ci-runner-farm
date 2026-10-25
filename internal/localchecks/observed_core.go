package localchecks

import (
	_ "embed"
	"strings"
)

// observedCurrentCore is an external observer for the existing merged Core
// wrapper. It is distinct from Core's source-authored V1 receipt protocol.
//
//go:embed observed_core.py
var observedCurrentCore string

func observedCurrentCoreShell() string {
	// Only static authored program text is quoted here. Credentials remain stdin.
	return "exec python3 -c '" + shellSingleQuote(observedCurrentCore) + "' \"$@\" \"$FARM_CHECKS_CPUS\" \"$FARM_CHECKS_MEMORY_BYTES\" \"$FARM_CHECKS_TIMEOUT\""
}

func shellSingleQuote(value string) string { return strings.ReplaceAll(value, "'", "'\"'\"'") }
