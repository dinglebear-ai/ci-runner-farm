package localchecks

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestNativeCommandHandshakeIsClosedAndDoesNotAcceptCallerPathsOrSecrets(t *testing.T) {
	command := `{"protocol":"farm-local-checks-worker/v1","action":"complete","epoch":"0123456789abcdef0123456789abcdef","requestID":"job-001"}`
	if _, err := DecodeNativeCommand(strings.NewReader(command)); err != nil {
		t.Fatal(err)
	}
	for _, addition := range []string{`,"command":"arbitrary"`, `,"token":"credential"`, `,"configPath":"/other-owner"`} {
		raw := strings.TrimSuffix(command, "}") + addition + "}"
		if _, err := DecodeNativeCommand(strings.NewReader(raw)); err == nil {
			t.Fatal("accepted caller authority override")
		}
	}
	if _, err := DecodeNativeCommand(strings.NewReader(strings.Replace(command, "farm-local-checks-worker/v1", "other/v1", 1))); err == nil {
		t.Fatal("accepted incompatible protocol")
	}
	contract := NativeWorkerContract()
	if contract.Role != "local-checks" || !contract.RequiresInheritedFleetLock || contract.QueueOwner != "existing-coordinator" {
		t.Fatal(contract)
	}
}

func TestNativeCreateHandshakeCannotAdoptCallerContainer(t *testing.T) {
	s := submission()
	raw, _ := json.Marshal(NativeCommand{Protocol: NativeProtocol, Action: "create-admit", Epoch: "0123456789abcdef0123456789abcdef", Submission: &s})
	if _, err := DecodeNativeCommand(bytes.NewReader(raw)); err != nil {
		t.Fatal(err)
	}
	command := NativeCommand{Protocol: NativeProtocol, Action: "create-admit", Epoch: "0123456789abcdef0123456789abcdef", Submission: &s, ContainerID: strings.Repeat("d", 64)}
	raw, _ = json.Marshal(command)
	if _, err := DecodeNativeCommand(bytes.NewReader(raw)); err == nil {
		t.Fatal("caller container adopted")
	}
}

func TestNativeExecuteCommandRequiresOnlyExistingRequestIdentity(t *testing.T) {
	raw := `{"protocol":"farm-local-checks-worker/v1","action":"execute","epoch":"0123456789abcdef0123456789abcdef","requestID":"job-001"}`
	if _, err := DecodeNativeCommand(strings.NewReader(raw)); err != nil {
		t.Fatal(err)
	}
	raw = strings.TrimSuffix(raw, "}") + `,"containerID":"` + strings.Repeat("d", 64) + `"}`
	if _, err := DecodeNativeCommand(strings.NewReader(raw)); err == nil {
		t.Fatal("execution accepted caller container")
	}
}
