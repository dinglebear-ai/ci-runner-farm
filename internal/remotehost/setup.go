package remotehost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/githubapp"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"syscall"
	"time"
)

// SetupProposal is pending configuration only. No storage path, credential,
// command, image pull, admission mutation or runner-start authority is carried.
type SetupProposal struct {
	Version          int    `json:"version"`
	OperationID      string `json:"operationID"`
	StageOperationID string `json:"stageOperationID"`
	PackageSHA256    string `json:"packageSHA256"`
	Owner            string `json:"owner"`
	Repository       string `json:"repository"`
	MemoryMiB        uint64 `json:"memoryMiB"`
	VCPUs            uint32 `json:"vcpus"`
	RunnerCount      uint32 `json:"runnerCount"`
}

var setupOwner = regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9-]{0,38}\z`)
var setupRepository = regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\z`)

func (p SetupProposal) Validate() error {
	if p.Version != 1 || !referencePattern.MatchString(p.OperationID) || !referencePattern.MatchString(p.StageOperationID) || !referenceDigest.MatchString(p.PackageSHA256) || !setupOwner.MatchString(p.Owner) || !setupRepository.MatchString(p.Repository) || p.MemoryMiB < 1024 || p.MemoryMiB > 1048576 || p.VCPUs < 1 || p.VCPUs > 256 || p.RunnerCount != 1 {
		return errors.New("remote_setup_proposal_invalid")
	}
	return nil
}
func StoreSetupProposal(root, stageRoot string, p SetupProposal) error {
	if err := p.Validate(); err != nil {
		return err
	}
	if err := inspectPrivate(root, true); err != nil {
		return err
	}
	// Only a previously staged exact native Farm artifact may seed this proposal.
	artifact := filepath.Join(stageRoot, p.StageOperationID, "ci-runner-farm.tgz")
	if err := inspectPrivate(filepath.Dir(artifact), true); err != nil {
		return err
	}
	canonical, e := filepath.EvalSymlinks(artifact)
	if e != nil || canonical != artifact {
		return errors.New("remote_setup_staged_package_invalid")
	}
	ai, e := os.Lstat(artifact)
	if e != nil {
		return errors.New("remote_setup_staged_package_invalid")
	}
	st, ok := ai.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != uint32(os.Geteuid()) || ai.Mode().Perm()&0077 != 0 {
		return errors.New("remote_setup_staged_package_invalid")
	}
	f, err := os.Open(artifact)
	if err != nil {
		return errors.New("remote_setup_staged_package_unavailable")
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxPackageBytes {
		return errors.New("remote_setup_staged_package_invalid")
	}
	raw, err := io.ReadAll(io.LimitReader(f, maxPackageBytes+1))
	if err != nil {
		return err
	}
	view, err := InspectPackage(raw)
	if err != nil || view.SHA256 != p.PackageSHA256 {
		return errors.New("remote_setup_staged_package_changed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	release, err := githubapp.AcquireCredentialLease(ctx, filepath.Join(root, "inventory"))
	if err != nil {
		return err
	}
	defer release()
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) >= 33 {
		return errors.New("remote_setup_inventory_limit")
	}
	path := filepath.Join(root, p.OperationID+".json")
	encoded, _ := json.Marshal(p)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return errors.New("remote_setup_existing_proposal_inspect")
	}
	_, w := file.Write(encoded)
	s := file.Sync()
	c := file.Close()
	if errors.Join(w, s, c) != nil {
		return errors.New("remote_setup_proposal_store_uncertain")
	}
	dir, err := os.Open(root)
	if err != nil {
		return err
	}
	s = dir.Sync()
	c = dir.Close()
	return errors.Join(s, c)
}
func ListSetupProposals(root string) ([]SetupProposal, error) {
	if err := inspectPrivate(root, true); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	release, err := githubapp.AcquireCredentialLease(ctx, filepath.Join(root, "inventory"))
	if err != nil {
		return nil, err
	}
	defer release()
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) > 33 {
		return nil, errors.New("remote_setup_inventory_unavailable")
	}
	out := []SetupProposal{}
	for _, entry := range entries {
		if entry.Name() == "inventory.lock" {
			continue
		}
		id := entry.Name()
		if len(id) != 37 || filepath.Ext(id) != ".json" || !referencePattern.MatchString(id[:32]) {
			return nil, errors.New("remote_setup_inventory_invalid")
		}
		path := filepath.Join(root, id)
		if err = inspectPrivate(path, false); err != nil {
			return nil, err
		}
		raw, e := os.ReadFile(path)
		if e != nil {
			return nil, e
		}
		var p SetupProposal
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&p) != nil || decoder.Decode(new(any)) != io.EOF || p.Validate() != nil || p.OperationID != id[:32] {
			return nil, errors.New("remote_setup_inventory_invalid")
		}
		out = append(out, p)
	}
	return out, nil
}

// ProposeSetup sends a closed pending proposal, never target configuration.
// observe=true recovers the original result with a read-only target query.
func ProposeSetup(ctx context.Context, root, actor, reference string, p SetupProposal, observe bool) (SetupProposal, error) {
	if err := p.Validate(); err != nil {
		return SetupProposal{}, err
	}
	connection, err := Load(root, actor, reference)
	if err != nil {
		return SetupProposal{}, err
	}
	directory := filepath.Join(connectionDirectory(root, actor, reference), "setup")
	if err = os.Mkdir(directory, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return SetupProposal{}, err
	}
	if err = inspectPrivate(directory, true); err != nil {
		return SetupProposal{}, err
	}
	leaseCtx, leaseCancel := context.WithTimeout(ctx, 2*time.Second)
	defer leaseCancel()
	release, err := githubapp.AcquireCredentialLease(leaseCtx, filepath.Join(connectionDirectory(root, actor, reference), ".setup-owner"))
	if err != nil {
		return SetupProposal{}, err
	}
	defer release()
	localPath := filepath.Join(directory, p.OperationID+".json")
	encoded, _ := json.Marshal(p)
	if observe {
		if inspectPrivate(localPath, false) != nil {
			return SetupProposal{}, errors.New("remote_setup_original_intent_required")
		}
		previous, e := os.ReadFile(localPath)
		if e != nil || !bytes.Equal(previous, encoded) {
			return SetupProposal{}, errors.New("remote_setup_original_intent_mismatch")
		}
	} else {
		entries, e := os.ReadDir(directory)
		if e != nil || len(entries) >= 32 {
			return SetupProposal{}, errors.New("remote_setup_intent_limit")
		}
		for _, entry := range entries {
			path := filepath.Join(directory, entry.Name())
			if inspectPrivate(path, false) != nil {
				return SetupProposal{}, errors.New("remote_setup_intent_invalid")
			}
			raw, e := os.ReadFile(path)
			if e != nil {
				return SetupProposal{}, e
			}
			var old SetupProposal
			if json.Unmarshal(raw, &old) != nil {
				return SetupProposal{}, errors.New("remote_setup_intent_invalid")
			}
			old.OperationID = p.OperationID
			if old == p {
				return SetupProposal{}, errors.New("remote_setup_existing_intent_inspect_original_operation")
			}
		}
		file, e := os.OpenFile(localPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return SetupProposal{}, errors.New("remote_setup_existing_intent_inspect")
		}
		_, w := file.Write(encoded)
		sy := file.Sync()
		cl := file.Close()
		if errors.Join(w, sy, cl) != nil {
			return SetupProposal{}, errors.New("remote_setup_intent_uncertain")
		}
		dir, e := os.Open(directory)
		if e != nil {
			return SetupProposal{}, e
		}
		sy = dir.Sync()
		cl = dir.Close()
		if errors.Join(sy, cl) != nil {
			return SetupProposal{}, errors.New("remote_setup_intent_uncertain")
		}
	}
	bounded, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	args := append([]string(nil), connection.Args...)
	args[len(args)-1] = remoteSetupCommand
	cmd := exec.CommandContext(bounded, "ssh", args...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent"}
	header, _ := json.Marshal(map[string]any{"proposal": p, "observe": observe})
	cmd.Stdin = bytes.NewReader(append(header, '\n'))
	var output, diagnostic limitedOutput
	cmd.Stdout = &output
	cmd.Stderr = &diagnostic
	if cmd.Run() != nil {
		return SetupProposal{}, errors.New("remote_setup_response_uncertain_inspect_original_operation")
	}
	var result SetupProposal
	decoder := json.NewDecoder(bytes.NewReader(output.Bytes()))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&result) != nil || decoder.Decode(new(any)) != io.EOF || result != p {
		return SetupProposal{}, errors.New("remote_setup_receipt_mismatch")
	}
	return result, nil
}

const remoteSetupCommand = `python3 -c '
import json,os,socket,sys,signal
signal.alarm(12)
m=json.loads(sys.stdin.buffer.readline(8193))
if set(m)!={"proposal","observe"} or not isinstance(m["observe"],bool) or os.geteuid()!=0:raise RuntimeError("invalid setup request")
p=m["proposal"]
r=dict(action="remote-setup-list") if m["observe"] else dict(action="remote-setup-propose",value=json.dumps(p))
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
 c.settimeout(8);c.connect("/run/unraid-core/plugin-data/ci-runner-farm/backend.sock");c.sendall((json.dumps(r)+"\n").encode());raw=b""
 while b"\n" not in raw:
  b=c.recv(4096)
  if not b:raise RuntimeError("incomplete setup response")
  raw+=b
  if len(raw)>32768:raise RuntimeError("setup response limit")
r=json.loads(raw.split(b"\n",1)[0])
if not r.get("ok"):raise RuntimeError("target setup proposal refused")
result=next((x for x in r["data"] if x.get("operationID")==p.get("operationID")),None) if m["observe"] else r["data"]
if result!=p:raise RuntimeError("pending setup proposal mismatch")
print(json.dumps(result))
'`
