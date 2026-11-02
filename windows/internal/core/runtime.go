package core

import (
	"archive/zip"
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"tryfydeos.io/windows/internal/payload"
)

const runtimeComplete = ".complete"

func (l *Locations) RuntimeExtracted() bool {
	_, err := os.Stat(filepath.Join(l.Runtime, runtimeComplete))
	return err == nil
}

// EnsureRuntime extracts the payload's runtime.zip into l.Runtime unless a
// complete extraction is there; false when there was nothing to do.
func (l *Locations) EnsureRuntime() (bool, error) {
	if !l.RuntimeFromPayload() || l.RuntimeExtracted() {
		return false, nil
	}
	r, e, err := l.Payload.Verified(payload.RuntimeEntry)
	if err != nil {
		return false, err
	}
	// Read the archive through the hash check before trusting its directory.
	data := bytes.NewBuffer(make([]byte, 0, e.Length))
	if _, err := io.Copy(data, r); err != nil {
		return false, err
	}
	zr, err := zip.NewReader(bytes.NewReader(data.Bytes()), int64(data.Len()))
	if err != nil {
		return false, fmt.Errorf("%s: %w", payload.RuntimeEntry, err)
	}
	tmp := fmt.Sprintf("%s.extracting-%d", l.Runtime, os.Getpid())
	os.RemoveAll(tmp)
	if err := extractZip(zr, tmp); err != nil {
		os.RemoveAll(tmp)
		return false, err
	}
	if err := os.WriteFile(filepath.Join(tmp, runtimeComplete), nil, 0o600); err != nil {
		os.RemoveAll(tmp)
		return false, err
	}
	if !l.RuntimeExtracted() {
		os.RemoveAll(l.Runtime)
	}
	// A virus scanner still reading the fresh files makes the rename fail for a while.
	err = os.Rename(tmp, l.Runtime)
	for i := 0; err != nil && i < 20 && !l.RuntimeExtracted(); i++ {
		time.Sleep(250 * time.Millisecond)
		err = os.Rename(tmp, l.Runtime)
	}
	if err != nil {
		os.RemoveAll(tmp)
		if l.RuntimeExtracted() {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func extractZip(zr *zip.Reader, dir string) error {
	for _, f := range zr.File {
		if !filepath.IsLocal(f.Name) {
			return fmt.Errorf("%s: unsafe path %q", payload.RuntimeEntry, f.Name)
		}
		path := filepath.Join(dir, filepath.FromSlash(f.Name))
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(path, 0o700); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return err
		}
		if err := extractFile(f, path); err != nil {
			return err
		}
	}
	return nil
}

func extractFile(f *zip.File, path string) error {
	in, err := f.Open()
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o700)
	if err != nil {
		return err
	}
	// archive/zip checks each file's CRC-32 at EOF.
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return fmt.Errorf("%s: %s: %w", payload.RuntimeEntry, f.Name, err)
	}
	return out.Close()
}

// PrepareStage names the slow steps of preparing a workspace.
type PrepareStage int

const (
	StageDownloading PrepareStage = iota + 1
	StageConverting
)

// PrepareWorkspace extracts the runtime if needed and prepares ws from the
// FydeOS image, downloading it first if needed; say gets one line per slow step.
func (l *Locations) PrepareWorkspace(ws *Workspace, lock *StorageLock, say func(string),
	progress func(stage PrepareStage, done, total int64)) (*Metadata, *FactorySpec, error) {
	start := time.Now()
	if done, err := l.EnsureRuntime(); err != nil {
		return nil, nil, fmt.Errorf("extracting the runtime into %s: %w", l.Runtime, err)
	} else if done {
		say(fmt.Sprintf("runtime extracted into %s in %.1f s", l.Runtime, time.Since(start).Seconds()))
	}
	spec, err := l.LoadSpec()
	if err != nil {
		return nil, nil, err
	}
	if ws.IsPrepared() {
		m, err := ws.Prepare(lock, spec, "", FactoryRecord{}, "", nil)
		return m, spec, err
	}
	stage := func(s PrepareStage) func(done, total int64) {
		if progress == nil {
			return nil
		}
		return func(done, total int64) { progress(s, done, total) }
	}
	container, record, err := l.FactoryContainer(context.Background(), spec, say, stage(StageDownloading))
	if err != nil {
		return nil, nil, err
	}
	say(fmt.Sprintf("converting %s into %s", container, ws.Disk()))
	start = time.Now()
	m, err := ws.Prepare(lock, spec, container, record, l.VarsTemplate(), stage(StageConverting))
	if err != nil {
		return nil, nil, err
	}
	say(fmt.Sprintf("converted in %.1f s (FydeOS image %d bytes)", time.Since(start).Seconds(), m.Factory.RawBytes))
	return m, spec, nil
}
