package capacitycmd

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestClassicLocalChecksDelegatesOnlyFixedBindingAndProtectedInput(t *testing.T) {
	input := strings.NewReader("protected envelope")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	marker := errors.New("delegate result")
	called := false
	err := runClassicLocalChecks(ctx, []string{"local-checks"}, input, io.Discard, func(got context.Context, path string, in io.Reader, out io.Writer) error {
		called = true
		if path != "/boot/config/plugins/ci-runner-farm/native-local-checks.json" || in != input || out != io.Discard || got.Err() != context.Canceled {
			t.Fatal("classic transport changed protected owner/input/context")
		}
		return marker
	})
	if !called || !errors.Is(err, marker) {
		t.Fatalf("delegation %v %v", called, err)
	}
}
func TestClassicLocalChecksRejectsCallerPathAndExtraArguments(t *testing.T) {
	for _, args := range [][]string{{}, {"other"}, {"local-checks", "/caller/path"}, {"local-checks", "--skip-qualification"}} {
		called := false
		err := runClassicLocalChecks(context.Background(), args, strings.NewReader("secret"), io.Discard, func(context.Context, string, io.Reader, io.Writer) error { called = true; return nil })
		if err == nil || called {
			t.Fatalf("accepted caller controls: %q", args)
		}
	}
}
