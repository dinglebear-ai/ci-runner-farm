package localchecks

import (
	"bytes"
	"errors"
	"io"
	"strings"
)

// DecodeNativeEnvelope accepts a compact command JSON line followed by an
// optional raw credential on stdin. Only execute accepts that credential; it is
// never part of the persisted command/manifest/receipt or process arguments.
func DecodeNativeEnvelope(input io.Reader) (NativeCommand, string, error) {
	var command NativeCommand
	data, err := io.ReadAll(io.LimitReader(input, 16384+1+4096+1))
	if err != nil || len(data) > 16384+1+4096 {
		return command, "", errors.New("local_checks_native_envelope_invalid")
	}
	parts := bytes.SplitN(data, []byte{'\n'}, 2)
	command, err = DecodeNativeCommand(bytes.NewReader(parts[0]))
	if err != nil {
		return command, "", err
	}
	secret := ""
	if len(parts) == 2 {
		secret = string(parts[1])
	}
	if command.Action == "execute" {
		if len(secret) < 8 || len(secret) > 4096 || strings.ContainsAny(secret, "\x00\r\n") {
			return command, "", errors.New("local_checks_dependency_credential_required")
		}
	} else if secret != "" {
		return command, "", errors.New("local_checks_native_envelope_invalid")
	}
	return command, secret, nil
}
