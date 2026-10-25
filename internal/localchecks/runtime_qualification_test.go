package localchecks

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRuntimeQualificationRequiresExactReviewedMaterialsAndFullPass(t *testing.T) {
	b := ProtectedBinding{Epoch: strings.Repeat("a", 32), Host: "worker", Image: "sha256:" + strings.Repeat("b", 64)}
	helper := strings.Repeat("c", 64)
	policy := strings.Repeat("d", 64)
	record := RuntimeQualification{MachineIDSHA256: strings.Repeat("8", 64), KernelRelease: "6.12.fixture", Version: 1, Protocol: "farm-local-checks-qualification/v1", KernelReceiptSHA256: strings.Repeat("3", 64), FullReceiptSHA256: strings.Repeat("4", 64), FullResultSHA256: strings.Repeat("5", 64), Host: b.Host, Epoch: b.Epoch, Image: b.Image, HelperSHA256: helper, PolicySHA256: policy, KernelRequestID: strings.Repeat("e", 32), FullRequestID: strings.Repeat("f", 32)}
	submission := Submission{Version: 1, Repository: "unraid/core", Commit: strings.Repeat("1", 40), Base: strings.Repeat("1", 40), BundleSHA256: strings.Repeat("2", 64), TimeoutSeconds: 180, ScratchMiB: 1024, RequestID: record.KernelRequestID, MemoryMiB: 12288, CPUs: 2}
	kernel := NativeReceipt{ContainerID: strings.Repeat("6", 64), Fence: strings.Repeat("7", 32), Version: 1, Epoch: b.Epoch, State: "released", Worker: WorkerBinding{Image: b.Image}, Request: submission, Qualification: &QualificationProof{Scope: "cgroup-isolation-only", Image: b.Image, ProbeSHA256: helper, Outer: KernelLimits{CPUQuota: 200000, CPUPeriod: 100000, MemoryBytes: 12288 << 20, PIDs: 4096, Domain: true}, Nested: KernelLimits{CPUQuota: 100000, CPUPeriod: 100000, MemoryBytes: 64 << 20, PIDs: 64, Domain: true}}}
	full := kernel
	full.Qualification = nil
	full.Request.RequestID = record.FullRequestID
	full.Request.Commit = strings.Repeat("1", 40)
	full.Request.Base = full.Request.Commit
	full.Request.BundleSHA256 = strings.Repeat("2", 64)
	result := Result{RequestID: record.FullRequestID, Host: b.Host, Commit: full.Request.Commit, Base: full.Request.Base, BundleSHA256: full.Request.BundleSHA256, Status: "passed", StartedAt: time.Now().Add(-time.Minute), FinishedAt: time.Now()}
	check := func() error {
		return validateRuntimeQualification(record, b, helper, policy, strings.Repeat("8", 64), "6.12.fixture", kernel, full, result)
	}
	if err := check(); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"helper", "image", "epoch", "policy", "exit", "release", "probe", "machine", "kernel"} {
		savedB, savedR, savedResult, savedFull, savedKernel := b, record, result, full, kernel
		switch field {
		case "machine":
			record.MachineIDSHA256 = strings.Repeat("0", 64)
		case "kernel":
			record.KernelRelease = "other-kernel"
		case "helper":
			record.HelperSHA256 = strings.Repeat("0", 64)
		case "image":
			b.Image = "sha256:" + strings.Repeat("0", 64)
		case "epoch":
			b.Epoch = strings.Repeat("0", 32)
		case "policy":
			record.PolicySHA256 = strings.Repeat("0", 64)
		case "exit":
			result.ExitCode = 1
		case "release":
			full.State = "running"
		case "probe":
			copy := *kernel.Qualification
			copy.Nested.MemoryBytes = 0
			kernel.Qualification = &copy
		}
		if check() == nil {
			t.Fatal("qualification survived changed", field)
		}
		b, record, result, full, kernel = savedB, savedR, savedResult, savedFull, savedKernel
	}
}

func TestQualificationEvidenceIsPrivatePinnedClosedAndNotSymlinked(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "qualification.json")
	raw := []byte(`{"version":1}`)
	sum := sha256.Sum256(raw)
	digest := hex.EncodeToString(sum[:])
	os.WriteFile(path, raw, 0600)
	var record RuntimeQualification
	read := func(p, d string) error { return readQualificationJSONOwned(p, d, &record, uint32(os.Geteuid())) }
	if err := read(path, digest); err != nil {
		t.Fatal(err)
	}
	if read(path, strings.Repeat("0", 64)) == nil {
		t.Fatal("changed evidence digest accepted")
	}
	alias := filepath.Join(root, "alias.json")
	os.Symlink(path, alias)
	if read(alias, digest) == nil {
		t.Fatal("symlinked evidence accepted")
	}
	os.Chmod(path, 0644)
	if read(path, digest) == nil {
		t.Fatal("nonprivate evidence accepted")
	}
	os.Chmod(path, 0600)
	unknown := []byte(`{"version":1,"promote":true}`)
	os.WriteFile(path, unknown, 0600)
	sum = sha256.Sum256(unknown)
	if read(path, hex.EncodeToString(sum[:])) == nil {
		t.Fatal("unknown acceptance authority field accepted")
	}
}
