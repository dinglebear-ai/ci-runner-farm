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
	"strings"
	"time"
)

const remoteBootstrapRoot = "/var/tmp/unraid-farm-bootstrap"

type StageReceipt struct {
	Protocol           string `json:"protocol"`
	OperationID        string `json:"operationID"`
	SHA256             string `json:"sha256"`
	Bytes              int64  `json:"bytes"`
	TargetPath         string `json:"targetPath"`
	HostIdentitySHA256 string `json:"hostIdentitySHA256"`
	State              string `json:"state"`
}
type StageIntent struct {
	OperationID string      `json:"operationID"`
	Reference   string      `json:"reference"`
	Package     PackageView `json:"package"`
	State       string      `json:"state"`
}

// StagePackage is a one-run file transfer under the native daemon's existing
// operation ID. It never installs, starts or approves a plugin on the target.
func StagePackage(ctx context.Context, connectionsRoot, packagesRoot, actor, reference, digest, operationID string) (StageReceipt, error) {
	var receipt StageReceipt
	if !referencePattern.MatchString(operationID) {
		return receipt, errors.New("remote_stage_operation_required")
	}
	connection, err := Load(connectionsRoot, actor, reference)
	if err != nil {
		return receipt, err
	}
	artifact, view, err := LoadPackage(packagesRoot, actor, digest)
	if err != nil {
		return receipt, err
	}
	leaseCtx, leaseCancel := context.WithTimeout(ctx, 2*time.Second)
	defer leaseCancel()
	release, err := githubapp.AcquireCredentialLease(leaseCtx, filepath.Join(connectionDirectory(connectionsRoot, actor, reference), ".staging-owner"))
	if err != nil {
		return receipt, err
	}
	defer release()
	operations := filepath.Join(connectionDirectory(connectionsRoot, actor, reference), "staging")
	if err = os.Mkdir(operations, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return receipt, err
	}
	if err = inspectPrivate(operations, true); err != nil {
		return receipt, err
	}
	entries, err := os.ReadDir(operations)
	if err != nil || len(entries) >= 128 {
		return receipt, errors.New("remote_stage_inventory_unavailable")
	}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) == ".receipt" && referencePattern.MatchString(strings.TrimSuffix(entry.Name(), ".receipt")) {
			continue
		}
		if filepath.Ext(entry.Name()) != ".json" {
			return receipt, errors.New("remote_stage_inventory_invalid")
		}
		intentPath := filepath.Join(operations, entry.Name())
		if e := inspectPrivate(intentPath, false); e != nil {
			return receipt, e
		}
		raw, e := os.ReadFile(intentPath)
		if e != nil {
			return receipt, e
		}
		var previous StageIntent
		if json.Unmarshal(raw, &previous) != nil {
			return receipt, errors.New("remote_stage_existing_intent_unreadable")
		}
		if previous.Package.SHA256 == digest {
			return receipt, errors.New("remote_stage_existing_intent_inspect_before_retry")
		}
	}
	intent := StageIntent{OperationID: operationID, Reference: reference, Package: view, State: "before_transfer"}
	journal := filepath.Join(operations, operationID+".json")
	raw, _ := json.MarshalIndent(intent, "", "  ")
	f, err := os.OpenFile(journal, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return receipt, errors.New("remote_stage_existing_operation_inspect")
	}
	_, writeErr := f.Write(raw)
	syncErr := f.Sync()
	closeErr := f.Close()
	if errors.Join(writeErr, syncErr, closeErr) != nil {
		return receipt, errors.New("remote_stage_intent_uncertain")
	}
	directory, err := os.Open(operations)
	if err != nil {
		return receipt, err
	}
	syncErr = directory.Sync()
	closeErr = directory.Close()
	if errors.Join(syncErr, closeErr) != nil {
		return receipt, errors.New("remote_stage_intent_uncertain")
	}
	file, err := os.Open(artifact)
	if err != nil {
		return receipt, errors.New("remote_stage_source_unavailable")
	}
	defer file.Close()
	bounded, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	args := append([]string(nil), connection.Args...)
	args[len(args)-1] = remoteStageCommand
	cmd := exec.CommandContext(bounded, "ssh", args...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent"}
	header, _ := json.Marshal(map[string]any{"protocol": "farm-native-package-stage/v1", "operationID": operationID, "sha256": digest, "bytes": view.Bytes})
	cmd.Stdin = io.MultiReader(bytes.NewReader(append(header, '\n')), io.LimitReader(file, maxPackageBytes+1))
	var output, diagnostic limitedOutput
	cmd.Stdout = &output
	cmd.Stderr = &diagnostic
	if err = cmd.Run(); err != nil {
		return receipt, errors.New("remote_stage_uncertain_inspect_existing_operation")
	}
	decoder := json.NewDecoder(bytes.NewReader(output.Bytes()))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&receipt) != nil || decoder.Decode(new(any)) != io.EOF || receipt.Protocol != "farm-native-package-stage/v1" || receipt.OperationID != operationID || receipt.SHA256 != digest || receipt.Bytes != view.Bytes || receipt.TargetPath != filepath.Join(remoteBootstrapRoot, operationID, "ci-runner-farm.tgz") || !referenceDigest.MatchString(receipt.HostIdentitySHA256) || receipt.State != "staged_waiting_native_approval" {
		return receipt, errors.New("remote_stage_receipt_uncertain")
	}
	// Preserve the immutable before-transfer intent; terminal result is separate.
	result, err := os.OpenFile(filepath.Join(operations, operationID+".receipt"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return receipt, errors.New("remote_stage_receipt_store_uncertain")
	}
	encoded, _ := json.Marshal(receipt)
	_, writeErr = result.Write(encoded)
	syncErr = result.Sync()
	closeErr = result.Close()
	if errors.Join(writeErr, syncErr, closeErr) != nil {
		return receipt, errors.New("remote_stage_receipt_store_uncertain")
	}
	return receipt, nil
}

// Fixed target program accepts only bounded identity metadata + exact package
// bytes on stdin. It creates an exclusive task directory and leaves installer
// authority with the target's native Plugins preview/approval workflow.
const remoteStageCommand = `python3 -c '
import hashlib,json,os,pathlib,re,signal,stat,sys
signal.signal(signal.SIGALRM,lambda *_: (_ for _ in ()).throw(TimeoutError("bounded staging deadline")))
signal.alarm(25)
m=json.loads(sys.stdin.buffer.readline(4096))
if set(m)!={"protocol","operationID","sha256","bytes"} or m["protocol"]!="farm-native-package-stage/v1" or not re.fullmatch("[a-f0-9]{32}",m["operationID"]) or not re.fullmatch("[a-f0-9]{64}",m["sha256"]) or not isinstance(m["bytes"],int) or not 0<m["bytes"]<=8388608:raise RuntimeError("invalid stage metadata")
if os.geteuid()!=0:raise RuntimeError("target root authorization required")
v=pathlib.Path("/etc/unraid-version").read_text()
if not re.search("version=.?8[.]",v):raise RuntimeError("target Unraid 8 required")
root=pathlib.Path("/var/tmp/unraid-farm-bootstrap")
root.mkdir(mode=0o700,exist_ok=True)
s=root.lstat()
if not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or s.st_mode & 0o077:raise RuntimeError("unsafe target staging root")
task=root/m["operationID"]
task.mkdir(mode=0o700)
journal=task/"stage-intent.json"
with journal.open("x") as f:
 os.fchmod(f.fileno(),0o600);json.dump(dict(m,state="before_receive",pid=os.getpid()),f);f.flush();os.fsync(f.fileno())
fd=os.open(task,os.O_RDONLY|os.O_DIRECTORY);os.fsync(fd);os.close(fd)
fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY);os.fsync(fd);os.close(fd)
temporary=task/"package.receiving"
h=hashlib.sha256();remaining=m["bytes"]
with temporary.open("xb") as f:
 os.fchmod(f.fileno(),0o600)
 while remaining:
  block=sys.stdin.buffer.read(min(65536,remaining))
  if not block:raise RuntimeError("incomplete package stream")
  f.write(block);h.update(block);remaining-=len(block)
 if sys.stdin.buffer.read(1):raise RuntimeError("excess package bytes")
 f.flush();os.fsync(f.fileno())
if h.hexdigest()!=m["sha256"]:raise RuntimeError("package hash mismatch")
final=task/"ci-runner-farm.tgz"
os.rename(temporary,final)
identity=hashlib.sha256(pathlib.Path("/etc/machine-id").read_bytes().strip()).hexdigest()
r=dict(protocol=m["protocol"],operationID=m["operationID"],sha256=m["sha256"],bytes=m["bytes"],targetPath=str(final),hostIdentitySHA256=identity,state="staged_waiting_native_approval")
with (task/"stage-receipt.json").open("x") as f:
 os.fchmod(f.fileno(),0o600);json.dump(r,f);f.flush();os.fsync(f.fileno())
fd=os.open(task,os.O_RDONLY|os.O_DIRECTORY);os.fsync(fd);os.close(fd)
print(json.dumps(r))
'`
