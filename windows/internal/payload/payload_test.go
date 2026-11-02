package payload

import (
	"bytes"
	"crypto/sha256"
	"debug/pe"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tryfydeos.io/windows/internal/payload/payloadtest"
)

func fakePE(t *testing.T, dir string) string {
	path := filepath.Join(dir, "app.exe")
	if err := os.WriteFile(path, payloadtest.FakePE(), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func writeFile(t *testing.T, dir, name string, data []byte) string {
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func sum(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func packed(t *testing.T) (string, map[string][]byte) {
	dir := t.TempDir()
	exe := fakePE(t, dir)
	content := map[string][]byte{
		RuntimeEntry: bytes.Repeat([]byte("runtime"), 1000),
		SpecEntry:    []byte(`{"schema":2}`),
	}
	var files []File
	for _, name := range []string{RuntimeEntry, SpecEntry} {
		files = append(files, File{Name: name, Path: writeFile(t, dir, name, content[name])})
	}
	files[0].SHA256 = sum(content[RuntimeEntry])
	out := filepath.Join(dir, "out.exe")
	if _, err := Append(exe, out, files); err != nil {
		t.Fatal(err)
	}
	return out, content
}

func TestRoundTrip(t *testing.T) {
	out, content := packed(t)
	p, err := Open(out)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if p.Start != payloadtest.ImageEnd || len(p.Entries) != 2 {
		t.Fatalf("start %#x entries %+v", p.Start, p.Entries)
	}
	for name, want := range content {
		got, err := p.ReadAll(name)
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("%s: %v", name, err)
		}
		r, e, err := p.Entry(name)
		if err != nil || e.Length != int64(len(want)) || e.SHA256 != sum(want) || r.Size() != e.Length {
			t.Fatalf("%s entry %+v %v", name, e, err)
		}
	}
	if _, _, err := p.Entry("missing"); err == nil {
		t.Fatal("found a missing entry")
	}
	if _, err := Append(out, out+"2", nil); err == nil || !strings.Contains(err.Error(), "after its PE image") {
		t.Fatalf("appended twice: %v", err)
	}
}

func TestSignedAfterPayload(t *testing.T) {
	out, content := packed(t)
	data, _ := os.ReadFile(out)
	// Authenticode appends its table at the end and points the security directory at it.
	dirOffset := payloadtest.OptionalHeaderOffset + 112 + 8*pe.IMAGE_DIRECTORY_ENTRY_SECURITY
	binary.LittleEndian.PutUint32(data[dirOffset:], uint32(len(data)))
	binary.LittleEndian.PutUint32(data[dirOffset+4:], 16)
	data = append(data, bytes.Repeat([]byte{0xee}, 16)...)
	os.WriteFile(out, data, 0o755)
	p, err := Open(out)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if got, err := p.ReadAll(SpecEntry); err != nil || !bytes.Equal(got, content[SpecEntry]) {
		t.Fatalf("spec after signing: %q %v", got, err)
	}
	if _, err := Append(out, out+"2", nil); err == nil || !strings.Contains(err.Error(), "certificate table") {
		t.Fatalf("appended to a signed exe: %v", err)
	}
}

func TestNoPayload(t *testing.T) {
	dir := t.TempDir()
	if _, err := Open(fakePE(t, dir)); !errors.Is(err, ErrNoPayload) {
		t.Fatalf("plain exe: %v", err)
	}
	if _, err := Open(writeFile(t, dir, "text", []byte("not a PE"))); !errors.Is(err, ErrNoPayload) {
		t.Fatalf("text file: %v", err)
	}
	if _, err := Open(filepath.Join(dir, "missing.exe")); err == nil || errors.Is(err, ErrNoPayload) {
		t.Fatalf("missing file: %v", err)
	}
}

func TestCorrupt(t *testing.T) {
	out, _ := packed(t)
	good, _ := os.ReadFile(out)
	start := payloadtest.ImageEnd
	n := int(binary.LittleEndian.Uint32(good[start+len(Magic):]))
	for name, mutate := range map[string]func([]byte) []byte{
		"truncated":    func(b []byte) []byte { return b[:len(b)-1] },
		"index length": func(b []byte) []byte { binary.LittleEndian.PutUint32(b[start+len(Magic):], 1<<30); return b },
		"index json":   func(b []byte) []byte { b[start+len(Magic)+4] = '['; return b },
		"short index":  func(b []byte) []byte { return b[:start+len(Magic)+4+n/2] },
	} {
		data := mutate(bytes.Clone(good))
		os.WriteFile(out, data, 0o755)
		if p, err := Open(out); err == nil || errors.Is(err, ErrNoPayload) {
			if p != nil {
				p.Close()
			}
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestHashMismatch(t *testing.T) {
	out, _ := packed(t)
	data, _ := os.ReadFile(out)
	data[len(data)-1] ^= 0xff
	os.WriteFile(out, data, 0o755)
	p, err := Open(out)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if _, err := p.ReadAll(SpecEntry); err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Fatalf("corrupt entry read: %v", err)
	}
	r := NewVerifier(strings.NewReader("abc"), "x", 4, sum([]byte("abc")))
	if _, err := io.ReadAll(r); err == nil || !strings.Contains(err.Error(), "expected 4") {
		t.Fatalf("short read: %v", err)
	}
	dir := t.TempDir()
	if _, err := Append(fakePE(t, dir), filepath.Join(dir, "o.exe"),
		[]File{{Name: "a", Path: writeFile(t, dir, "a", []byte("a")), SHA256: sum([]byte("b"))}}); err == nil {
		t.Fatal("appended a file whose hash differs from the expected one")
	}
}
