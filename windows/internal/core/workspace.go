package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"

	"tryfydeos.io/windows/internal/payload"
)

type Metadata struct {
	Schema    int           `json:"schema"`
	Factory   FactoryRecord `json:"factory"`
	DiskBytes int64         `json:"diskBytes"`
	MAC       string        `json:"mac"`
	Created   string        `json:"created"`
}

type RunRecord struct {
	ID            string   `json:"id"`
	Argv          []string `json:"argv"`
	SupervisorPid int      `json:"supervisorPid"`
	Pid           int      `json:"pid,omitempty"`
	Start         string   `json:"start"`
	QMPReady      string   `json:"qmpReady,omitempty"`
	End           string   `json:"end,omitempty"`
	ExitCode      *int     `json:"exitCode,omitempty"`
	Reason        string   `json:"reason,omitempty"`
	// ShutdownRequest is why the supervisor ran the shutdown ladder, empty if it never did.
	ShutdownRequest string `json:"shutdownRequest,omitempty"`
}

type WorkspaceState int

const (
	WorkspaceAbsent WorkspaceState = iota
	WorkspaceEmpty
	WorkspaceMarked
	WorkspaceForeign
)

func UTCTimestamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

const (
	MarkerName    = ".try-fydeos"
	MarkerContent = "try-fydeos-vm 1\n"
)

type Workspace struct{ Dir string }

func (w *Workspace) path(name string) string { return filepath.Join(w.Dir, name) }
func (w *Workspace) Marker() string          { return w.path(MarkerName) }
func (w *Workspace) LockFile() string        { return w.path(".lock") }
func (w *Workspace) Disk() string            { return w.path("disk.raw") }
func (w *Workspace) stagingDisk() string     { return w.path(".disk.raw.preparing") }
func (w *Workspace) EFIVars() string         { return w.path("efi-vars.fd") }
func (w *Workspace) MetadataFile() string    { return w.path("metadata.json") }
func (w *Workspace) QMPSocket() string       { return w.path("qmp.sock") }
func (w *Workspace) ControlSocket() string   { return w.path("control.sock") }
func (w *Workspace) RunsDir() string         { return w.path("runs") }

// State says whether the directory is ours; why explains a foreign one.
func (w *Workspace) State() (state WorkspaceState, why string) {
	st, err := os.Stat(w.Dir)
	if err != nil {
		return WorkspaceAbsent, ""
	}
	if !st.IsDir() {
		return WorkspaceForeign, "not a directory"
	}
	if text, err := os.ReadFile(w.Marker()); err == nil {
		if string(text) == MarkerContent {
			return WorkspaceMarked, ""
		}
		return WorkspaceForeign, fmt.Sprintf("marker %s has unknown content %q", MarkerName, text)
	}
	entries, err := os.ReadDir(w.Dir)
	if err != nil {
		return WorkspaceForeign, err.Error()
	}
	for _, e := range entries {
		if e.Name() != ".lock" {
			return WorkspaceForeign, "non-empty directory without a " + MarkerName + " marker"
		}
	}
	return WorkspaceEmpty, ""
}

func (w *Workspace) IsPrepared() bool {
	for _, p := range []string{w.MetadataFile(), w.Disk(), w.EFIVars()} {
		if _, err := os.Stat(p); err != nil {
			return false
		}
	}
	return true
}

func (w *Workspace) IsLocked() bool { return LockHeld(w.LockFile()) }

// Open takes the storage lock, creating and marking the directory if it is new.
// requireFS lists the acceptable filesystems; empty skips the check.
func (w *Workspace) Open(requireFS ...string) (*StorageLock, error) {
	if s, why := w.State(); s == WorkspaceForeign {
		return nil, fmt.Errorf("refusing to use %s: %s", w.Dir, why)
	}
	if err := os.MkdirAll(w.Dir, 0o700); err != nil {
		return nil, err
	}
	if len(requireFS) > 0 {
		fs, _, err := VolumeInfo(w.Dir)
		if err != nil {
			return nil, fmt.Errorf("filesystem of %s: %w", w.Dir, err)
		}
		ok := false
		for _, want := range requireFS {
			ok = ok || strings.EqualFold(fs, want)
		}
		if !ok {
			return nil, fmt.Errorf("%s is on %s, not %s; the sparse VM disk needs one of them", w.Dir, fs, strings.Join(requireFS, " or "))
		}
	}
	lock, err := AcquireLock(w.LockFile())
	if err != nil {
		return nil, err
	}
	switch s, why := w.State(); s {
	case WorkspaceForeign:
		lock.Release()
		return nil, fmt.Errorf("refusing to use %s: %s", w.Dir, why)
	case WorkspaceAbsent, WorkspaceEmpty:
		if err := os.WriteFile(w.Marker(), []byte(MarkerContent), 0o600); err != nil {
			lock.Release()
			return nil, err
		}
	}
	return lock, nil
}

func (w *Workspace) LoadMetadata() (*Metadata, error) {
	data, err := os.ReadFile(w.MetadataFile())
	if err != nil {
		return nil, err
	}
	var m Metadata
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("%s: %w", w.MetadataFile(), err)
	}
	return &m, nil
}

// Prepare unpacks the zstd factory image into a sparse disk of spec.DiskBytes
// and copies the vars template. Idempotent: a prepared workspace is left alone
// and image may be nil.
func (w *Workspace) Prepare(lock *StorageLock, spec *FactorySpec, image *ImageSource, varsTemplate string,
	progress func(written, total int64)) (*Metadata, error) {
	if lock == nil || lock.Path != w.LockFile() {
		return nil, errors.New("prepare needs the workspace lock")
	}
	if w.IsPrepared() {
		m, err := w.LoadMetadata()
		if err != nil {
			return nil, fmt.Errorf("refusing to use %s: metadata.json is unreadable (%v); inspect it or run 'tryfydeos reset --yes'", w.Dir, err)
		}
		return m, nil
	}
	if image == nil {
		return nil, errors.New("prepare needs the factory image")
	}
	for _, p := range []string{w.MetadataFile(), w.Disk(), w.EFIVars(), w.stagingDisk()} {
		os.Remove(p)
	}
	raw := spec.Image.RawBytes
	if _, free, err := VolumeInfo(w.Dir); err != nil {
		return nil, err
	} else if free < raw+(1<<30) {
		return nil, fmt.Errorf("not enough free space: %.1f GB needed, %.1f GB available", float64(raw+(1<<30))/1e9, float64(free)/1e9)
	}
	if err := copyFile(varsTemplate, w.EFIVars()); err != nil {
		return nil, err
	}
	in := payload.NewVerifier(image, image.Name, spec.Image.Bytes, spec.Image.SHA256)
	if err := unpackSparse(in, image.Name, w.stagingDisk(), raw, progress); err != nil {
		os.Remove(w.stagingDisk())
		return nil, err
	}
	if err := os.Rename(w.stagingDisk(), w.Disk()); err != nil {
		return nil, err
	}
	if err := os.Truncate(w.Disk(), spec.DiskBytes); err != nil {
		return nil, err
	}
	m := &Metadata{
		Schema:    1,
		Factory:   FactoryRecord{File: spec.Image.File, SHA256: spec.Image.SHA256, RawBytes: raw, Version: spec.Image.Version},
		DiskBytes: spec.DiskBytes,
		MAC:       RandomMAC(),
		Created:   UTCTimestamp(time.Now()),
	}
	if err := writeJSON(w.MetadataFile(), m); err != nil {
		return nil, err
	}
	return m, nil
}

const unpackBlock = 1 << 20

// unpackSparse decompresses into a file marked sparse and seeks over all-zero
// blocks, so the disk occupies only its data. The decoder checks the frame
// checksums; the size check catches a truncated or foreign image. in is read
// to its end so that a verifying reader gets to report a mismatch.
func unpackSparse(in io.Reader, image, output string, rawBytes int64, progress func(int64, int64)) error {
	dec, err := zstd.NewReader(in, zstd.WithDecoderConcurrency(1))
	if err != nil {
		return err
	}
	defer dec.Close()
	out, err := os.OpenFile(output, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer out.Close()
	if err := setSparse(out); err != nil {
		return fmt.Errorf("marking %s sparse: %w", output, err)
	}
	buf := make([]byte, unpackBlock)
	zero := make([]byte, unpackBlock)
	var off int64
	lastStep := int64(-1)
	for {
		n, err := io.ReadFull(dec, buf)
		if n > 0 {
			if off+int64(n) > rawBytes {
				return fmt.Errorf("%s unpacks to more than %d bytes, the size the spec gives", image, rawBytes)
			}
			if !bytes.Equal(buf[:n], zero[:n]) {
				if _, werr := out.WriteAt(buf[:n], off); werr != nil {
					return werr
				}
			}
			off += int64(n)
			if progress != nil && off*10/rawBytes != lastStep {
				lastStep = off * 10 / rawBytes
				progress(off, rawBytes)
			}
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			break
		}
		if err != nil {
			return fmt.Errorf("unpacking %s: %w", image, err)
		}
	}
	if off != rawBytes {
		return fmt.Errorf("%s unpacked to %d bytes, spec says %d", image, off, rawBytes)
	}
	if _, err := io.Copy(io.Discard, in); err != nil {
		return err
	}
	if err := out.Truncate(off); err != nil {
		return err
	}
	return out.Close()
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// Reset deletes the VM's disk, variables and metadata. Never touches runs\, the marker, the lock or the directory.
func (w *Workspace) Reset(lock *StorageLock) error {
	if lock == nil || lock.Path != w.LockFile() {
		return errors.New("reset needs the workspace lock")
	}
	for _, p := range []string{w.Disk(), w.EFIVars(), w.MetadataFile()} {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func (w *Workspace) NewRunDirectory(now time.Time) (string, string, error) {
	id := now.UTC().Format("20060102T150405Z")
	dir := filepath.Join(w.RunsDir(), id)
	if err := os.MkdirAll(w.RunsDir(), 0o700); err != nil {
		return "", "", err
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		return "", "", err
	}
	return id, dir, nil
}

// LastRun returns the newest run directory (ids sort by time) and its record.
func (w *Workspace) LastRun() (string, *RunRecord, error) {
	entries, err := os.ReadDir(w.RunsDir())
	if err != nil {
		return "", nil, err
	}
	var ids []string
	for _, e := range entries {
		if e.IsDir() {
			ids = append(ids, e.Name())
		}
	}
	if len(ids) == 0 {
		return "", nil, os.ErrNotExist
	}
	sort.Strings(ids)
	dir := filepath.Join(w.RunsDir(), ids[len(ids)-1])
	data, err := os.ReadFile(filepath.Join(dir, "run.json"))
	if err != nil {
		return dir, nil, err
	}
	var r RunRecord
	if err := json.Unmarshal(data, &r); err != nil {
		return dir, nil, err
	}
	return dir, &r, nil
}

func WriteRunRecord(r *RunRecord, dir string) error {
	return writeJSON(filepath.Join(dir, "run.json"), r)
}
