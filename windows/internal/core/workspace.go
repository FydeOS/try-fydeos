package core

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"tryfydeos.io/windows/internal/vmdk"
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

// workReserve is the free space kept for converting the image and for the
// guest's first writes; a variable so that tests do not depend on the host.
var workReserve int64 = 10 << 30

// Prepare converts the disk of container (.ova or .zip) into a sparse disk of
// spec.DiskBytes and copies the vars template; record is stored in the
// metadata with the image's length. Idempotent: a prepared workspace is left
// alone and container may be empty.
func (w *Workspace) Prepare(lock *StorageLock, spec *FactorySpec, container string, record FactoryRecord, varsTemplate string,
	progress func(done, total int64)) (*Metadata, error) {
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
	if container == "" {
		return nil, errors.New("prepare needs the FydeOS image")
	}
	for _, p := range []string{w.MetadataFile(), w.Disk(), w.EFIVars(), w.stagingDisk()} {
		os.Remove(p)
	}
	if _, free, err := VolumeInfo(w.Dir); err != nil {
		return nil, err
	} else if free < workReserve {
		return nil, fmt.Errorf("not enough free space: %.1f GB needed, %.1f GB available", float64(workReserve)/1e9, float64(free)/1e9)
	}
	if err := copyFile(varsTemplate, w.EFIVars()); err != nil {
		return nil, err
	}
	raw, err := convertSparse(container, w.stagingDisk(), spec.DiskBytes, progress)
	if err != nil {
		os.Remove(w.stagingDisk())
		return nil, err
	}
	if err := os.Rename(w.stagingDisk(), w.Disk()); err != nil {
		return nil, err
	}
	if err := os.Truncate(w.Disk(), spec.DiskBytes); err != nil {
		return nil, err
	}
	record.RawBytes = raw
	m := &Metadata{
		Schema:    1,
		Factory:   record,
		DiskBytes: spec.DiskBytes,
		MAC:       RandomMAC(),
		Created:   UTCTimestamp(time.Now()),
	}
	if err := writeJSON(w.MetadataFile(), m); err != nil {
		return nil, err
	}
	return m, nil
}

type countingReader struct {
	r io.Reader
	n int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

// convertSparse decodes the container's VMDK into a file marked sparse,
// skipping all-zero grains, and cuts it to the FydeOS image inside: the disk
// is the image followed by zeros, and the image ends with its GPT's
// alternate header. Returns that length.
func convertSparse(container, output string, diskBytes int64, progress func(done, total int64)) (int64, error) {
	disk, err := vmdk.FindDisk(container)
	if err != nil {
		return 0, err
	}
	rc, size, err := vmdk.OpenMember(container, disk)
	if err != nil {
		return 0, err
	}
	defer rc.Close()
	out, err := os.OpenFile(output, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, err
	}
	defer out.Close()
	if err := setSparse(out); err != nil {
		return 0, fmt.Errorf("marking %s sparse: %w", output, err)
	}
	in := &countingReader{r: rc}
	var zero []byte
	var end int64
	lastStep := int64(-1)
	info, err := vmdk.Decode(in, func(off int64, data []byte) error {
		if len(zero) < len(data) {
			zero = make([]byte, len(data))
		}
		if !bytes.Equal(data, zero[:len(data)]) {
			if _, err := out.WriteAt(data, off); err != nil {
				return err
			}
			last := len(data)
			for data[last-1] == 0 {
				last--
			}
			end = max(end, off+int64(last))
		}
		if progress != nil && size > 0 && in.n*100/size != lastStep {
			lastStep = in.n * 100 / size
			progress(min(in.n, size), size)
		}
		return nil
	})
	if err != nil {
		return 0, fmt.Errorf("converting %s: %s: %w", container, disk, err)
	}
	header := make([]byte, 512)
	if _, err := out.ReadAt(header, 512); err != nil || string(header[:8]) != "EFI PART" {
		return 0, fmt.Errorf("%s: no GPT on the disk", container)
	}
	raw := (int64(binary.LittleEndian.Uint64(header[32:])) + 1) * 512
	switch {
	case raw <= 0 || raw > info.Capacity:
		return 0, fmt.Errorf("%s: the GPT ends at %d, outside the %d-byte disk", container, raw, info.Capacity)
	case end > raw:
		return 0, fmt.Errorf("%s: foreign image: data beyond the GPT (at %d, the GPT ends at %d)", container, end, raw)
	case raw > diskBytes:
		return 0, fmt.Errorf("%s: the image is %d bytes, more than the %d-byte VM disk", container, raw, diskBytes)
	}
	if err := out.Truncate(raw); err != nil {
		return 0, err
	}
	if progress != nil && size > 0 {
		progress(size, size)
	}
	return raw, out.Close()
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
