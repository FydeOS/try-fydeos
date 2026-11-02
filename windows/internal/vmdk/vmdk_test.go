package vmdk

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const fixtureBytes = 8 << 20

func golden(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("testdata/raw.sha256")
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

func decodeToRaw(t *testing.T, r io.Reader) (Info, string) {
	t.Helper()
	raw := make([]byte, fixtureBytes)
	info, err := Decode(r, func(off int64, data []byte) error {
		if off < 0 || off+int64(len(data)) > int64(len(raw)) {
			t.Fatalf("grain at %d+%d outside the disk", off, len(data))
		}
		copy(raw[off:], data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if info.Capacity != fixtureBytes || info.GrainBytes != 64<<10 {
		t.Fatalf("info = %+v", info)
	}
	sum := sha256.Sum256(raw)
	return info, hex.EncodeToString(sum[:])
}

func decodeErr(b []byte) error {
	_, err := Decode(bytes.NewReader(b), func(int64, []byte) error { return nil })
	return err
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestDecodeStream(t *testing.T) {
	info, sum := decodeToRaw(t, bytes.NewReader(readFixture(t, "stream.vmdk")))
	if sum != golden(t) {
		t.Errorf("sha256 = %s, want %s", sum, golden(t))
	}
	if !info.Compressed || info.CreateType != "streamOptimized" {
		t.Errorf("info = %+v", info)
	}
}

func TestDecodeSparse(t *testing.T) {
	f, err := os.Open("testdata/sparse.vmdk.gz")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	info, sum := decodeToRaw(t, zr)
	if sum != golden(t) {
		t.Errorf("sha256 = %s, want %s", sum, golden(t))
	}
	if info.Compressed || info.CreateType != "monolithicSparse" {
		t.Errorf("info = %+v", info)
	}
}

func TestContainers(t *testing.T) {
	for _, tc := range []struct{ path, disk string }{
		{"testdata/test.ova", "stream.vmdk"},
		{"testdata/test.zip", "dir.vmwarevm/sparse.vmdk"},
	} {
		disk, err := FindDisk(tc.path)
		if err != nil || disk != tc.disk {
			t.Fatalf("FindDisk(%s) = %q, %v; want %q", tc.path, disk, err, tc.disk)
		}
		rc, size, err := OpenMember(tc.path, disk)
		if err != nil {
			t.Fatal(err)
		}
		_, sum := decodeToRaw(t, rc)
		if err := rc.Close(); err != nil {
			t.Fatal(err)
		}
		if sum != golden(t) {
			t.Errorf("%s: sha256 = %s, want %s", tc.path, sum, golden(t))
		}
		if size <= 0 {
			t.Errorf("%s: size = %d", tc.path, size)
		}
	}
}

func TestOpenMemberMissing(t *testing.T) {
	for _, p := range []string{"testdata/test.ova", "testdata/test.zip"} {
		if _, _, err := OpenMember(p, "nope.vmdk"); err == nil {
			t.Errorf("%s: missing member opened", p)
		}
	}
	if _, _, err := OpenMember("testdata/stream.vmdk", "stream.vmdk"); err == nil {
		t.Error("non-container opened")
	}
}

func TestBadMagic(t *testing.T) {
	b := readFixture(t, "stream.vmdk")
	b[0] ^= 0xff
	if err := decodeErr(b); err == nil || !strings.Contains(err.Error(), "magic") {
		t.Errorf("err = %v", err)
	}
}

func TestUnsupportedFlags(t *testing.T) {
	b := readFixture(t, "stream.vmdk")
	binary.LittleEndian.PutUint32(b[8:], 1<<16)
	if err := decodeErr(b); err == nil || !strings.Contains(err.Error(), "flags 0x10000") {
		t.Errorf("err = %v", err)
	}
}

func TestTruncated(t *testing.T) {
	b := readFixture(t, "stream.vmdk")
	for _, n := range []int{100, 600, 128*512 + 100, 132 * 512} {
		if err := decodeErr(b[:n]); err == nil {
			t.Errorf("stream cut at %d decoded", n)
		}
	}
	zr, err := gzip.NewReader(bytes.NewReader(readFixture(t, "sparse.vmdk.gz")))
	if err != nil {
		t.Fatal(err)
	}
	sparse, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []int{1000, 128 * 512, len(sparse) - 100} {
		if err := decodeErr(sparse[:n]); err == nil {
			t.Errorf("sparse cut at %d decoded", n)
		}
	}
}

func craftStream(t *testing.T, lba uint64, payload []byte) []byte {
	t.Helper()
	le := binary.LittleEndian
	h := make([]byte, 512)
	le.PutUint32(h[0:], magic)
	le.PutUint32(h[4:], 3)
	le.PutUint32(h[8:], flagCompressed|flagMarkers)
	le.PutUint64(h[12:], 256)
	le.PutUint64(h[20:], 128)
	le.PutUint32(h[44:], 512)
	le.PutUint64(h[64:], 1)
	var z bytes.Buffer
	zw := zlib.NewWriter(&z)
	zw.Write(payload)
	zw.Close()
	m := make([]byte, (12+z.Len()+511)/512*512)
	le.PutUint64(m[0:], lba)
	le.PutUint32(m[8:], uint32(z.Len()))
	copy(m[12:], z.Bytes())
	out := append(h, m...)
	return append(out, make([]byte, 512)...)
}

func TestStreamGrainChecks(t *testing.T) {
	grain := bytes.Repeat([]byte{7}, 64<<10)
	if err := decodeErr(craftStream(t, 128, grain)); err != nil {
		t.Fatalf("valid crafted stream: %v", err)
	}
	if err := decodeErr(craftStream(t, 256, grain)); err == nil || !strings.Contains(err.Error(), "beyond capacity") {
		t.Errorf("grain beyond capacity: err = %v", err)
	}
	if err := decodeErr(craftStream(t, 200, grain)); err == nil {
		t.Error("grain straddling capacity decoded")
	}
	if err := decodeErr(craftStream(t, 0, append(grain, 1))); err == nil {
		t.Error("oversized grain decoded")
	}
	if err := decodeErr(craftStream(t, 0, grain[:1000])); err == nil {
		t.Error("short grain decoded")
	}
	b := craftStream(t, 0, grain)
	if err := decodeErr(b[:len(b)-512]); err == nil {
		t.Error("stream without end-of-stream marker decoded")
	}
}

func hashFile(t *testing.T, p string) string {
	t.Helper()
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.CopyBuffer(h, f, make([]byte, 4<<20)); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// TestCrossCheck compares Decode against a qemu-img conversion:
// TRY_FYDEOS_VMDK_CROSSCHECK=<container>:<member>:<rawfile>.
func TestCrossCheck(t *testing.T) {
	spec := os.Getenv("TRY_FYDEOS_VMDK_CROSSCHECK")
	if spec == "" {
		t.Skip("TRY_FYDEOS_VMDK_CROSSCHECK not set")
	}
	parts := strings.SplitN(spec, ":", 3)
	if len(parts) != 3 {
		t.Fatalf("TRY_FYDEOS_VMDK_CROSSCHECK=%q, want <container>:<member>:<rawfile>", spec)
	}
	rc, _, err := OpenMember(parts[0], parts[1])
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	out, err := os.Create(filepath.Join(t.TempDir(), "disk.raw"))
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	start := time.Now()
	var written, skipped int
	info, err := Decode(rc, func(off int64, data []byte) error {
		for _, c := range data {
			if c != 0 {
				written++
				_, err := out.WriteAt(data, off)
				return err
			}
		}
		skipped++
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := out.Truncate(info.Capacity); err != nil {
		t.Fatal(err)
	}
	t.Logf("decoded %+v in %v: %d grains written, %d all-zero grains skipped", info, time.Since(start), written, skipped)
	start = time.Now()
	got, want := hashFile(t, out.Name()), hashFile(t, parts[2])
	t.Logf("hashed in %v", time.Since(start))
	if got != want {
		t.Fatalf("sha256 = %s, want %s (%s)", got, want, parts[2])
	}
	t.Logf("sha256 %s matches", got)
}
