package capacitycmd

import (
	"context"
	"errors"
	"io"

	"github.com/unraid/ci-runner-farm/internal/localchecks"
)

// ClassicLocalChecksBinding is owned by the existing classic Farm installation.
// Callers cannot select a policy, ledger, worker path or alternate binding.
const ClassicLocalChecksBinding = "/boot/config/plugins/ci-runner-farm/native-local-checks.json"

// RunClassicLocalChecks reuses the protected Farm role owner and inherited FD8.
// The classic shell owns flock acquisition; RunProtected verifies it again.
// Cancellation belongs to this process's signal context, not a second queue.
func RunClassicLocalChecks(ctx context.Context, arguments []string, input io.Reader, output io.Writer) error {
	return runClassicLocalChecks(ctx, arguments, input, output, localchecks.RunProtected)
}
func runClassicLocalChecks(ctx context.Context, arguments []string, input io.Reader, output io.Writer, run func(context.Context, string, io.Reader, io.Writer) error) error {
	if len(arguments) != 1 || arguments[0] != "local-checks" {
		return errors.New("classic_local_checks_closed_command_required")
	}
	return run(ctx, ClassicLocalChecksBinding, input, output)
}
