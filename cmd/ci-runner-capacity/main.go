// Command ci-runner-capacity owns Farm's host-local admission lifecycle.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/unraid/ci-runner-farm/internal/capacitycmd"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "local-checks" {
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
		defer cancel()
		if capacitycmd.RunClassicLocalChecks(ctx, os.Args[1:], os.Stdin, os.Stdout) != nil {
			fmt.Fprintln(os.Stderr, "classic_local_checks_operation_failed")
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
