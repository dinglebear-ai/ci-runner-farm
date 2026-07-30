package journal

import (
	"path/filepath"
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
	if got[9].Phase != "committed" {
		t.Fatalf("got %s", got[9].Phase)
	}
}
func TestRejectsUnknownPhase(t *testing.T) {
	e := Entry{ScaleSetID: 1, Phase: "invented"}
	if e.Validate() == nil {
		t.Fatal("accepted unknown phase")
	}
}
