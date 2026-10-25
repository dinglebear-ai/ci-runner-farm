package nativebackend

import (
	"bytes"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/internal/remotehost"
	"io"
	"os"
	"path/filepath"
)

// Incoming SSH authority can publish only a pending proposal. All configuration,
// storage and admission effects still require the target native UI's own actor.
func (s *Service) remoteSetup(r Request) Response {
	if len(r.Args) != 0 || len(r.Values) != 0 || r.Kind != "" {
		return fail("invalid_remote_setup_request")
	}
	root := filepath.Join(s.config, "pending-setup")
	if CheckDirectory(s.config, uint32(os.Geteuid())) != nil {
		return fail("remote_setup_storage_unavailable")
	}
	if err := os.Mkdir(root, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return fail("remote_setup_storage_unavailable")
	}
	if CheckDirectory(root, uint32(os.Geteuid())) != nil {
		return fail("remote_setup_storage_unavailable")
	}
	if r.Action == "remote-setup-list" {
		if r.Value != "" {
			return fail("invalid_remote_setup_request")
		}
		views, err := remotehost.ListSetupProposals(root)
		if err != nil {
			return fail("remote_setup_inventory_unavailable")
		}
		return success(views)
	}
	var p remotehost.SetupProposal
	decoder := json.NewDecoder(bytes.NewBufferString(r.Value))
	decoder.DisallowUnknownFields()
	if len(r.Value) > 8192 || decoder.Decode(&p) != nil || decoder.Decode(new(any)) != io.EOF || p.Validate() != nil {
		return fail("invalid_remote_setup_proposal")
	}
	if err := remotehost.StoreSetupProposal(root, "/var/tmp/unraid-farm-bootstrap", p); err != nil {
		return fail("remote_setup_proposal_refused_inspect_original_operation")
	}
	return success(p)
}
