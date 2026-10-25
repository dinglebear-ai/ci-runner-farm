package remotehost

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func fixturePackage(t *testing.T, id string) []byte {
	t.Helper()
	body := []byte("fixture-native-helper")
	sum := sha256.Sum256(body)
	m, _ := json.Marshal(map[string]any{"id": id, "version": "0.1.0-test", "native": map[string]any{"helpers": []map[string]string{{"id": "backend", "path": "vendor/farm-backend", "sha256": hex.EncodeToString(sum[:])}, {"id": "observer", "path": "vendor/farm-observer", "sha256": hex.EncodeToString(sum[:])}}}})
	var out bytes.Buffer
	gz := gzip.NewWriter(&out)
	tw := tar.NewWriter(gz)
	for name, b := range map[string][]byte{"manifest.json": m, "vendor/farm-backend": body, "vendor/farm-observer": body} {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0600, Size: int64(len(b)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		tw.Write(b)
	}
	tw.Close()
	gz.Close()
	return out.Bytes()
}
func TestPackageUploadIsActorOwnedImmutableAndFarmOnly(t *testing.T) {
	root := privateRoot(t)
	raw := fixturePackage(t, "ci-runner-farm")
	view, err := StorePackage(root, "core-alice", raw)
	if err != nil {
		t.Fatal(err)
	}
	listed, listErr := ListPackages(root, "core-alice")
	if listErr != nil || len(listed) != 1 || listed[0] != view {
		t.Fatal(listed, listErr)
	}
	if view.Bytes != int64(len(raw)) || view.Version != "0.1.0-test" {
		t.Fatal(view)
	}
	path, _, err := LoadPackage(root, "core-alice", view.SHA256)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(path) != view.SHA256+".tgz" {
		t.Fatal(path)
	}
	if _, _, err = LoadPackage(root, "core-bob", view.SHA256); err == nil {
		t.Fatal("cross actor artifact")
	}
	if _, err = StorePackage(root, "core-alice", fixturePackage(t, "other-plugin")); err == nil {
		t.Fatal("other plugin accepted")
	}
	if err = os.WriteFile(path, []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err = LoadPackage(root, "core-alice", view.SHA256); err == nil {
		t.Fatal("changed package accepted")
	}
}
func TestPackageRejectsTraversalAndHelperMismatch(t *testing.T) {
	raw := fixturePackage(t, "ci-runner-farm")
	if _, err := InspectPackage(raw); err != nil {
		t.Fatal(err)
	}
	if _, err := InspectPackage(append(raw, make([]byte, maxPackageBytes+1)...)); err == nil {
		t.Fatal("oversized package")
	}
	var out bytes.Buffer
	gz := gzip.NewWriter(&out)
	tw := tar.NewWriter(gz)
	tw.WriteHeader(&tar.Header{Name: "../outside", Mode: 0600, Size: 1, Typeflag: tar.TypeReg})
	tw.Write([]byte("x"))
	tw.Close()
	gz.Close()
	if _, err := InspectPackage(out.Bytes()); err == nil {
		t.Fatal("traversal package accepted")
	}
}

func TestPackageRejectsChangedHelperBytes(t *testing.T) {
	raw := fixturePackage(t, "ci-runner-farm")
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()
	reader := tar.NewReader(gz)
	var out bytes.Buffer
	compressed := gzip.NewWriter(&out)
	writer := tar.NewWriter(compressed)
	for {
		h, e := reader.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			t.Fatal(e)
		}
		body, e := io.ReadAll(reader)
		if e != nil {
			t.Fatal(e)
		}
		if h.Name == "vendor/farm-backend" {
			body[0] ^= 1
		}
		writer.WriteHeader(h)
		writer.Write(body)
	}
	writer.Close()
	compressed.Close()
	if _, err = InspectPackage(out.Bytes()); err == nil {
		t.Fatal("changed helper bytes accepted")
	}
}
