package localchecks

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestObservedCurrentCoreComposedRuntimeContracts(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "python3", "observed_core_test.py")
	cmd.Env = append(os.Environ(), "PYTHONDONTWRITEBYTECODE=1")
	output, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(output), "OK") {
		t.Fatalf("observed Core contract fixtures failed: %s %v", output, err)
	}
}
