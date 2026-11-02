package core

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const fixtureRawBytes = 8<<20 - 32<<10

func init() { workReserve = 0 }

func fixture(name string) string { return filepath.Join("..", "vmdk", "testdata", name) }

// testSpec returns a spec for the vmdk fixtures and a vars template.
func testSpec(t *testing.T) (*FactorySpec, string) {
	spec := &FactorySpec{Schema: 2, DiskBytes: 64 << 20, Board: "test",
		Image:   FactoryImage{URL: "https://example.invalid/test.ova", Bytes: 1, SHA256: strings.Repeat("ab", 32), Version: "test 1"},
		Release: ReleaseSource{API: "https://example.invalid/api", Board: "test"}}
	vars := filepath.Join(t.TempDir(), "vars.fd")
	os.WriteFile(vars, []byte("vars"), 0o600)
	return spec, vars
}

func fixtureDiskSHA256(t *testing.T) string {
	b, err := os.ReadFile(fixture("raw.sha256"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

func TestPrepareConvertsSparseAndIsIdempotent(t *testing.T) {
	for _, container := range []string{fixture("test.ova"), fixture("test.zip")} {
		spec, vars := testSpec(t)
		ws := &Workspace{Dir: filepath.Join(t.TempDir(), "VM", "v1")}
		lock, err := ws.Open()
		if err != nil {
			t.Fatal(err)
		}
		var calls int
		var last [2]int64
		record := FactoryRecord{URL: spec.Image.URL, FileName: "test.ova", SHA256: spec.Image.SHA256, Version: "test 1"}
		m, err := ws.Prepare(lock, spec, container, record, vars, func(done, total int64) { calls++; last = [2]int64{done, total} })
		if err != nil {
			t.Fatalf("%s: %v", container, err)
		}
		record.RawBytes = fixtureRawBytes
		if calls == 0 || last[0] != last[1] || last[1] <= 0 || m.DiskBytes != spec.DiskBytes || m.Factory != record {
			t.Fatalf("%s: metadata %+v, progress calls %d, last %v", container, m, calls, last)
		}
		st, err := os.Stat(ws.Disk())
		if err != nil || st.Size() != spec.DiskBytes {
			t.Fatalf("disk %v %v", st, err)
		}
		data, _ := os.ReadFile(ws.Disk())
		sum := sha256.Sum256(data[:16<<20])
		if hex.EncodeToString(sum[:]) != fixtureDiskSHA256(t) || !bytes.Equal(data[16<<20:], make([]byte, len(data)-16<<20)) {
			t.Fatalf("%s: disk content differs from the fixture", container)
		}
		if v, _ := os.ReadFile(ws.EFIVars()); string(v) != "vars" {
			t.Fatalf("vars %q", v)
		}
		if allocated := diskAllocated(t, ws.Disk()); allocated >= 4<<20 {
			t.Fatalf("disk not sparse: %d bytes allocated", allocated)
		}
		before, _ := os.ReadFile(ws.MetadataFile())
		m2, err := ws.Prepare(lock, spec, "", FactoryRecord{}, "/nonexistent", nil)
		after, _ := os.ReadFile(ws.MetadataFile())
		if err != nil || m2.MAC != m.MAC || !bytes.Equal(before, after) {
			t.Fatalf("second prepare changed something: %v", err)
		}

		_, run, err := ws.NewRunDirectory(time.Now())
		if err != nil {
			t.Fatal(err)
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
		if _, err := os.Stat(run); err != nil {
			t.Fatalf("reset removed the runs: %v", err)
		}
		lock.Release()
	}
}

func TestPrepareRejects(t *testing.T) {
	for name, tc := range map[string]struct {
		container string
		diskBytes int64
		want      string
	}{
		"data beyond the GPT": {fixture("beyond.ova"), 64 << 20, "data beyond the GPT"},
		"disk too small":      {fixture("test.ova"), fixtureRawBytes - 512, "more than the"},
		"not a container":     {fixture("stream.vmdk"), 64 << 20, "unsupported container"},
		"no free space":       {fixture("test.ova"), 64 << 20, "not enough free space"},
	} {
		if name == "no free space" {
			workReserve = 1 << 62
		}
		spec, vars := testSpec(t)
		spec.DiskBytes = tc.diskBytes
		ws := &Workspace{Dir: t.TempDir()}
		lock, err := ws.Open()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := ws.Prepare(lock, spec, tc.container, FactoryRecord{}, vars, nil); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v", name, err)
		}
		workReserve = 0
		if ws.IsPrepared() {
			t.Errorf("%s: prepared", name)
		}
		for _, p := range []string{ws.Disk(), ws.stagingDisk()} {
			if _, err := os.Stat(p); err == nil {
				t.Errorf("%s: %s left behind", name, p)
			}
		}
		lock.Release()
	}
}

// TestPrepareCrossCheck converts a real image and compares the installed
// disk with a qemu-img conversion of the same container over the image's
// length: TRY_FYDEOS_PREPARE_CROSSCHECK=<container>:<rawfile>. Set TMPDIR
// to a disk with room for the converted image.
func TestPrepareCrossCheck(t *testing.T) {
	env := os.Getenv("TRY_FYDEOS_PREPARE_CROSSCHECK")
	if env == "" {
		t.Skip("TRY_FYDEOS_PREPARE_CROSSCHECK not set")
	}
	container, rawFile, ok := strings.Cut(env, ":")
	if !ok {
		t.Fatalf("TRY_FYDEOS_PREPARE_CROSSCHECK=%q, want <container>:<rawfile>", env)
	}
	spec, vars := testSpec(t)
	spec.DiskBytes = 64 << 30
	ws := &Workspace{Dir: t.TempDir()}
	lock, err := ws.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Release()
	start := time.Now()
	m, err := ws.Prepare(lock, spec, container, FactoryRecord{}, vars, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("prepared in %v: FydeOS image %d bytes, %d bytes allocated", time.Since(start), m.Factory.RawBytes, diskAllocated(t, ws.Disk()))
	start = time.Now()
	prefix := func(p string) string {
		f, err := os.Open(p)
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		h := sha256.New()
		if n, err := io.CopyBuffer(h, io.LimitReader(f, m.Factory.RawBytes), make([]byte, 4<<20)); err != nil || n != m.Factory.RawBytes {
			t.Fatalf("%s: read %d of %d bytes: %v", p, n, m.Factory.RawBytes, err)
		}
		return hex.EncodeToString(h.Sum(nil))
	}
	got, want := prefix(ws.Disk()), prefix(rawFile)
	t.Logf("hashed in %v", time.Since(start))
	if got != want {
		t.Fatalf("sha256 of the first %d bytes = %s, want %s (%s)", m.Factory.RawBytes, got, want, rawFile)
	}
	t.Logf("sha256 of the first %d bytes %s matches", m.Factory.RawBytes, got)
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
