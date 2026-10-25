package localchecks

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestFleetPackBridgeVerifiesExistingCoordinatorManifest(t *testing.T) {
	root := t.TempDir()
	files := map[string]PackArtifact{}
	for _, name := range []string{"history.pack", "snapshots.pack"} {
		data := []byte("fixture-" + name)
		if err := os.WriteFile(filepath.Join(root, name), data, 0600); err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(data)
		files[name] = PackArtifact{Bytes: uint64(len(data)), SHA256: hex.EncodeToString(digest[:])}
	}
	s := submission()
	manifest := FleetSnapshot{Commit: s.Commit, Base: s.Base, MergeBase: s.Base, Files: files}
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeFleetSnapshot(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if err := got.VerifyPacks(context.Background(), root); err != nil {
		t.Fatal(err)
	}
	canonical, err := got.CanonicalBytes()
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(canonical)
	if got.Digest() != hex.EncodeToString(digest[:]) {
		t.Fatal("canonical digest differs")
	}
	if err := os.WriteFile(filepath.Join(root, "history.pack"), []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := got.VerifyPacks(context.Background(), root); err == nil {
		t.Fatal("accepted changed transfer")
	}
}
func TestFleetPackBridgeRejectsUnexpectedOrUnsafeArtifacts(t *testing.T) {
	s := submission()
	for _, files := range []map[string]PackArtifact{{"../history.pack": {Bytes: 1, SHA256: s.BundleSHA256}}, {"history.pack": {Bytes: 1, SHA256: s.BundleSHA256}}, {"history.pack": {Bytes: 1 << 30, SHA256: s.BundleSHA256}, "snapshots.pack": {Bytes: 1, SHA256: s.BundleSHA256}}} {
		raw, _ := json.Marshal(FleetSnapshot{Commit: s.Commit, Base: s.Base, MergeBase: s.Base, Files: files})
		if _, err := DecodeFleetSnapshot(bytes.NewReader(raw)); err == nil {
			t.Fatal("accepted unsafe manifest")
		}
	}
}
