package journal

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestDurableReplayKeepsLatestPhase(t *testing.T) {
	s := Store{Path: filepath.Join(t.TempDir(), "journal.jsonl")}
	base := Entry{ScaleSetID: 7, MessageID: 9, SessionID: "s", Phase: "received",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64)}
	if err := s.Append(base); err != nil {
		t.Fatal(err)
	}
	base.Phase = "committed"
	if err := s.Append(base); err != nil {
		t.Fatal(err)
	}
	got, err := s.Replay()
	if err != nil {
		t.Fatal(err)
	}
	if got[Key{ScaleSetID: 7, MessageID: 9}].Phase != "committed" {
		t.Fatalf("got %s", got[Key{ScaleSetID: 7, MessageID: 9}].Phase)
	}
}
func TestRejectsUnknownPhase(t *testing.T) {
	e := Entry{ScaleSetID: 1, Phase: "invented"}
	if e.Validate() == nil {
		t.Fatal("accepted unknown phase")
	}
}

func TestReplaySeparatesIdenticalMessageIDsAcrossScaleSets(t *testing.T) {
	s := Store{Path: filepath.Join(t.TempDir(), "journal.jsonl")}
	for _, entry := range []Entry{
		{ScaleSetID: 7, MessageID: 9, SessionID: "one", Phase: "acked",
			ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64)},
		{ScaleSetID: 8, MessageID: 9, SessionID: "two", Phase: "committed",
			ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64)},
	} {
		if err := s.Append(entry); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.Replay()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[Key{ScaleSetID: 7, MessageID: 9}].Phase != "acked" ||
		got[Key{ScaleSetID: 8, MessageID: 9}].Phase != "committed" {
		t.Fatalf("cross-scale-set replay collision: %#v", got)
	}
}

func TestRewriteAtomicallyCompactsAndPreservesMode(t *testing.T) {
	s := Store{Path: filepath.Join(t.TempDir(), "journal.jsonl")}
	entries := []Entry{
		{ScaleSetID: 8, MessageID: 12, SessionID: "two", Phase: "acked",
			ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64)},
		{ScaleSetID: 7, MessageID: 11, SessionID: "one", Phase: "committed",
			AcquiredHandles: []int64{501},
			ConfigRevision:  strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64)},
	}
	if err := s.Rewrite(entries); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(s.Path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("journal mode: info=%v err=%v", info, err)
	}
	got, err := s.Replay()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 ||
		!slices.Equal(got[Key{ScaleSetID: 7, MessageID: 11}].AcquiredHandles, []int64{501}) {
		t.Fatalf("compacted replay mismatch: %#v", got)
	}
}

func TestEntryRejectsDuplicateOrOversizedHandles(t *testing.T) {
	base := Entry{ScaleSetID: 7, MessageID: 9, SessionID: "s", Phase: "acked",
		ConfigRevision: strings.Repeat("a", 64), OwnershipRevision: strings.Repeat("b", 64)}
	base.AcquiredHandles = []int64{501, 501}
	if base.Validate() == nil {
		t.Fatal("duplicate acquired handle was accepted")
	}
	base.AcquiredHandles = nil
	base.SessionID = strings.Repeat("x", MaxEntryBytes)
	if base.Validate() == nil {
		t.Fatal("oversized journal entry was accepted")
	}
}
