package remotehost

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestSetupProposalHasNoExecutionOrStorageAuthority(t *testing.T) {
	p := SetupProposal{Version: 1, OperationID: strings.Repeat("a", 32), StageOperationID: strings.Repeat("b", 32), PackageSHA256: strings.Repeat("c", 64), Owner: "dinglebear-ai", Repository: "labby", MemoryMiB: 12288, VCPUs: 2, RunnerCount: 1}
	if p.Validate() != nil {
		t.Fatal(p.Validate())
	}
	for _, field := range []string{"memory", "cpu", "owner", "repository", "runner", "package", "stage"} {
		q := p
		switch field {
		case "memory":
			q.MemoryMiB = 0
		case "cpu":
			q.VCPUs = 0
		case "owner":
			q.Owner = "../root"
		case "repository":
			q.Repository = "other/repo"
		case "runner":
			q.RunnerCount = 2
		case "package":
			q.PackageSHA256 = "arbitrary"
		case "stage":
			q.StageOperationID = "../x"
		}
		if q.Validate() == nil {
			t.Fatal("accepted", field)
		}
	}
}

func TestPendingSetupIsBoundedPrivateAndNeverAppliesConfiguration(t *testing.T) {
	root := privateRoot(t)
	stage := privateRoot(t)
	stageID := strings.Repeat("b", 32)
	dir := filepath.Join(stage, stageID)
	os.Mkdir(dir, 0700)
	raw := fixturePackage(t, "ci-runner-farm")
	view, err := InspectPackage(raw)
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "ci-runner-farm.tgz")
	os.WriteFile(file, raw, 0600)
	p := SetupProposal{Version: 1, OperationID: strings.Repeat("a", 32), StageOperationID: stageID, PackageSHA256: view.SHA256, Owner: "dinglebear-ai", Repository: "labby", MemoryMiB: 12288, VCPUs: 2, RunnerCount: 1}
	config := filepath.Join(filepath.Dir(root), "existing-config")
	os.WriteFile(config, []byte("unchanged"), 0600)
	for i := 0; i < 31; i++ {
		q := p
		q.OperationID = fmt.Sprintf("%032x", i+1)
		if err = StoreSetupProposal(root, stage, q); err != nil {
			t.Fatal(err)
		}
	}
	var wg sync.WaitGroup
	var admitted atomic.Int32
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			q := p
			q.OperationID = fmt.Sprintf("%032x", i+100)
			if StoreSetupProposal(root, stage, q) == nil {
				admitted.Add(1)
			}
		}(i)
	}
	wg.Wait()
	if admitted.Load() != 1 {
		t.Fatal("inventory admitted", admitted.Load())
	}
	listed, err := ListSetupProposals(root)
	if err != nil || len(listed) != 32 {
		t.Fatal(len(listed), err)
	}
	existing, _ := os.ReadFile(config)
	if string(existing) != "unchanged" {
		t.Fatal("proposal applied configuration")
	}
	q := p
	q.PackageSHA256 = strings.Repeat("0", 64)
	if StoreSetupProposal(privateRoot(t), stage, q) == nil {
		t.Fatal("changed staged package accepted")
	}
	alias := filepath.Join(dir, "other")
	os.Rename(file, alias)
	os.Symlink(alias, file)
	if StoreSetupProposal(privateRoot(t), stage, p) == nil {
		t.Fatal("symlink staged package accepted")
	}
}

func TestActualSetupTransportPublishesPendingOnlyAndObservationIsReadOnly(t *testing.T) {
	root, err := os.MkdirTemp("", "fst-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	path := filepath.Join(root, "farm.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	p := SetupProposal{Version: 1, OperationID: strings.Repeat("a", 32), StageOperationID: strings.Repeat("b", 32), PackageSHA256: strings.Repeat("c", 64), Owner: "dinglebear-ai", Repository: "labby", MemoryMiB: 12288, VCPUs: 2, RunnerCount: 1}
	done := make(chan error, 1)
	go func() {
		for _, action := range []string{"remote-setup-propose", "remote-setup-list"} {
			c, e := listener.Accept()
			if e != nil {
				done <- e
				return
			}
			c.SetDeadline(time.Now().Add(3 * time.Second))
			var r map[string]string
			e = json.NewDecoder(c).Decode(&r)
			if e != nil || r["action"] != action {
				c.Close()
				done <- fmt.Errorf("unexpected mutation: %v", r)
				return
			}
			var data any = p
			if action == "remote-setup-list" {
				if len(r) != 1 {
					c.Close()
					done <- fmt.Errorf("observation had write payload")
					return
				}
				data = []SetupProposal{p}
			} else {
				var received SetupProposal
				if json.Unmarshal([]byte(r["value"]), &received) != nil || received != p {
					c.Close()
					done <- fmt.Errorf("proposal changed")
					return
				}
			}
			e = json.NewEncoder(c).Encode(map[string]any{"ok": true, "data": data})
			c.Close()
			if e != nil {
				done <- e
				return
			}
		}
		done <- nil
	}()
	source := strings.TrimSuffix(strings.TrimPrefix(remoteSetupCommand, "python3 -c '"), "'")
	source = strings.ReplaceAll(source, "/run/unraid-core/plugin-data/ci-runner-farm/backend.sock", path)
	source = strings.ReplaceAll(source, "os.geteuid()!=0", "os.geteuid()!="+strconv.Itoa(os.Geteuid()))
	for _, observe := range []bool{false, true} {
		header, _ := json.Marshal(map[string]any{"proposal": p, "observe": observe})
		ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
		cmd := exec.CommandContext(ctx, "python3", "-c", source)
		cmd.Stdin = bytes.NewReader(append(header, '\n'))
		out, e := cmd.CombinedOutput()
		cancel()
		if e != nil {
			t.Fatalf("%s %v", out, e)
		}
		var received SetupProposal
		if json.Unmarshal(out, &received) != nil || received != p {
			t.Fatal(string(out))
		}
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
}
