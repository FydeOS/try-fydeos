package core

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

// testImage writes a zstd image with data, a run of zero blocks and a short tail.
func testImage(t *testing.T) (string, *FactorySpec, []byte) {
	raw := bytes.Repeat([]byte("FydeOS"), 300000)
	raw = append(raw, make([]byte, 5*unpackBlock+123)...)
	raw = append(raw, []byte("tail")...)
	dir := t.TempDir()
	image := filepath.Join(dir, "image.bin.zst")
	f, _ := os.Create(image)
	enc, _ := zstd.NewWriter(f)
	enc.Write(raw)
	enc.Close()
	f.Close()
	sum := sha256.Sum256(raw)
	st, _ := os.Stat(image)
	spec := &FactorySpec{Schema: 1, DiskBytes: 64 << 20, Board: "test", Image: FactoryImage{
		File: "image.bin.zst", Bytes: st.Size(), SHA256: hex.EncodeToString(sum[:]),
		RawBytes: int64(len(raw)), RawSHA256: hex.EncodeToString(sum[:]), Version: "test 1",
	}}
	vars := filepath.Join(dir, "vars.fd")
	os.WriteFile(vars, []byte("vars"), 0o600)
	return image, spec, raw
}

func TestPrepareUnpacksSparseAndIsIdempotent(t *testing.T) {
	image, spec, raw := testImage(t)
	vars := filepath.Join(filepath.Dir(image), "vars.fd")
	ws := &Workspace{Dir: filepath.Join(t.TempDir(), "VM", "v1")}
	lock, err := ws.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Release()
	var calls int
	m, err := ws.Prepare(lock, spec, image, vars, func(w, total int64) { calls++ })
	if err != nil {
		t.Fatal(err)
	}
	if calls == 0 || m.DiskBytes != spec.DiskBytes || m.Factory.SHA256 != spec.Image.SHA256 || m.Factory.Version != "test 1" {
		t.Fatalf("metadata %+v, progress calls %d", m, calls)
	}
	st, err := os.Stat(ws.Disk())
	if err != nil || st.Size() != spec.DiskBytes {
		t.Fatalf("disk %v %v", st, err)
	}
	data, _ := os.ReadFile(ws.Disk())
	if !bytes.Equal(data[:len(raw)], raw) || !bytes.Equal(data[len(raw):], make([]byte, len(data)-len(raw))) {
		t.Fatal("disk content differs from the image")
	}
	if v, _ := os.ReadFile(ws.EFIVars()); string(v) != "vars" {
		t.Fatalf("vars %q", v)
	}
	if allocated := diskAllocated(t, ws.Disk()); allocated >= 4<<20 {
		t.Fatalf("disk not sparse: %d bytes allocated", allocated)
	}
	before, _ := os.ReadFile(ws.MetadataFile())
	m2, err := ws.Prepare(lock, spec, "/nonexistent", "/nonexistent", nil)
	after, _ := os.ReadFile(ws.MetadataFile())
	if err != nil || m2.MAC != m.MAC || !bytes.Equal(before, after) {
		t.Fatalf("second prepare changed something: %v", err)
	}

	if err := ws.Reset(lock); err != nil {
		t.Fatal(err)
	}
	if ws.IsPrepared() {
		t.Fatal("prepared after reset")
	}
	if s, _ := ws.State(); s != WorkspaceMarked {
		t.Fatalf("state after reset %v", s)
	}
}

func TestPrepareRejectsWrongSize(t *testing.T) {
	image, spec, _ := testImage(t)
	vars := filepath.Join(filepath.Dir(image), "vars.fd")
	for _, delta := range []int64{-1, 1} {
		s := *spec
		s.Image.RawBytes += delta
		ws := &Workspace{Dir: t.TempDir()}
		lock, err := ws.Open()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := ws.Prepare(lock, &s, image, vars, nil); err == nil {
			t.Errorf("delta %d: accepted", delta)
		}
		if _, err := os.Stat(ws.Disk()); err == nil {
			t.Errorf("delta %d: disk left behind", delta)
		}
		if _, err := os.Stat(ws.stagingDisk()); err == nil {
			t.Errorf("delta %d: staging disk left behind", delta)
		}
		lock.Release()
	}
}

func TestOpenRefusesForeignAndLocks(t *testing.T) {
	foreign := t.TempDir()
	os.WriteFile(filepath.Join(foreign, "notes.txt"), nil, 0o600)
	if _, err := (&Workspace{Dir: foreign}).Open(); err == nil {
		t.Fatal("opened a foreign directory")
	}
	wrongMarker := t.TempDir()
	os.WriteFile(filepath.Join(wrongMarker, MarkerName), []byte("other\n"), 0o600)
	if _, err := (&Workspace{Dir: wrongMarker}).Open(); err == nil {
		t.Fatal("opened a directory with a foreign marker")
	}

	ws := &Workspace{Dir: t.TempDir()}
	lock, err := ws.Open()
	if err != nil {
		t.Fatal(err)
	}
	if !ws.IsLocked() {
		t.Fatal("lock not visible")
	}
	var busy *LockBusyError
	if _, err := ws.Open(); !errors.As(err, &busy) {
		t.Fatalf("second open: %v", err)
	}
	lock.Release()
	if ws.IsLocked() {
		t.Fatal("lock still held after release")
	}
	if _, err := os.Stat(ws.LockFile()); err != nil {
		t.Fatal("lock file removed")
	}
}

func TestRunDirectoriesAndRecords(t *testing.T) {
	ws := &Workspace{Dir: t.TempDir()}
	t0 := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	for i, at := range []time.Time{t0, t0.Add(time.Hour)} {
		id, dir, err := ws.NewRunDirectory(at)
		if err != nil {
			t.Fatal(err)
		}
		code := i
		WriteRunRecord(&RunRecord{ID: id, Start: UTCTimestamp(at), ExitCode: &code, Reason: "guest-shutdown"}, dir)
	}
	if _, _, err := ws.NewRunDirectory(t0); err == nil {
		t.Fatal("reused a run directory")
	}
	_, r, err := ws.LastRun()
	if err != nil || r.ID != "20261027T130000Z" || *r.ExitCode != 1 {
		t.Fatalf("last run %+v %v", r, err)
	}
}
