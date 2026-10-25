package localchecks

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"golang.org/x/sys/unix"
)

// RuntimeQualification is an explicit owner-reviewed acceptance record, not a
// scheduler request or a general GitHub Actions runner qualification.
type RuntimeQualification struct {
	Version             int    `json:"version"`
	Protocol            string `json:"protocol"`
	Host                string `json:"host"`
	Epoch               string `json:"epoch"`
	Image               string `json:"image"`
	MachineIDSHA256     string `json:"machineIDSHA256"`
	KernelRelease       string `json:"kernelRelease"`
	HelperSHA256        string `json:"helperSHA256"`
	PolicySHA256        string `json:"policySHA256"`
	KernelRequestID     string `json:"kernelRequestID"`
	KernelReceiptSHA256 string `json:"kernelReceiptSHA256"`
	FullRequestID       string `json:"fullRequestID"`
	FullReceiptSHA256   string `json:"fullReceiptSHA256"`
	FullResultSHA256    string `json:"fullResultSHA256"`
}

func validateRuntimeQualification(r RuntimeQualification, b ProtectedBinding, helper, policy, machineID, kernelRelease string, kernel, full NativeReceipt, result Result) error {
	invalid := errors.New("local_checks_qualification_materials_changed")
	if !bundleID.MatchString(machineID) || r.MachineIDSHA256 != machineID || kernelRelease == "" || len(kernelRelease) > 256 || r.KernelRelease != kernelRelease || r.Version != 1 || r.Protocol != "farm-local-checks-qualification/v1" || r.Host != b.Host || r.Epoch != b.Epoch || r.Image != b.Image || !bundleID.MatchString(helper) || !bundleID.MatchString(policy) || r.HelperSHA256 != helper || r.PolicySHA256 != policy || !bundleID.MatchString(r.KernelReceiptSHA256) || !bundleID.MatchString(r.FullReceiptSHA256) || !bundleID.MatchString(r.FullResultSHA256) || !identifier.MatchString(r.KernelRequestID) || !identifier.MatchString(r.FullRequestID) || r.KernelRequestID == r.FullRequestID {
		return invalid
	}
	for _, entry := range []struct {
		receipt NativeReceipt
		id      string
	}{{kernel, r.KernelRequestID}, {full, r.FullRequestID}} {
		n := entry.receipt
		if n.Version != 1 || n.Epoch != b.Epoch || n.State != "released" || n.Worker.Image != b.Image || n.Request.RequestID != entry.id || n.Request.Validate() != nil || !immutableContainerID.MatchString(n.ContainerID) || !nativeEpoch.MatchString(n.Fence) {
			return invalid
		}
	}
	p := kernel.Qualification
	if validateQualificationSubmission(kernel.Request) != nil || p == nil || p.Scope != "cgroup-isolation-only" || p.Image != b.Image || p.ProbeSHA256 != helper || p.DiskQuotaEnforced || p.Outer.Verify(kernel.Request.MemoryMiB, kernel.Request.CPUs, 4096) != nil || p.Nested.Verify(64, 1, 64) != nil {
		return invalid
	}
	if full.Request.MemoryMiB > kernel.Request.MemoryMiB || full.Request.CPUs > kernel.Request.CPUs || result.RequestID != r.FullRequestID || result.Host != b.Host || result.Commit != full.Request.Commit || result.Base != full.Request.Base || result.BundleSHA256 != full.Request.BundleSHA256 || result.Status != "passed" || result.ExitCode != 0 || result.StartedAt.IsZero() || !result.FinishedAt.After(result.StartedAt) {
		return invalid
	}
	return nil
}

// VerifyRuntimeQualification binds acceptance to the executing helper and current
// protected policy on every general dispatch. Cleanup does not require it.
func VerifyRuntimeQualification(bindingPath string, b ProtectedBinding) error {
	if !bundleID.MatchString(b.QualificationSHA256) {
		return errors.New("local_checks_qualification_receipt_required")
	}
	materials, config, err := currentQualificationMaterials(b)
	if err != nil {
		return err
	}
	var record RuntimeQualification
	if err = readQualificationJSON(filepath.Join(filepath.Dir(bindingPath), "native-local-checks-qualification.json"), b.QualificationSHA256, &record); err != nil {
		return err
	}
	var kernel, full NativeReceipt
	if !identifier.MatchString(record.KernelRequestID) || !identifier.MatchString(record.FullRequestID) {
		return errors.New("local_checks_qualification_identity_invalid")
	}
	for _, entry := range []struct {
		id, digest string
		out        *NativeReceipt
	}{{record.KernelRequestID, record.KernelReceiptSHA256, &kernel}, {record.FullRequestID, record.FullReceiptSHA256, &full}} {
		if err = readQualificationJSON(filepath.Join(config.ReceiptRoot, "local-checks", entry.id+".json"), entry.digest, entry.out); err != nil {
			return err
		}
	}
	var result Result
	if err = readQualificationJSON(filepath.Join(b.Root, record.FullRequestID, "evidence", record.FullRequestID, "result.json"), record.FullResultSHA256, &result); err != nil {
		return err
	}
	return validateRuntimeQualification(record, b, materials.HelperSHA256, materials.PolicySHA256, materials.MachineIDSHA256, materials.KernelRelease, kernel, full, result)
}

func readQualificationJSON(path, digest string, out any) error {
	return readQualificationJSONOwned(path, digest, out, 0)
}
func readQualificationJSONOwned(path, digest string, out any, owner uint32) error {
	if !bundleID.MatchString(digest) {
		return errors.New("local_checks_qualification_digest_invalid")
	}
	actual, err := privateQualificationEvidence(path, out, owner)
	if err != nil {
		return err
	}
	if actual != digest {
		return errors.New("local_checks_qualification_evidence_changed")
	}
	return nil
}
func privateQualificationEvidence(path string, out any, owner uint32) (string, error) {
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil || canonical != path {
		return "", errors.New("local_checks_qualification_evidence_unavailable")
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return "", err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != owner || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 65536 {
		return "", errors.New("local_checks_qualification_evidence_not_private")
	}
	raw, err := io.ReadAll(io.LimitReader(f, 65537))
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(out) != nil || decoder.Decode(new(any)) != io.EOF {
		return "", errors.New("local_checks_qualification_evidence_invalid")
	}
	return hex.EncodeToString(sum[:]), nil
}

// WriteRuntimeReadiness is read-only dynamic admission evidence. It does not
// mint acceptance, promote a binding, reserve capacity, or contact Docker.
func WriteRuntimeReadiness(bindingPath string, output io.Writer) error {
	if os.Geteuid() != 0 {
		return errors.New("local_checks_native_root_required")
	}
	binding, err := loadProtectedBinding(bindingPath, 0, true)
	if err != nil {
		return json.NewEncoder(output).Encode(map[string]any{"protocol": NativeProtocol, "runtimeQualified": false, "reason": "protected_binding_unavailable"})
	}
	qualified := binding.RuntimeQualified && VerifyRuntimeQualification(bindingPath, binding) == nil
	reason := "qualification_missing_or_changed"
	if qualified {
		reason = "reviewed_materials_match"
	}
	return json.NewEncoder(output).Encode(map[string]any{"protocol": NativeProtocol, "runtimeQualified": qualified, "reason": reason, "host": binding.Host, "epoch": binding.Epoch, "image": binding.Image})
}

func currentQualificationMaterials(b ProtectedBinding) (RuntimeQualification, *hostcapacity.Config, error) {
	var materials RuntimeQualification
	config, err := hostcapacity.Load(hostcapacity.ConfigPath)
	if err != nil {
		return materials, nil, err
	}
	if config.Validate(b.Host) != nil || config.Epoch != b.Epoch || config.Mode != "active" {
		return materials, nil, errors.New("local_checks_qualification_policy_changed")
	}
	policyRaw, _ := json.Marshal(config)
	policySum := sha256.Sum256(policyRaw)
	f, err := os.Open("/proc/self/exe")
	if err != nil {
		return materials, nil, err
	}
	info, statErr := f.Stat()
	if statErr != nil || !info.Mode().IsRegular() || info.Size() > 64<<20 {
		f.Close()
		return materials, nil, errors.New("local_checks_helper_identity_unavailable")
	}
	hash := sha256.New()
	_, copyErr := io.Copy(hash, io.LimitReader(f, 64<<20))
	closeErr := f.Close()
	if errors.Join(copyErr, closeErr) != nil {
		return materials, nil, errors.New("local_checks_helper_identity_unavailable")
	}
	machine, err := os.ReadFile("/etc/machine-id")
	if err != nil || len(machine) > 128 || len(strings.TrimSpace(string(machine))) == 0 {
		return materials, nil, errors.New("local_checks_machine_identity_unavailable")
	}
	release, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil || len(release) > 256 || strings.TrimSpace(string(release)) == "" {
		return materials, nil, errors.New("local_checks_kernel_identity_unavailable")
	}
	machineSum := sha256.Sum256([]byte(strings.TrimSpace(string(machine))))

	materials = RuntimeQualification{Version: 1, Protocol: "farm-local-checks-qualification/v1", Host: b.Host, Epoch: b.Epoch, Image: b.Image, HelperSHA256: hex.EncodeToString(hash.Sum(nil)), PolicySHA256: hex.EncodeToString(policySum[:]), MachineIDSHA256: hex.EncodeToString(machineSum[:]), KernelRelease: strings.TrimSpace(string(release))}
	return materials, config, nil
}

// ReviewRuntimeQualification emits a proposed owner-review record only after
// every current material and retained proof matches. It writes no state.
func ReviewRuntimeQualification(bindingPath, kernelID, fullID string, output io.Writer) error {
	if os.Geteuid() != 0 {
		return errors.New("local_checks_native_root_required")
	}
	if !identifier.MatchString(kernelID) || !identifier.MatchString(fullID) || kernelID == fullID {
		return errors.New("local_checks_qualification_identity_invalid")
	}
	binding, err := loadProtectedBinding(bindingPath, 0, true)
	if err != nil {
		return err
	}
	record, config, err := currentQualificationMaterials(binding)
	if err != nil {
		return err
	}
	record.KernelRequestID = kernelID
	record.FullRequestID = fullID
	var kernel, full NativeReceipt
	var result Result
	record.KernelReceiptSHA256, err = privateQualificationEvidence(filepath.Join(config.ReceiptRoot, "local-checks", kernelID+".json"), &kernel, 0)
	if err != nil {
		return err
	}
	record.FullReceiptSHA256, err = privateQualificationEvidence(filepath.Join(config.ReceiptRoot, "local-checks", fullID+".json"), &full, 0)
	if err != nil {
		return err
	}
	record.FullResultSHA256, err = privateQualificationEvidence(filepath.Join(binding.Root, fullID, "evidence", fullID, "result.json"), &result, 0)
	if err != nil {
		return err
	}
	if err = validateRuntimeQualification(record, binding, record.HelperSHA256, record.PolicySHA256, record.MachineIDSHA256, record.KernelRelease, kernel, full, result); err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(record)
}
