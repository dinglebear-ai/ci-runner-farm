// Command ci-runner-capacity owns Farm's host-local admission lifecycle.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"regexp"
	"syscall"

	"github.com/unraid/ci-runner-farm/internal/capacitycmd"
	"github.com/unraid/ci-runner-farm/internal/localchecks"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--local-checks-probe" {
		if err := localchecks.WriteKernelProbe(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "local_checks_kernel_probe_failed", classicFailure(err))
			os.Exit(1)
		}
		return
	}

	if len(os.Args) > 1 && (os.Args[1] == "local-checks-readiness" || os.Args[1] == "local-checks-qualification-review") {
		var err error
		if os.Args[1] == "local-checks-readiness" {
			err = capacitycmd.WriteClassicLocalChecksReadiness(os.Args[1:], os.Stdout)
		} else {
			err = capacitycmd.ReviewClassicLocalChecksQualification(os.Args[1:], os.Stdout)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "classic_local_checks_observation_refused")
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "local-checks" {
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
		defer cancel()
		if err := capacitycmd.RunClassicLocalChecks(ctx, os.Args[1:], os.Stdin, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, classicFailure(err))
			os.Exit(1)
		}
		return
	}
	err := capacitycmd.Run(os.Args[1:], os.Stdout)
	if err == nil {
		return
	}
	fmt.Fprintln(os.Stderr, "ci-runner-capacity:", err)
	if errors.Is(err, farmcapacity.ErrQueued) {
		os.Exit(75)
	}
	if errors.Is(err, farmcapacity.ErrCredentialsExpired) {
		os.Exit(76)
	}
	os.Exit(1)
}

// Only fixed lowercase failure identifiers may cross this diagnostic boundary.
// Arguments, paths, credential values and multiline errors remain suppressed.
func classicFailure(err error) string {
	if err != nil && regexp.MustCompile(`\Alocal_checks_[a-z_]{1,100}\z`).MatchString(err.Error()) {
		return "classic_local_checks_operation_failed: " + err.Error()
	}
	return "classic_local_checks_operation_failed"
}
