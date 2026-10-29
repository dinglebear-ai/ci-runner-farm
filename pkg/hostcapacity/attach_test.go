package hostcapacity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func attachmentFixture(t *testing.T) (string, Config, QAAttachment) {
	t.Helper()
	root := testRoot(t)
	previous := testConfig(root)
	previous.Policy = sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}, AgingSeconds: 300, Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}, Maximum: 1, Priority: 3}}}
	path := filepath.Join(root, "host-capacity.json")
	writeConfig(t, path, previous)
	broker := sharedcapacity.Broker{Path: previous.LedgerPath}
	if err := broker.Initialize(&previous.Policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(previous)
	sum := sha256.Sum256(data)
	revised := sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 112000, VCPUs: 20}, AgingSeconds: 300, Pools: map[string]sharedcapacity.Pool{
		"build":      previous.Policy.Pools["build"],
		"qa-runner":  {Cost: sharedcapacity.Resources{MemoryMiB: 2048, VCPUs: 1}, Minimum: 4, Maximum: 4, Priority: 4},
		"qa-guest":   {Cost: sharedcapacity.Resources{MemoryMiB: 9216, VCPUs: 4}, Maximum: 4, Priority: 5},
		"qa-service": {Cost: sharedcapacity.Resources{MemoryMiB: 256, VCPUs: 1}, Maximum: 1, Priority: 5},
	}}
	build := revised.Pools["build"]
	build.Minimum = 1
	revised.Pools["build"] = build
	return path, previous, QAAttachment{Schema: "farm-qa-attachment/v1", ExpectedOwnerDigest: hex.EncodeToString(sum[:]), Previous: previous, RevisedPolicy: revised, Consumers: map[string]Consumer{"qa": {Pools: []string{"qa-runner", "qa-guest", "qa-service"}, OverheadMiB: 1024}}}
}

func TestQAAttachmentCommitsSameOwnerClosedAndRetries(t *testing.T) {
	path, previous, request := attachmentFixture(t)
	lease, err := acquire(context.Background(), path, true, previous.Host, uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	attestations := 0
	attest := func() error { attestations++; return nil }
	if err := lease.AttachQA(request, sharedcapacity.Resources{MemoryMiB: 128435, VCPUs: 24}, attest); err != nil {
		t.Fatal(err)
	}
	got := *lease.Config
	if got.Mode != "closed" || got.QAAttachment != nil || got.Epoch != previous.Epoch || got.LedgerPath != previous.LedgerPath || got.ReceiptRoot != previous.ReceiptRoot || got.TokenPath != previous.TokenPath || got.LockPath != previous.LockPath {
		t.Fatal("attachment changed original ownership or reopened starts")
	}
	if !reflect.DeepEqual(got.Policy, request.RevisedPolicy) || !reflect.DeepEqual(got.Consumers, request.Consumers) {
		t.Fatal("destination policy or consumer differs")
	}
	if _, err := (&sharedcapacity.Broker{Path: got.LedgerPath}).Status(&request.RevisedPolicy); err != nil {
		t.Fatal("ledger did not commit destination", err)
	}
	if attestations < 3 {
		t.Fatal("native ownership was not reattested at publication boundaries")
	}
	if err := lease.AttachQA(request, sharedcapacity.Resources{MemoryMiB: 128435, VCPUs: 24}, attest); err != nil {
		t.Fatal("exact closed retry", err)
	}
}

func TestQAAttachmentRejectsStaleCASOwnersAndPhysicalOvercommit(t *testing.T) {
	for _, scenario := range []string{"stale-cas", "shared-lease", "native-busy", "memory-reserve", "cpu-reserve", "changed-build-cost", "changed-build-priority", "changed-epoch", "changed-ledger", "foreign-consumer"} {
		t.Run(scenario, func(t *testing.T) {
			path, previous, request := attachmentFixture(t)
			physical := sharedcapacity.Resources{MemoryMiB: 128435, VCPUs: 24}
			attest := func() error { return nil }
			switch scenario {
			case "stale-cas":
				request.ExpectedOwnerDigest = string(make([]byte, 64))
			case "native-busy":
				attest = func() error { return errors.New("native inventory changed") }
			case "memory-reserve":
				physical.MemoryMiB = 128383
			case "cpu-reserve":
				physical.VCPUs = 23
			case "changed-build-cost":
				p := request.RevisedPolicy.Pools["build"]
				p.Cost.MemoryMiB++
				request.RevisedPolicy.Pools["build"] = p
			case "changed-build-priority":
				p := request.RevisedPolicy.Pools["build"]
				p.Priority++
				request.RevisedPolicy.Pools["build"] = p
			case "changed-epoch":
				request.Previous.Epoch = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
			case "changed-ledger":
				request.Previous.LedgerPath += ".replacement"
			case "foreign-consumer":
				request.Consumers["other"] = Consumer{Pools: []string{"qa-service"}}
			}
			if scenario == "changed-epoch" || scenario == "changed-ledger" {
				data, _ := json.Marshal(request.Previous)
				sum := sha256.Sum256(data)
				request.ExpectedOwnerDigest = hex.EncodeToString(sum[:])
			}
			lease, err := acquire(t.Context(), path, scenario != "shared-lease", previous.Host, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			defer lease.Close()
			if err := lease.AttachQA(request, physical, attest); err == nil {
				t.Fatal("unsafe attachment accepted")
			}
			current, err := load(path, previous.Host, uint32(os.Geteuid()))
			if err != nil || !reflect.DeepEqual(*current, previous) {
				t.Fatal("refusal changed owner", err)
			}
		})
	}
}

func TestQAAttachmentNeverReplacesMissingCorruptOrNonemptyLedger(t *testing.T) {
	for _, scenario := range []string{"missing", "corrupt", "grant", "pending"} {
		t.Run(scenario, func(t *testing.T) {
			path, previous, request := attachmentFixture(t)
			broker := sharedcapacity.Broker{Path: previous.LedgerPath}
			switch scenario {
			case "missing":
				if err := os.Remove(previous.LedgerPath); err != nil {
					t.Fatal(err)
				}
			case "corrupt":
				if err := os.WriteFile(previous.LedgerPath, []byte("retain corrupt original"), 0600); err != nil {
					t.Fatal(err)
				}
			default:
				if _, err := broker.Admit(&previous.Policy, sharedcapacity.Request{ID: "existing", Pool: "build"}); err != nil {
					t.Fatal(err)
				}
				if scenario == "pending" {
					if _, err := broker.Admit(&previous.Policy, sharedcapacity.Request{ID: "waiting", Pool: "build"}); err != nil {
						t.Fatal(err)
					}
				}
			}
			before, _ := os.ReadFile(previous.LedgerPath)
			var snapshot sharedcapacity.Snapshot
			if scenario == "grant" || scenario == "pending" {
				snapshot, _ = broker.Status(&previous.Policy)
			}
			lease, err := acquire(t.Context(), path, true, previous.Host, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			defer lease.Close()
			if err := lease.AttachQA(request, sharedcapacity.Resources{MemoryMiB: 128435, VCPUs: 24}, func() error { return nil }); err == nil {
				t.Fatal("unsafe ledger accepted")
			}
			after, _ := os.ReadFile(previous.LedgerPath)
			if scenario == "grant" || scenario == "pending" {
				current, err := broker.Status(&previous.Policy)
				if err != nil || !reflect.DeepEqual(snapshot.Grants, current.Grants) || !reflect.DeepEqual(snapshot.Pending, current.Pending) {
					t.Fatal("refusal changed original grants or queue", err)
				}
			} else if !reflect.DeepEqual(before, after) {
				t.Fatal("refusal replaced missing or corrupt ledger")
			}
		})
	}
}

func TestQAAttachmentRetainsClosedRecoveryAtEveryCommitBoundary(t *testing.T) {
	for _, stop := range []int{1, 2, 3, 4} {
		t.Run(string(rune('0'+stop)), func(t *testing.T) {
			path, previous, request := attachmentFixture(t)
			lease, err := acquire(t.Context(), path, true, previous.Host, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			count := 0
			interrupted := func() error {
				count++
				if count == stop {
					return errors.New("interrupted native proof")
				}
				return nil
			}
			physical := sharedcapacity.Resources{MemoryMiB: 128435, VCPUs: 24}
			if err := lease.AttachQA(request, physical, interrupted); err == nil {
				t.Fatal("lost native proof was ignored")
			}
			if stop > 1 && lease.Config.Mode != "closed" {
				t.Fatal("interrupted transition reopened owner")
			}
			if lease.Config.QAAttachment != nil {
				if err := lease.Activate(); err == nil {
					t.Fatal("pending QA attachment activated before adoption")
				}
			}
			if err := lease.Close(); err != nil {
				t.Fatal(err)
			}
			lease, err = acquire(t.Context(), path, true, previous.Host, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal("pending owner cannot resume", err)
			}
			defer lease.Close()
			if err := lease.AttachQA(request, physical, func() error { return errors.New("native inventory became busy") }); err == nil {
				t.Fatal("recovery skipped fresh native attestation")
			}
			if err := lease.AttachQA(request, physical, func() error { return nil }); err != nil {
				t.Fatal("exact recovery failed", err)
			}
			if lease.Config.Mode != "closed" || lease.Config.QAAttachment != nil {
				t.Fatal("recovery did not finish closed")
			}
		})
	}
}

func TestQAAttachmentCannotPublishAnUnreadablePendingOwner(t *testing.T) {
	path, previous, request := attachmentFixture(t)
	previous.Organization = strings.Repeat("a", 39)
	for i := range 256 {
		previous.ScanRepositories = append(previous.ScanRepositories, previous.Organization+"/"+fmt.Sprintf("%099d", i))
	}
	request.Previous = previous
	data, _ := json.Marshal(previous)
	sum := sha256.Sum256(data)
	request.ExpectedOwnerDigest = hex.EncodeToString(sum[:])
	writeConfig(t, path, previous)
	lease, err := acquire(t.Context(), path, true, previous.Host, uint32(os.Geteuid()))
	if err != nil {
		t.Fatal("large supported original cannot load", err)
	}
	defer lease.Close()
	if err := lease.AttachQA(request, sharedcapacity.Resources{MemoryMiB: 128435, VCPUs: 24}, func() error { return nil }); err == nil {
		t.Fatal("oversized pending owner accepted")
	}
	current, err := load(path, previous.Host, uint32(os.Geteuid()))
	if err != nil || !reflect.DeepEqual(*current, previous) {
		t.Fatal("refusal published an unreadable owner", err)
	}
}

func TestQAAttachmentPendingPublicationIncludesEncoderNewline(t *testing.T) {
	for _, size := range []int{64*1024 - 1, 64 * 1024} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			path, previous, request := attachmentFixture(t)
			previous.Organization = strings.Repeat("a", 39)
			for i := range 256 {
				previous.ScanRepositories = append(previous.ScanRepositories, previous.Organization+"/"+fmt.Sprintf("%03d", i))
			}
			bind := func() []byte {
				request.Previous = previous
				data, _ := json.Marshal(previous)
				sum := sha256.Sum256(data)
				request.ExpectedOwnerDigest = hex.EncodeToString(sum[:])
				data, _ = json.Marshal(request.pendingOwner())
				return data
			}
			data := bind()
			if (size-len(data))%2 != 0 {
				request.RevisedPolicy.Budget.MemoryMiB = 99999
				data = bind()
			}
			remaining := (size - len(data)) / 2 // Previous appears in both the owner and journal.
			for i := range previous.ScanRepositories {
				padding := min(remaining, 97)
				previous.ScanRepositories[i] += strings.Repeat("a", padding)
				remaining -= padding
			}
			if remaining != 0 || len(bind()) != size {
				t.Fatal("fixture did not reach the exact encoded boundary")
			}
			writeConfig(t, path, previous)
			lease, err := acquire(t.Context(), path, true, previous.Host, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			defer lease.Close()
			attestations := 0
			err = lease.AttachQA(request, sharedcapacity.Resources{MemoryMiB: 128435, VCPUs: 24}, func() error {
				attestations++
				if attestations == 2 {
					return errors.New("stop after pending publication")
				}
				return nil
			})
			if err == nil {
				t.Fatal("attachment unexpectedly completed")
			}
			current, err := load(path, previous.Host, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal("publication became unreadable", err)
			}
			if size == 64*1024 {
				if attestations != 0 || !reflect.DeepEqual(*current, previous) {
					t.Fatal("over-bound publication changed the original owner")
				}
			} else if attestations != 2 || current.QAAttachment == nil {
				t.Fatal("exactly bounded pending publication was refused")
			}
		})
	}
}
