// Package payload reads and writes the data appended to "Try FydeOS.exe":
// magic, little-endian u32 index length, index JSON, then the entries, all at
// the PE overlay start. Entry offsets are relative to the overlay start.
package payload

import (
	"bytes"
	"crypto/sha256"
	"debug/pe"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"regexp"
)

const (
	Magic        = "TRYFYDEOS-PAYLOAD-1"
	RuntimeEntry = "runtime.zip"
	ImageEntry   = "image.zst"
	SpecEntry    = "spec.json"

	maxIndex = 1 << 20
)

var ErrNoPayload = errors.New("no payload")

type Entry struct {
	Name   string `json:"name"`
	Offset int64  `json:"offset"`
	Length int64  `json:"length"`
	SHA256 string `json:"sha256"`
}

type index struct {
	Entries []Entry `json:"entries"`
}

type Payload struct {
	Path    string
	Start   int64
	Entries []Entry
	f       *os.File
}

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

// overlay returns where the PE image ends and whether it carries a certificate table.
// The image ends after the last section's raw data (or the COFF symbol and string
// tables of an unstripped build). The Authenticode table is addressed by file
// offset and sits after everything else, so it never moves the overlay start.
func overlay(r io.ReaderAt) (start int64, signed bool, err error) {
	f, err := pe.NewFile(r)
	if err != nil {
		return 0, false, err
	}
	defer f.Close()
	align := int64(1)
	var security pe.DataDirectory
	switch oh := f.OptionalHeader.(type) {
	case *pe.OptionalHeader64:
		align = int64(oh.FileAlignment)
		if oh.NumberOfRvaAndSizes > pe.IMAGE_DIRECTORY_ENTRY_SECURITY {
			security = oh.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_SECURITY]
		}
	case *pe.OptionalHeader32:
		align = int64(oh.FileAlignment)
		if oh.NumberOfRvaAndSizes > pe.IMAGE_DIRECTORY_ENTRY_SECURITY {
			security = oh.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_SECURITY]
		}
	}
	for _, s := range f.Sections {
		if s.Size > 0 {
			start = max(start, int64(s.Offset)+int64(s.Size))
		}
	}
	if p := int64(f.FileHeader.PointerToSymbolTable); p != 0 {
		end := p + int64(f.FileHeader.NumberOfSymbols)*pe.COFFSymbolSize
		var n [4]byte
		if _, err := r.ReadAt(n[:], end); err == nil {
			end += int64(binary.LittleEndian.Uint32(n[:]))
		}
		start = max(start, end)
	}
	if align > 1 {
		start = (start + align - 1) / align * align
	}
	return start, security.Size != 0, nil
}

// Open reads the index of the payload appended to exe. It returns ErrNoPayload
// for a file that is not a PE image or carries no payload (a development build).
func Open(exe string) (*Payload, error) {
	f, err := os.Open(exe)
	if err != nil {
		return nil, err
	}
	p, err := read(f, exe)
	if err != nil {
		f.Close()
		return nil, err
	}
	return p, nil
}

func read(f *os.File, path string) (*Payload, error) {
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	start, _, err := overlay(f)
	if err != nil {
		return nil, ErrNoPayload
	}
	head := make([]byte, len(Magic)+4)
	if _, err := f.ReadAt(head, start); err != nil || string(head[:len(Magic)]) != Magic {
		return nil, ErrNoPayload
	}
	n := int64(binary.LittleEndian.Uint32(head[len(Magic):]))
	dataStart := int64(len(head)) + n
	if n == 0 || n > maxIndex || start+dataStart > st.Size() {
		return nil, fmt.Errorf("%s: payload index length %d is corrupt", path, n)
	}
	raw := make([]byte, n)
	if _, err := f.ReadAt(raw, start+int64(len(head))); err != nil {
		return nil, fmt.Errorf("%s: reading payload index: %w", path, err)
	}
	var ix index
	if err := json.Unmarshal(raw, &ix); err != nil {
		return nil, fmt.Errorf("%s: payload index: %w", path, err)
	}
	seen := map[string]bool{}
	for _, e := range ix.Entries {
		if e.Name == "" || seen[e.Name] || !hex64.MatchString(e.SHA256) || e.Offset < dataStart || e.Length < 0 ||
			start+e.Offset+e.Length > st.Size() {
			return nil, fmt.Errorf("%s: payload entry %q is corrupt or truncated", path, e.Name)
		}
		seen[e.Name] = true
	}
	return &Payload{Path: path, Start: start, Entries: ix.Entries, f: f}, nil
}

func (p *Payload) Close() error { return p.f.Close() }

func (p *Payload) Lookup(name string) (Entry, bool) {
	for _, e := range p.Entries {
		if e.Name == name {
			return e, true
		}
	}
	return Entry{}, false
}

// Entry returns the raw bytes of an entry; Verified also checks them.
func (p *Payload) Entry(name string) (*io.SectionReader, Entry, error) {
	e, ok := p.Lookup(name)
	if !ok {
		return nil, e, fmt.Errorf("%s: payload has no %s", p.Path, name)
	}
	return io.NewSectionReader(p.f, p.Start+e.Offset, e.Length), e, nil
}

func (p *Payload) Verified(name string) (io.Reader, Entry, error) {
	r, e, err := p.Entry(name)
	if err != nil {
		return nil, e, err
	}
	return NewVerifier(r, name, e.Length, e.SHA256), e, nil
}

// ReadAll returns a small entry, verified.
func (p *Payload) ReadAll(name string) ([]byte, error) {
	r, _, err := p.Verified(name)
	if err != nil {
		return nil, err
	}
	return io.ReadAll(r)
}

type verifier struct {
	r      io.Reader
	h      hash.Hash
	name   string
	n      int64
	length int64
	sha256 string
}

// NewVerifier passes r through and, instead of io.EOF, returns an error if
// the bytes read differ from length and sha256.
func NewVerifier(r io.Reader, name string, length int64, sha256Hex string) io.Reader {
	return &verifier{r: r, h: sha256.New(), name: name, length: length, sha256: sha256Hex}
}

func (v *verifier) Read(b []byte) (int, error) {
	n, err := v.r.Read(b)
	v.h.Write(b[:n])
	v.n += int64(n)
	if err == io.EOF {
		if v.n != v.length {
			return n, fmt.Errorf("%s: %d bytes, expected %d", v.name, v.n, v.length)
		}
		if got := hex.EncodeToString(v.h.Sum(nil)); got != v.sha256 {
			return n, fmt.Errorf("%s: sha256 %s, expected %s", v.name, got, v.sha256)
		}
	}
	return n, err
}

// File is an entry to append; a non-empty SHA256 must match the file's content.
type File struct {
	Name   string
	Path   string
	SHA256 string
}

// Append writes outPath: exePath followed by a payload of files.
func Append(exePath, outPath string, files []File) ([]Entry, error) {
	exe, err := os.ReadFile(exePath)
	if err != nil {
		return nil, err
	}
	start, signed, err := overlay(bytes.NewReader(exe))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", exePath, err)
	}
	if signed {
		return nil, fmt.Errorf("%s has a certificate table; append the payload before signing", exePath)
	}
	if start != int64(len(exe)) {
		return nil, fmt.Errorf("%s has %d bytes after its PE image (an existing payload?)", exePath, int64(len(exe))-start)
	}
	entries := make([]Entry, len(files))
	for i, file := range files {
		f, err := os.Open(file.Path)
		if err != nil {
			return nil, err
		}
		h := sha256.New()
		n, err := io.Copy(h, f)
		f.Close()
		if err != nil {
			return nil, err
		}
		entries[i] = Entry{Name: file.Name, Length: n, SHA256: hex.EncodeToString(h.Sum(nil))}
		if file.SHA256 != "" && file.SHA256 != entries[i].SHA256 {
			return nil, fmt.Errorf("%s: sha256 %s, expected %s", file.Path, entries[i].SHA256, file.SHA256)
		}
	}
	// Offsets depend on the index length and vice versa; a few rounds settle it.
	var raw []byte
	for size := -1; size != len(raw); {
		size = len(raw)
		off := int64(len(Magic) + 4 + size)
		for i := range entries {
			entries[i].Offset = off
			off += entries[i].Length
		}
		if raw, err = json.Marshal(index{entries}); err != nil {
			return nil, err
		}
	}

	tmp := outPath + ".tmp"
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return nil, err
	}
	err = func() error {
		head := binary.LittleEndian.AppendUint32([]byte(Magic), uint32(len(raw)))
		for _, b := range [][]byte{exe, head, raw} {
			if _, err := out.Write(b); err != nil {
				return err
			}
		}
		for i, file := range files {
			f, err := os.Open(file.Path)
			if err != nil {
				return err
			}
			_, err = io.Copy(out, NewVerifier(f, file.Path, entries[i].Length, entries[i].SHA256))
			f.Close()
			if err != nil {
				return err
			}
		}
		return out.Close()
	}()
	if err != nil {
		out.Close()
		os.Remove(tmp)
		return nil, err
	}
	return entries, os.Rename(tmp, outPath)
}
