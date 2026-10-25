package localchecks

import (
	"strings"
	"testing"
)

func TestNativeEnvelopeSeparatesBoundedDependencyCredentialFromCommand(t *testing.T) {
	command := `{"protocol":"farm-local-checks-worker/v1","action":"execute","epoch":"0123456789abcdef0123456789abcdef","requestID":"job-001"}`
	got, secret, err := DecodeNativeEnvelope(strings.NewReader(command + "\nfixture-private-dependency"))
	if err != nil || got.RequestID != "job-001" || secret != "fixture-private-dependency" {
		t.Fatal("private envelope rejected", err)
	}
	for _, tail := range []string{"", "line-one\nline-two", strings.Repeat("x", 4097)} {
		if _, _, err := DecodeNativeEnvelope(strings.NewReader(command + "\n" + tail)); err == nil {
			t.Fatal("unbounded/missing credential accepted")
		}
	}
	if _, _, err := DecodeNativeEnvelope(strings.NewReader(strings.Replace(command, "execute", "complete", 1) + "\nfixture-private-dependency")); err == nil {
		t.Fatal("credential accepted outside execution")
	}
}
