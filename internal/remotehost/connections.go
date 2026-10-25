// Package remotehost owns private, actor-scoped native host connection material.
// Farm policy and installation effects stay with the target native owners.
// Protected storage and SSH pinning follow qa-lab commit 5a602960; provider MCP is not reused.
package remotehost

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/githubapp"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"

	"bytes"
	"io"
	"os/exec"
)

var (
	referencePattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
	hostPattern      = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9.:-]*$`)
	userPattern      = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$`)
)

// Endpoint contains public connection details and an explicitly verified host pin.
// Private keys and arbitrary command/config paths are never accepted as inputs.
type Endpoint struct {
	Host                 string `json:"host"`
	CoreURL              string `json:"coreURL,omitempty"`
	User                 string `json:"user"`
	Port                 int    `json:"port"`
	HostPublicKey        string `json:"hostPublicKey"`
	ConfirmedFingerprint string `json:"confirmedFingerprint"`
}

// View is the only projection returned to the native browser-facing caller.
type View struct {
	Reference       string `json:"reference"`
	CoreURL         string `json:"coreURL,omitempty"`
	Host            string `json:"host"`
	User            string `json:"user"`
	Port            int    `json:"port"`
	PublicKey       string `json:"publicKey"`
	HostFingerprint string `json:"hostFingerprint"`
}

func validateEndpoint(endpoint *Endpoint) (ssh.PublicKey, error) {
	if !hostPattern.MatchString(endpoint.Host) || !userPattern.MatchString(endpoint.User) || endpoint.Port < 1 || endpoint.Port > 65535 {
		return nil, errors.New("invalid remote host endpoint")
	}
	if endpoint.CoreURL != "" {
		u, err := url.Parse(endpoint.CoreURL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || !strings.EqualFold(u.Hostname(), endpoint.Host) || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
			return nil, errors.New("Core URL must name this explicit target without credentials or path")
		}
	}
	key, _, options, rest, err := ssh.ParseAuthorizedKey([]byte(endpoint.HostPublicKey))
	if err != nil || len(options) != 0 || strings.TrimSpace(string(rest)) != "" {
		return nil, errors.New("invalid pinned host public key")
	}
	if endpoint.ConfirmedFingerprint != ssh.FingerprintSHA256(key) {
		return nil, errors.New("host fingerprint must be explicitly verified")
	}
	return key, nil
}

func actorDirectory(root, actor string) string {
	hash := sha256.Sum256([]byte(actor))
	return filepath.Join(root, hex.EncodeToString(hash[:]))
}

func connectionDirectory(root, actor, reference string) string {
	return filepath.Join(actorDirectory(root, actor), reference)
}

func validateActor(root, actor string) error {
	if !filepath.IsAbs(root) || strings.TrimSpace(actor) == "" || len(actor) > 512 {
		return errors.New("authenticated actor and private absolute root are required")
	}
	return nil
}

func inspectPrivate(path string, directory bool) error {
	info, err := os.Lstat(path)
	if err != nil {
		return errors.New("private connection material unavailable")
	}
	if info.Mode()&os.ModeSymlink != 0 || info.IsDir() != directory || (!directory && (!info.Mode().IsRegular() || info.Size() > 65536)) || info.Mode().Perm()&0o077 != 0 {
		return errors.New("private connection material has unsafe type or permissions")
	}
	return nil
}

// Create generates a dedicated key locally; it does not connect to or mutate a target.
// actor must come from the authenticated native Core session, never form parameters.
func Create(root, actor string, endpoint Endpoint) (View, error) {
	if err := validateActor(root, actor); err != nil {
		return View{}, err
	}
	hostKey, err := validateEndpoint(&endpoint)
	if err != nil {
		return View{}, err
	}
	if inspectErr := inspectPrivate(root, true); inspectErr != nil {
		return View{}, inspectErr
	}
	release, err := connectionInventoryLease(root, actor)
	if err != nil {
		return View{}, err
	}
	defer release()
	actorRoot := actorDirectory(root, actor)
	if err = os.Mkdir(actorRoot, 0o700); err != nil && !os.IsExist(err) {
		return View{}, err
	}
	if inspectErr := inspectPrivate(actorRoot, true); inspectErr != nil {
		return View{}, inspectErr
	}
	entries, listErr := os.ReadDir(actorRoot)
	if listErr != nil || len(entries) >= 128 {
		return View{}, errors.New("connection inventory exceeds supported limit")
	}
	random := make([]byte, 16)
	if _, err = rand.Read(random); err != nil {
		return View{}, err
	}
	reference := hex.EncodeToString(random)
	dir := connectionDirectory(root, actor, reference)
	if createErr := os.Mkdir(dir, 0o700); createErr != nil {
		return View{}, createErr
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(dir)
		}
	}()
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return View{}, err
	}
	block, err := ssh.MarshalPrivateKey(private, "")
	if err != nil {
		return View{}, err
	}
	public, err := ssh.NewPublicKey(pub)
	if err != nil {
		return View{}, err
	}
	encoded, err := json.Marshal(endpoint)
	if err != nil {
		return View{}, err
	}
	address := knownhosts.Normalize(net.JoinHostPort(endpoint.Host, strconv.Itoa(endpoint.Port)))
	files := map[string][]byte{"identity": pem.EncodeToMemory(block), "connection.json": encoded, "known_hosts": []byte(knownhosts.Line([]string{address}, hostKey) + "\n")}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), body, 0o600); err != nil {
			return View{}, err
		}
	}
	complete = true
	return View{CoreURL: endpoint.CoreURL, Reference: reference, Host: endpoint.Host, User: endpoint.User, Port: endpoint.Port, PublicKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(public))), HostFingerprint: ssh.FingerprintSHA256(hostKey)}, nil
}

// Load resolves an opaque reference exclusively inside its authenticated actor's directory.
func Load(root, actor, reference string) (Connection, error) {
	if err := validateActor(root, actor); err != nil {
		return Connection{}, err
	}
	if !referencePattern.MatchString(reference) {
		return Connection{}, errors.New("invalid connection reference")
	}
	dir := connectionDirectory(root, actor, reference)
	for _, path := range []string{root, actorDirectory(root, actor), dir} {
		if err := inspectPrivate(path, true); err != nil {
			return Connection{}, err
		}
	}
	for _, name := range []string{"identity", "connection.json", "known_hosts"} {
		if err := inspectPrivate(filepath.Join(dir, name), false); err != nil {
			return Connection{}, err
		}
	}
	body, err := os.ReadFile(filepath.Join(dir, "connection.json"))
	if err != nil {
		return Connection{}, errors.New("connection configuration unavailable")
	}
	var endpoint Endpoint
	if json.Unmarshal(body, &endpoint) != nil {
		return Connection{}, errors.New("connection configuration invalid")
	}
	hostKey, validateErr := validateEndpoint(&endpoint)
	if validateErr != nil {
		return Connection{}, validateErr
	}
	pins, readErr := os.ReadFile(filepath.Join(dir, "known_hosts"))
	expected := knownhosts.Line([]string{knownhosts.Normalize(net.JoinHostPort(endpoint.Host, strconv.Itoa(endpoint.Port)))}, hostKey) + "\n"
	if readErr != nil || string(pins) != expected {
		return Connection{}, errors.New("stored host pin does not match reviewed endpoint")
	}

	args := []string{"-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "PreferredAuthentications=publickey", "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UserKnownHostsFile=" + filepath.Join(dir, "known_hosts"), "-i", filepath.Join(dir, "identity"), "-p", strconv.Itoa(endpoint.Port), endpoint.User + "@" + endpoint.Host, remoteProbeCommand}
	connection := Connection{Host: endpoint.Host, User: endpoint.User, Port: endpoint.Port, Command: "ssh", Args: args}

	return connection, nil
}

// Status performs one bounded fixed read; it never installs or changes a target.
func Status(ctx context.Context, root, actor, reference string) (json.RawMessage, error) {
	return statusForSetup(ctx, root, actor, reference, "")
}

func StatusForSetup(ctx context.Context, root, actor, reference, proposalID string) (json.RawMessage, error) {
	if !referencePattern.MatchString(proposalID) {
		return nil, errors.New("remote_setup_proposal_identity_required")
	}
	return statusForSetup(ctx, root, actor, reference, proposalID)
}

func statusForSetup(ctx context.Context, root, actor, reference, proposalID string) (json.RawMessage, error) {
	connection, err := Load(root, actor, reference)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd, err := connection.TransportCommand(ctx)
	if err != nil {
		return nil, err
	}
	var out limitedOutput
	var diagnostic limitedOutput
	cmd.Stdout = &out
	cmd.Stderr = &diagnostic
	payload, _ := json.Marshal(map[string]string{"proposalID": proposalID})
	cmd.Stdin = bytes.NewReader(payload)
	if err = cmd.Run(); err != nil {
		return nil, errors.New(statusFailureCode(fmt.Errorf("%w %s", err, diagnostic.String())))
	}
	var result Probe
	decoder := json.NewDecoder(bytes.NewReader(out.Bytes()))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&result) != nil || decoder.Decode(new(any)) != io.EOF || !result.valid() || result.SetupProposalID != proposalID {
		return nil, errors.New("remote_protocol_error")
	}
	result.ConnectionVerified = true
	result.Reference = reference
	return json.Marshal(result)
}

// List returns public connection receipts for one authenticated actor after restart.
func List(root, actor string) ([]View, error) {
	if err := validateActor(root, actor); err != nil {
		return nil, err
	}
	if err := inspectPrivate(root, true); err != nil {
		return nil, err
	}
	release, err := connectionInventoryLease(root, actor)
	if err != nil {
		return nil, err
	}
	defer release()
	actorRoot := actorDirectory(root, actor)
	if _, err := os.Lstat(actorRoot); os.IsNotExist(err) {
		return []View{}, nil
	}
	if err := inspectPrivate(actorRoot, true); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(actorRoot)
	if err != nil {
		return nil, errors.New("connection inventory unavailable")
	}
	if len(entries) > 128 {
		return nil, errors.New("connection inventory exceeds supported limit")
	}
	views := make([]View, 0, len(entries))
	for _, entry := range entries {
		if !referencePattern.MatchString(entry.Name()) {
			return nil, errors.New("unexpected private connection entry")
		}
		reference := entry.Name()
		connection, loadErr := Load(root, actor, reference)
		if loadErr != nil {
			return nil, loadErr
		}
		dir := connectionDirectory(root, actor, reference)
		keyBytes, readErr := os.ReadFile(filepath.Join(dir, "identity"))
		if readErr != nil {
			return nil, errors.New("connection identity unavailable")
		}
		signer, parseErr := ssh.ParsePrivateKey(keyBytes)
		if parseErr != nil {
			return nil, errors.New("connection identity invalid")
		}
		body, readErr := os.ReadFile(filepath.Join(dir, "connection.json"))
		if readErr != nil {
			return nil, errors.New("connection configuration unavailable")
		}
		var endpoint Endpoint
		if json.Unmarshal(body, &endpoint) != nil {
			return nil, errors.New("connection configuration invalid")
		}
		views = append(views, View{CoreURL: endpoint.CoreURL, Reference: reference, Host: connection.Host, User: connection.User, Port: connection.Port, PublicKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))), HostFingerprint: endpoint.ConfirmedFingerprint})
	}
	return views, nil
}

func statusFailureCode(err error) string {
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "host key verification failed"), strings.Contains(message, "remote host identification has changed"):
		return "remote_host_identity_rejected"
	case strings.Contains(message, "permission denied"), strings.Contains(message, "authentication failed"):
		return "remote_authentication_failed"
	case errors.Is(err, context.DeadlineExceeded), strings.Contains(message, "deadline exceeded"), strings.Contains(message, "connection timed out"):
		return "remote_connection_timeout"
	case strings.Contains(message, "command not found"), strings.Contains(message, "no such file or directory"):
		return "remote_service_missing"
	case strings.Contains(message, "connection refused"), strings.Contains(message, "no route to host"), strings.Contains(message, "could not resolve hostname"):
		return "remote_connection_unavailable"
	default:
		return "remote_protocol_error"
	}
}

type Connection struct {
	Host, User, Command string
	Port                int
	Args                []string
}

func (c Connection) TransportCommand(ctx context.Context) (*exec.Cmd, error) {
	if c.Command != "ssh" || len(c.Args) < 2 || c.Args[len(c.Args)-1] != remoteProbeCommand {
		return nil, errors.New("invalid fixed Farm transport")
	}
	cmd := exec.CommandContext(ctx, "ssh", c.Args...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent"}
	return cmd, nil
}

type limitedOutput struct{ bytes.Buffer }

func (b *limitedOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 32768 {
		return 0, errors.New("remote output limit")
	}
	return b.Buffer.Write(p)
}

var referenceDigest = regexp.MustCompile(`^[a-f0-9]{64}$`)

// InstallationSummary is returned only from the target's compiled-bundle
// receipt. It is not inferred from a responding socket or admission badge.
type InstallationSummary struct {
	Version        string `json:"version"`
	TreeSHA256     string `json:"treeSHA256"`
	ManifestSHA256 string `json:"manifestSHA256"`
	BackendSHA256  string `json:"backendSHA256"`
}

func (i *InstallationSummary) valid() bool {
	return i != nil && len(i.Version) <= 128 && regexp.MustCompile(`\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?\z`).MatchString(i.Version) && referenceDigest.MatchString(i.TreeSHA256) && referenceDigest.MatchString(i.ManifestSHA256) && referenceDigest.MatchString(i.BackendSHA256)
}

type AppliedConfigurationSummary struct {
	Protocol                 string `json:"protocol"`
	ProposalID               string `json:"proposalID"`
	ProposalSHA256           string `json:"proposalSHA256"`
	PackageSHA256            string `json:"packageSHA256"`
	InstalledTreeSHA256      string `json:"installedTreeSHA256"`
	Host                     string `json:"host"`
	Epoch                    string `json:"epoch"`
	PolicySHA256             string `json:"policySHA256"`
	SettingsProjectionSHA256 string `json:"settingsProjectionSHA256"`
	LedgerPolicyDigest       string `json:"ledgerPolicyDigest"`
}

func (a *AppliedConfigurationSummary) valid() bool {
	if a == nil || a.Protocol != "farm-applied-setup/v1" || !referencePattern.MatchString(a.ProposalID) || !referencePattern.MatchString(a.Epoch) || !hostPattern.MatchString(a.Host) {
		return false
	}
	for _, v := range []string{a.ProposalSHA256, a.PackageSHA256, a.InstalledTreeSHA256, a.PolicySHA256, a.SettingsProjectionSHA256, a.LedgerPolicyDigest} {
		if !referenceDigest.MatchString(v) {
			return false
		}
	}
	return true
}

type Probe struct {
	ConnectionVerified         bool                         `json:"connectionVerified,omitempty"`
	Reference                  string                       `json:"reference,omitempty"`
	SetupProposalID            string                       `json:"setupProposalID,omitempty"`
	ConfigurationStatus        string                       `json:"configurationStatus,omitempty"`
	Configured                 bool                         `json:"configured,omitempty"`
	AppliedConfiguration       *AppliedConfigurationSummary `json:"appliedConfiguration,omitempty"`
	InstallationStatus         string                       `json:"installationStatus,omitempty"`
	RuntimeQualificationStatus string                       `json:"runtimeQualificationStatus,omitempty"`
	Installation               *InstallationSummary         `json:"installation,omitempty"`
	RuntimeQualified           bool                         `json:"runtimeQualified,omitempty"`
	Schema                     string                       `json:"schema"`
	Hostname                   string                       `json:"hostname"`
	UnraidVersion              string                       `json:"unraidVersion"`
	IdentitySHA256             string                       `json:"identitySHA256"`
	FarmAvailable              bool                         `json:"farmAvailable"`
	Phase                      string                       `json:"phase"`
	Protocol                   string                       `json:"protocol,omitempty"`
	Active                     bool                         `json:"active"`
	Grants                     int                          `json:"grants"`
}

const remoteProbeCommand = `python3 -c '
import hashlib,json,pathlib,socket,sys,re
payload=json.loads(sys.stdin.buffer.read(513) or b"{}")
if not isinstance(payload,dict) or set(payload)-{"proposalID"}:raise RuntimeError("invalid closed probe input")
proposal=payload.get("proposalID","")
if proposal and not re.fullmatch("[a-f0-9]{32}",proposal):raise RuntimeError("invalid proposal identity")
p=pathlib.Path("/etc/unraid-version")
v=next(x.split("=",1)[1].strip().strip(chr(34)) for x in p.read_text().splitlines() if x.startswith("version="))
identity=hashlib.sha256(pathlib.Path("/etc/machine-id").read_bytes().strip()).hexdigest()
r={"schema":"farm-remote-host/v1","hostname":socket.gethostname(),"unraidVersion":v,"identitySHA256":identity,"farmAvailable":False,"phase":"backend_unavailable","active":False,"grants":0}
r["setupProposalID"]=proposal
path="/run/unraid-core/plugin-data/ci-runner-farm/backend.sock"
def query(action,value=None):
 with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
  c.settimeout(2);c.connect(path);request={"action":action}
  if value is not None:request["value"]=value
  c.sendall((json.dumps(request)+"\n").encode());raw=b""
  while b"\n" not in raw:
   block=c.recv(65536)
   if not block:raise RuntimeError("incomplete Farm response")
   raw+=block
   if len(raw)>1048576:raise RuntimeError("Farm response bound")
  result=json.loads(raw.split(b"\n",1)[0])
  if not result.get("ok"):raise RuntimeError("Farm refused discovery")
  return result["data"]
if pathlib.Path(path).exists():
 contract=query("local-checks-contract");job=query("job-status");admission=query("admission-status")
 if contract.get("protocol")!="farm-local-checks-worker/v1":raise RuntimeError("Farm protocol mismatch")
 r.update(farmAvailable=True,protocol=contract["protocol"],active=job.get("active") is not None,grants=len(admission.get("grants") or []),phase="admission_available" if admission.get("policyMatches") else "admission_setup_required")
 if job.get("installationIdentity"):
  try:
   installed=query("remote-installation-status")
   if installed.get("protocol")!="farm-native-installation/v1":raise RuntimeError("installation protocol")
   r["installation"]={key:installed[key] for key in ("version","treeSHA256","manifestSHA256","backendSHA256")}
   r["installationStatus"]="observed"
  except Exception:
   r.pop("installation",None);r["installationStatus"]="unavailable"
  if r.get("installation"):
   try:
    readiness=query("local-checks-readiness")
    r["runtimeQualified"]=readiness.get("runtimeQualified") is True
    r["runtimeQualificationStatus"]="qualified" if r["runtimeQualified"] else "unqualified"
   except Exception:
    r["runtimeQualificationStatus"]="unavailable"
 else:
  r["installationStatus"]="unsupported";r["runtimeQualificationStatus"]="unavailable"
 if not job.get("appliedSetupVerification"):
  r["configurationStatus"]="unsupported"
 elif not proposal:
  r["configurationStatus"]="proposal_required"
 else:
  try:
   applied=query("remote-setup-applied-status",proposal)["evidence"]
   r["appliedConfiguration"]={key:applied[key] for key in ("protocol","proposalID","proposalSHA256","packageSHA256","installedTreeSHA256","host","epoch","policySHA256","settingsProjectionSHA256","ledgerPolicyDigest")}
   r["configured"]=True;r["configurationStatus"]="verified"
  except Exception:
   r["configurationStatus"]="unavailable"
 if r["active"] or r["grants"]:r["phase"]="busy"
print(json.dumps(r))
'`

func (p Probe) valid() bool {
	if p.SetupProposalID != "" && !referencePattern.MatchString(p.SetupProposalID) {
		return false
	}
	if p.ConfigurationStatus != "" && p.ConfigurationStatus != "unsupported" && p.ConfigurationStatus != "proposal_required" && p.ConfigurationStatus != "verified" && p.ConfigurationStatus != "unavailable" {
		return false
	}
	if (p.ConfigurationStatus == "verified") != p.Configured || (p.AppliedConfiguration != nil) != p.Configured {
		return false
	}
	if p.Configured && (p.Installation == nil || !p.AppliedConfiguration.valid() || p.AppliedConfiguration.ProposalID != p.SetupProposalID || p.AppliedConfiguration.InstalledTreeSHA256 != p.Installation.TreeSHA256 || p.AppliedConfiguration.Host != p.Hostname) {
		return false
	}

	if p.InstallationStatus != "" && p.InstallationStatus != "observed" && p.InstallationStatus != "unsupported" && p.InstallationStatus != "unavailable" {
		return false
	}
	if p.RuntimeQualificationStatus != "" && p.RuntimeQualificationStatus != "qualified" && p.RuntimeQualificationStatus != "unqualified" && p.RuntimeQualificationStatus != "unavailable" {
		return false
	}
	if (p.InstallationStatus == "observed") != (p.Installation != nil) && p.InstallationStatus != "" {
		return false
	}
	if (p.RuntimeQualificationStatus == "qualified") != p.RuntimeQualified {
		return false
	}
	if (p.Installation != nil && !p.Installation.valid()) || (p.RuntimeQualified && p.Installation == nil) {
		return false
	}
	if p.Schema != "farm-remote-host/v1" || !strings.HasPrefix(p.UnraidVersion, "8.") || len(p.UnraidVersion) > 128 || !referenceDigest.MatchString(p.IdentitySHA256) || len(p.Hostname) > 253 || !hostPattern.MatchString(p.Hostname) || p.Grants < 0 || p.Grants > 4096 {
		return false
	}
	if !p.FarmAvailable {
		return p.Phase == "backend_unavailable" && p.Protocol == "" && !p.Active && p.Grants == 0 && p.Installation == nil && !p.RuntimeQualified
	}
	return p.Protocol == "farm-local-checks-worker/v1" && (p.Phase == "configured" || p.Phase == "admission_available" || p.Phase == "admission_setup_required" || p.Phase == "busy")
}

func connectionInventoryLease(root, actor string) (func(), error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	release, err := githubapp.AcquireCredentialLease(ctx, actorDirectory(root, actor)+".inventory")
	if err != nil {
		cancel()
		return nil, errors.New("remote_host_inventory_busy_or_unavailable")
	}
	return func() { release(); cancel() }, nil
}
