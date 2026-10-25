package remotehost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// ObserveStage never retransmits bytes or invokes an installer. It recovers a
// lost response only after the pinned peer proves its immutable intent and file.
func ObserveStage(ctx context.Context, root, actor, reference, operationID, digest string) (StageReceipt, error) {
	var receipt StageReceipt
	if !referencePattern.MatchString(operationID) || !referenceDigest.MatchString(digest) {
		return receipt, errors.New("remote_stage_identity_required")
	}
	connection, err := Load(root, actor, reference)
	if err != nil {
		return receipt, err
	}
	dir := filepath.Join(connectionDirectory(root, actor, reference), "staging")
	path := filepath.Join(dir, operationID+".json")
	if err = inspectPrivate(path, false); err != nil {
		return receipt, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return receipt, err
	}
	var intent StageIntent
	if json.Unmarshal(raw, &intent) != nil || intent.OperationID != operationID || intent.Reference != reference || intent.Package.SHA256 != digest {
		return receipt, errors.New("remote_stage_intent_mismatch")
	}
	bounded, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	args := append([]string(nil), connection.Args...)
	args[len(args)-1] = remoteObserveCommand
	cmd := exec.CommandContext(bounded, "ssh", args...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent"}
	header, _ := json.Marshal(map[string]any{"protocol": "farm-native-package-stage/v1", "operationID": operationID, "sha256": digest, "bytes": intent.Package.Bytes})
	cmd.Stdin = bytes.NewReader(append(header, '\n'))
	var output, diagnostic limitedOutput
	cmd.Stdout = &output
	cmd.Stderr = &diagnostic
	if cmd.Run() != nil {
		return receipt, errors.New("remote_stage_observation_unavailable_no_retry")
	}
	decoder := json.NewDecoder(bytes.NewReader(output.Bytes()))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&receipt) != nil || decoder.Decode(new(any)) != io.EOF || receipt.Protocol != "farm-native-package-stage/v1" || receipt.OperationID != operationID || receipt.SHA256 != digest || receipt.Bytes != intent.Package.Bytes || receipt.TargetPath != filepath.Join(remoteBootstrapRoot, operationID, "ci-runner-farm.tgz") || !referenceDigest.MatchString(receipt.HostIdentitySHA256) || receipt.State != "staged_waiting_native_approval" {
		return receipt, errors.New("remote_stage_observation_mismatch")
	}
	encoded, _ := json.Marshal(receipt)
	resultPath := filepath.Join(dir, operationID+".receipt")
	f, err := os.OpenFile(resultPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if errors.Is(err, os.ErrExist) {
		existing, e := os.ReadFile(resultPath)
		if e != nil || !bytes.Equal(existing, encoded) {
			return receipt, errors.New("remote_stage_existing_receipt_mismatch")
		}
		return receipt, nil
	}
	if err != nil {
		return receipt, err
	}
	_, w := f.Write(encoded)
	s := f.Sync()
	c := f.Close()
	return receipt, errors.Join(w, s, c)
}

const remoteObserveCommand = `python3 -c '
import hashlib,json,os,pathlib,re,signal,stat,sys
signal.alarm(10)
m=json.loads(sys.stdin.buffer.readline(4096))
if set(m)!={"protocol","operationID","sha256","bytes"} or m["protocol"]!="farm-native-package-stage/v1" or not re.fullmatch("[a-f0-9]{32}",m["operationID"]) or not re.fullmatch("[a-f0-9]{64}",m["sha256"]) or not isinstance(m["bytes"],int) or not 0<m["bytes"]<=8388608:raise RuntimeError("invalid observation metadata")
if os.geteuid()!=0:raise RuntimeError("target root authorization required")
root=pathlib.Path("/var/tmp/unraid-farm-bootstrap")
task=root/m["operationID"]
for p in (root,task):
 s=p.lstat()
 if not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or s.st_mode & 0o077:raise RuntimeError("unsafe staging directory")
def private(p):
 s=p.lstat()
 if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_mode & 0o077:raise RuntimeError("unsafe staging file")
 return s
intent=task/"stage-intent.json"
if private(intent).st_size>4096:raise RuntimeError("intent too large")
i=json.loads(intent.read_text())
if any(i.get(k)!=v for k,v in m.items()) or i.get("state")!="before_receive":raise RuntimeError("intent mismatch")
final=task/"ci-runner-farm.tgz"
if private(final).st_size!=m["bytes"]:raise RuntimeError("staged bytes incomplete")
h=hashlib.sha256()
with final.open("rb") as f:
 while True:
  b=f.read(65536)
  if not b:break
  h.update(b)
if h.hexdigest()!=m["sha256"]:raise RuntimeError("staged hash mismatch")
identity=hashlib.sha256(pathlib.Path("/etc/machine-id").read_bytes().strip()).hexdigest()
r=dict(m,targetPath=str(final),hostIdentitySHA256=identity,state="staged_waiting_native_approval")
print(json.dumps(r))
'`
