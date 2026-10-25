package nativebackend

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/internal/remotehost"
	"io"
	"os"
	"path/filepath"
)

func (s *Service) remoteHosts(r Request) Response {
	if len(r.Args) != 0 || r.Kind != "" || len(r.Values) < 1 || len(r.Values) > 3 || r.Values["actor"] == "" {
		return fail("remote_host_authenticated_actor_required")
	}
	for key := range r.Values {
		if key != "actor" && !((r.Action == "remote-package-stage" || r.Action == "remote-package-observe") && (key == "sha256" || (r.Action == "remote-package-observe" && key == "operationID"))) {
			return fail("invalid_remote_host_request")
		}
	}
	actor := r.Values["actor"]
	root := filepath.Join(s.config, "remote-hosts")
	if err := CheckDirectory(s.config, uint32(os.Geteuid())); err != nil {
		return fail("remote_host_storage_unavailable")
	}
	if err := os.Mkdir(root, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return fail("remote_host_storage_unavailable")
	}
	if err := CheckDirectory(root, uint32(os.Geteuid())); err != nil {
		return fail("remote_host_storage_unavailable")
	}
	switch r.Action {
	case "remote-package-upload", "remote-package-list":
		engine, ok := s.engine.(*Engine)
		if !ok || engine.BoundCache == "" || len(r.Value) > 11184812 {
			return fail("remote_package_storage_unavailable")
		}
		packages := filepath.Join(engine.BoundCache, "native-remote-packages")
		if CheckDirectory(engine.BoundCache, uint32(os.Geteuid())) != nil {
			return fail("remote_package_storage_unavailable")
		}
		if err := os.Mkdir(packages, 0700); err != nil && !errors.Is(err, os.ErrExist) {
			return fail("remote_package_storage_unavailable")
		}
		if CheckDirectory(packages, uint32(os.Geteuid())) != nil {
			return fail("remote_package_storage_unavailable")
		}
		if r.Action == "remote-package-list" {
			if r.Value != "" {
				return fail("invalid_remote_package_request")
			}
			views, err := remotehost.ListPackages(packages, actor)
			if err != nil {
				return fail("remote_package_inventory_unavailable")
			}
			return success(views)
		}
		return s.launch(r, func(context.Context) (string, error) {
			raw, err := base64.StdEncoding.Strict().DecodeString(r.Value)
			if err != nil {
				return "", errors.New("remote_package_encoding_invalid")
			}
			view, err := remotehost.StorePackage(packages, actor, raw)
			if err != nil {
				return "", err
			}
			encoded, err := json.Marshal(view)
			return string(encoded), err
		})
	case "remote-package-stage", "remote-package-observe":
		engine, ok := s.engine.(*Engine)
		if !ok || engine.BoundCache == "" {
			return fail("remote_package_storage_unavailable")
		}
		return s.launch(r, func(ctx context.Context) (string, error) {
			var receipt remotehost.StageReceipt
			var err error
			if r.Action == "remote-package-observe" {
				receipt, err = remotehost.ObserveStage(ctx, root, actor, r.Value, r.Values["operationID"], r.Values["sha256"])
			} else {
				s.mu.Lock()
				operationID := s.active.ID
				s.mu.Unlock()
				receipt, err = remotehost.StagePackage(ctx, root, filepath.Join(engine.BoundCache, "native-remote-packages"), actor, r.Value, r.Values["sha256"], operationID)
			}
			if err != nil {
				return "", err
			}
			encoded, err := json.Marshal(receipt)
			return string(encoded), err
		})

	case "remote-host-list":
		if r.Value != "" {
			return fail("invalid_remote_host_request")
		}
		views, err := remotehost.List(root, actor)
		if err != nil {
			return fail("remote_host_inventory_unavailable")
		}
		return success(views)
	case "remote-host-create":
		var endpoint remotehost.Endpoint
		decoder := json.NewDecoder(bytes.NewBufferString(r.Value))
		decoder.DisallowUnknownFields()
		if len(r.Value) > 8192 || decoder.Decode(&endpoint) != nil || decoder.Decode(new(any)) != io.EOF {
			return fail("invalid_remote_host_endpoint")
		}
		return s.launch(r, func(context.Context) (string, error) {
			view, err := remotehost.Create(root, actor, endpoint)
			if err != nil {
				return "", errors.New("remote_host_connection_create_failed")
			}
			raw, err := json.Marshal(view)
			return string(raw), err
		})
	case "remote-host-status":
		return s.launch(r, func(ctx context.Context) (string, error) {
			raw, err := remotehost.Status(ctx, root, actor, r.Value)
			return string(raw), err
		})
	default:
		return fail("unsupported_remote_host_operation")
	}
}
