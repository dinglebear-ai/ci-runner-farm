package capacitycmd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestQAAttachmentCommandRequiresExactNativeArguments(t *testing.T) {
	if !validArguments([]string{"attach-qa", "0123456789abcdef0123456789abcdef", "/protected/request.json"}) {
		t.Fatal("native QA attachment dispatch is missing")
	}
	for _, args := range [][]string{{"attach-qa"}, {"attach-qa", "epoch"}, {"attach-qa", "epoch", "file", "extra"}} {
		if validArguments(args) {
			t.Fatal("incomplete attachment reached native owner")
		}
	}
}

func TestAttachmentClosuresPreserveOriginalCustody(t *testing.T) {
	for _, scenario := range []string{"content", "replacement", "permissions", "symlink", "fifo"} {
		t.Run(scenario, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "admission.closed")
			if scenario == "fifo" {
				if err := syscall.Mkfifo(path, 0600); err != nil {
					t.Fatal(err)
				}
				if guards, err := openAttachmentClosures([]string{path}, uint32(os.Geteuid())); err == nil {
					for _, g := range guards {
						g.file.Close()
					}
					t.Fatal("nonregular closure accepted")
				}
				return
			}
			if err := os.WriteFile(path, []byte("foreign owner closure\n"), 0600); err != nil {
				t.Fatal(err)
			}
			guards, err := openAttachmentClosures([]string{path}, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			defer guards[0].file.Close()
			if err := guards[0].verify(); err != nil {
				t.Fatal("unchanged closure refused", err)
			}
			switch scenario {
			case "content":
				err = os.WriteFile(path, []byte("changed closure\n"), 0600)
			case "permissions":
				err = os.Chmod(path, 0644)
			default:
				if err = os.Rename(path, path+".original"); err != nil {
					t.Fatal(err)
				}
				if scenario == "symlink" {
					err = os.Symlink(path+".original", path)
				} else {
					err = os.WriteFile(path, []byte("foreign owner closure\n"), 0600)
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := guards[0].verify(); err == nil {
				t.Fatal("changed original closure accepted")
			}
			if _, err := os.Lstat(path); err != nil {
				t.Fatal("verification removed a foreign closure", err)
			}
		})
	}
}

func TestAttachmentPhysicalResourcesUseHostTotals(t *testing.T) {
	got, err := parseAttachmentPhysicalResources("MemTotal:       131517828 kB\nMemFree: 1 kB\n", 24)
	if err != nil || got.MemoryMiB != 128435 || got.VCPUs != 24 {
		t.Fatal("physical envelope differs", got, err)
	}
	for _, s := range []string{"", "MemFree: 1000 kB", "MemTotal: unavailable kB"} {
		if _, err := parseAttachmentPhysicalResources(s, 24); err == nil {
			t.Fatal("missing host proof accepted")
		}
	}
}

type attachmentInventoryDocker struct {
	items   []farmcapacity.Container
	failure error
}

func (d attachmentInventoryDocker) Owned(context.Context) ([]farmcapacity.Container, error) {
	return d.items, d.failure
}
func (attachmentInventoryDocker) Inspect(context.Context, string) (*farmcapacity.Container, error) {
	return nil, errors.New("unexpected native inspection")
}
func (attachmentInventoryDocker) Start(context.Context, string) error {
	return errors.New("attachment must not start a workload")
}

func TestAttachmentRequiresActualEmptyNativeInventoryAndReceipts(t *testing.T) {
	for _, scenario := range []string{"empty", "docker-unavailable", "native-owner", "orphan-receipt", "sidecar", "sidecar-unavailable"} {
		t.Run(scenario, func(t *testing.T) {
			root := t.TempDir()
			docker := filepath.Join(root, "docker")
			script := "#!/bin/sh\nexit 0\n"
			if scenario == "sidecar" {
				script = "#!/bin/sh\nprintf '%s\\n' owned-sidecar\n"
			}
			if scenario == "sidecar-unavailable" {
				script = "#!/bin/sh\nexit 1\n"
			}
			if err := os.WriteFile(docker, []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", root)
			inventory := attachmentInventoryDocker{}
			if scenario == "docker-unavailable" {
				inventory.failure = errors.New("unavailable")
			}
			if scenario == "native-owner" {
				inventory.items = []farmcapacity.Container{{Name: "unrecognized-native-owner"}}
			}
			receipts := filepath.Join(root, "receipts")
			if err := os.Mkdir(receipts, 0700); err != nil {
				t.Fatal(err)
			}
			if scenario == "orphan-receipt" {
				if err := os.WriteFile(filepath.Join(receipts, "ci-runner-build-1.json"), []byte(`{}`), 0600); err != nil {
					t.Fatal(err)
				}
			}
			controller := &farmcapacity.Controller{Docker: inventory, ReceiptRoot: receipts}
			err := verifyAttachmentInventory(t.Context(), controller)
			if scenario == "empty" && err != nil {
				t.Fatal("proved empty native owner rejected", err)
			}
			if scenario != "empty" && err == nil {
				t.Fatal("incomplete native census accepted")
			}
		})
	}
}

func TestQAAttachmentRequestParserRetainsProtectedTypedContract(t *testing.T) {
	root := t.TempDir()
	previous := hostcapacity.Config{Schema: 1, Host: "build-host", Epoch: "0123456789abcdef0123456789abcdef", Organization: "example-org", Mode: "active", LedgerPath: filepath.Join(root, "ledger"), ReceiptRoot: filepath.Join(root, "receipts"), TokenPath: filepath.Join(root, "token"), LockPath: filepath.Join(root, "lock"), Policy: sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}, AgingSeconds: 300, Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}, Maximum: 1, Priority: 3}}}}
	data, _ := json.Marshal(previous)
	digest := sha256.Sum256(data)
	revised := sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 112000, VCPUs: 20}, AgingSeconds: 300, Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}, Minimum: 1, Maximum: 1, Priority: 3}, "qa-runner": {Cost: sharedcapacity.Resources{MemoryMiB: 2048, VCPUs: 1}, Minimum: 4, Maximum: 4, Priority: 4}, "qa-guest": {Cost: sharedcapacity.Resources{MemoryMiB: 9216, VCPUs: 4}, Maximum: 4, Priority: 5}}}
	request := hostcapacity.QAAttachment{Schema: "farm-qa-attachment/v1", ExpectedOwnerDigest: hex.EncodeToString(digest[:]), Previous: previous, RevisedPolicy: revised, Consumers: map[string]hostcapacity.Consumer{"qa": {Pools: []string{"qa-runner", "qa-guest"}, OverheadMiB: 1024}}}
	data, _ = json.Marshal(request)
	for _, scenario := range []string{"valid", "public", "symlink", "trailing", "unknown", "fifo"} {
		t.Run(scenario, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "request.json")
			input := append([]byte(nil), data...)
			if scenario == "trailing" {
				input = append(input, []byte(` {}`)...)
			}
			if scenario == "unknown" {
				input = append(input[:len(input)-1], []byte(`,"unreviewed":true}`)...)
			}
			if scenario == "fifo" {
				if err := syscall.Mkfifo(path, 0600); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.WriteFile(path, input, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if scenario == "public" {
				if err := os.Chmod(path, 0644); err != nil {
					t.Fatal(err)
				}
			}
			if scenario == "symlink" {
				if err := os.Rename(path, path+".original"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(path+".original", path); err != nil {
					t.Fatal(err)
				}
			}
			got, err := readQAAttachment(path, uint32(os.Geteuid()))
			if scenario == "valid" {
				if err != nil || got.ExpectedOwnerDigest != request.ExpectedOwnerDigest {
					t.Fatal("valid protected attachment rejected", err)
				}
			} else if err == nil {
				t.Fatal("unsafe attachment request accepted")
			}
		})
	}
}
