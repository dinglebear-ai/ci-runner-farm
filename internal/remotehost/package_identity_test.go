package remotehost

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

func packageIdentityProjection(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	view, err := InspectPackage(raw)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err = json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"treeSHA256", "backendSHA256"} {
		value, ok := fields[key].(string)
		if !ok || !referenceDigest.MatchString(value) {
			t.Fatalf("missing observed package identity %s: %v", key, fields)
		}
	}
	return fields
}

func rewriteIdentityArchive(t *testing.T, raw []byte, reverse, changeMode, addFile bool) []byte {
	t.Helper()
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()
	reader := tar.NewReader(gz)
	type entry struct {
		header tar.Header
		body   []byte
	}
	var entries []entry
	for {
		h, e := reader.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			t.Fatal(e)
		}
		b, e := io.ReadAll(reader)
		if e != nil {
			t.Fatal(e)
		}
		copy := *h
		if changeMode && strings.Contains(h.Name, "observer") {
			copy.Mode = 0755
		}
		entries = append(entries, entry{copy, b})
	}
	if addFile {
		entries = append(entries, entry{tar.Header{Name: "README.md", Mode: 0644, Size: 7, Typeflag: tar.TypeReg}, []byte("changed")})
	}
	var out bytes.Buffer
	compress := gzip.NewWriter(&out)
	writer := tar.NewWriter(compress)
	for i := range entries {
		index := i
		if reverse {
			index = len(entries) - 1 - i
		}
		e := entries[index]
		if err = writer.WriteHeader(&e.header); err != nil {
			t.Fatal(err)
		}
		if _, err = writer.Write(e.body); err != nil {
			t.Fatal(err)
		}
	}
	if err = writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err = compress.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func TestPackageIdentityBindsWholeInstalledTreeAndHelper(t *testing.T) {
	raw := fixturePackage(t, "ci-runner-farm")
	original := packageIdentityProjection(t, raw)
	reordered := packageIdentityProjection(t, rewriteIdentityArchive(t, raw, true, false, false))
	if original["treeSHA256"] != reordered["treeSHA256"] {
		t.Fatal("archive order changed the installed-tree identity")
	}
	for _, changed := range [][]byte{rewriteIdentityArchive(t, raw, false, true, false), rewriteIdentityArchive(t, raw, false, false, true)} {
		view := packageIdentityProjection(t, changed)
		if view["treeSHA256"] == original["treeSHA256"] {
			t.Fatal("helper executable mode or non-helper source change retained installed-tree identity")
		}
		if view["backendSHA256"] != original["backendSHA256"] {
			t.Fatal("unmodified running backend identity changed")
		}
	}
}

func TestPackageTreeV1CrossLanguageGolden(t *testing.T) {
	hashes := map[string]string{}
	for name, body := range map[string][]byte{"VERSION": []byte("0.1.0-test\n"), "vendor/farm-backend": {0, 1, 2, 'r', 'u', 'n', 'n', 'e', 'r'}} {
		digest := sha256.Sum256(body)
		hashes[name] = hex.EncodeToString(digest[:])
	}
	if got := packageTreeDigest(hashes, map[string]bool{"vendor/farm-backend": true}); got != "595e07cc11f10acdcde96e0fa13d5664c28b7f2ad0ca59205fec8962e27c90c0" {
		t.Fatal(got)
	}
}
