package core

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func testContent() ([]byte, string) {
	data := bytes.Repeat([]byte("FydeOS image "), 400000)
	sum := sha256.Sum256(data)
	return data, hex.EncodeToString(sum[:])
}

// imageServer serves data with Range support; abortFirst cuts the first
// answer after half the bytes, ignoreRange answers every request in full.
type imageServer struct {
	data                    []byte
	abortFirst, ignoreRange bool
	mu                      sync.Mutex
	ranges                  []string
}

func (s *imageServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.ranges = append(s.ranges, r.Header.Get("Range"))
	first := len(s.ranges) == 1
	s.mu.Unlock()
	if s.abortFirst && first {
		w.Header().Set("Content-Length", strconv.Itoa(len(s.data)))
		w.Write(s.data[:len(s.data)/2])
		w.(http.Flusher).Flush()
		panic(http.ErrAbortHandler)
	}
	if s.ignoreRange {
		r.Header.Del("Range")
	}
	http.ServeContent(w, r, "image.ova", time.Time{}, bytes.NewReader(s.data))
}

func serveImage(t *testing.T, s *imageServer) string {
	srv := httptest.NewServer(s)
	t.Cleanup(srv.Close)
	return srv.URL + "/image.ova"
}

func checkDownloaded(t *testing.T, dest string, data []byte) {
	t.Helper()
	got, err := os.ReadFile(dest)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("%s differs from the served image: %v", dest, err)
	}
	if _, err := os.Stat(dest + ".part"); err == nil {
		t.Fatal("part left behind")
	}
}

func TestDownloadFull(t *testing.T) {
	data, sum := testContent()
	url := serveImage(t, &imageServer{data: data})
	dest := filepath.Join(t.TempDir(), "images", "image.ova")
	var calls int
	var last [2]int64
	if err := Download(context.Background(), url, int64(len(data)), sum, dest, func(done, total int64) {
		calls++
		last = [2]int64{done, total}
	}); err != nil {
		t.Fatal(err)
	}
	checkDownloaded(t, dest, data)
	if calls < 2 || calls > 101 || last != [2]int64{int64(len(data)), int64(len(data))} {
		t.Fatalf("progress calls %d, last %v", calls, last)
	}
	if n, err := RemoteSize(context.Background(), url); err != nil || n != int64(len(data)) {
		t.Fatalf("RemoteSize = %d, %v", n, err)
	}
}

func TestDownloadResumes(t *testing.T) {
	data, sum := testContent()
	s := &imageServer{data: data, abortFirst: true}
	url := serveImage(t, s)
	dest := filepath.Join(t.TempDir(), "image.ova")
	if err := Download(context.Background(), url, int64(len(data)), sum, dest, nil); err == nil {
		t.Fatal("cut connection: no error")
	}
	st, err := os.Stat(dest + ".part")
	if err != nil || st.Size() == 0 || st.Size() >= int64(len(data)) {
		t.Fatalf("part after the cut: %v %v", st, err)
	}
	if err := Download(context.Background(), url, int64(len(data)), sum, dest, nil); err != nil {
		t.Fatal(err)
	}
	checkDownloaded(t, dest, data)
	if want := sprintf("bytes=%d-", st.Size()); s.ranges[1] != want {
		t.Fatalf("second request Range %q, want %q", s.ranges[1], want)
	}
}

func TestDownloadCompletePart(t *testing.T) {
	data, sum := testContent()
	s := &imageServer{data: data}
	url := serveImage(t, s)
	dest := filepath.Join(t.TempDir(), "image.ova")
	os.WriteFile(dest+".part", data, 0o600)
	if err := Download(context.Background(), url, int64(len(data)), sum, dest, nil); err != nil {
		t.Fatal(err)
	}
	checkDownloaded(t, dest, data)
}

func TestDownloadServerIgnoresRange(t *testing.T) {
	data, sum := testContent()
	s := &imageServer{data: data, ignoreRange: true}
	url := serveImage(t, s)
	dest := filepath.Join(t.TempDir(), "image.ova")
	os.WriteFile(dest+".part", bytes.Repeat([]byte("x"), 1000), 0o600)
	if err := Download(context.Background(), url, int64(len(data)), sum, dest, nil); err != nil {
		t.Fatal(err)
	}
	checkDownloaded(t, dest, data)
	if s.ranges[0] != "bytes=1000-" {
		t.Fatalf("Range %q", s.ranges[0])
	}
}

func TestDownloadHashMismatch(t *testing.T) {
	data, _ := testContent()
	url := serveImage(t, &imageServer{data: data})
	dest := filepath.Join(t.TempDir(), "image.ova")
	err := Download(context.Background(), url, int64(len(data)), strings.Repeat("0", 64), dest, nil)
	if err == nil || !strings.Contains(err.Error(), url) || !strings.Contains(err.Error(), "sha256") {
		t.Fatalf("err = %v", err)
	}
	for _, p := range []string{dest, dest + ".part"} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("%s left behind", p)
		}
	}
	if err := Download(context.Background(), url, int64(len(data))+1, strings.Repeat("0", 64), dest, nil); err == nil {
		t.Fatal("wrong size accepted")
	}
}

func TestFactoryContainerChoosesImage(t *testing.T) {
	pinned, pinnedSum := testContent()
	newer := append([]byte("newer "), pinned...)
	newerSum := sha256.Sum256(newer)
	var mu sync.Mutex
	var api string
	hits := map[string]int{}
	mux := http.NewServeMux()
	srv := httptest.NewTLSServer(mux)
	defer srv.Close()
	mux.HandleFunc("/api", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if api == "" {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte(api))
	})
	for name, data := range map[string][]byte{"/v1/pinned.ova": pinned, "/v2/newer.ova": newer} {
		mux.HandleFunc(name, func(w http.ResponseWriter, r *http.Request) {
			mu.Lock()
			hits[name]++
			mu.Unlock()
			http.ServeContent(w, r, name, time.Time{}, bytes.NewReader(data))
		})
	}
	saved := http.DefaultClient
	http.DefaultClient = srv.Client()
	defer func() { http.DefaultClient = saved }()
	listing := func(sum, file string) string {
		return `{"list":[{"board":"b","version":"9.9","releaseDate":"2026-12-01","fileName":"` + file + `","checksum":"` + sum +
			`","isEOL":false,"downloadUrls":[{"type":"official","url":"` + srv.URL + `/v2/` + file + `"}]}]}`
	}

	spec, _ := testSpec(t)
	spec.Image = FactoryImage{URL: srv.URL + "/v1/pinned.ova", Bytes: int64(len(pinned)), SHA256: pinnedSum, Version: "pinned"}
	spec.Release = ReleaseSource{API: srv.URL + "/api", Board: "b"}
	l := &Locations{AppData: t.TempDir(), AppVersion: "1"}
	say := func(string) {}

	path, rec, err := l.FactoryContainer(context.Background(), spec, say, nil)
	want := FactoryRecord{URL: spec.Image.URL, FileName: "pinned.ova", SHA256: pinnedSum, Version: "pinned"}
	if err != nil || path != filepath.Join(ImageDir(l.AppData), "pinned.ova") || rec != want || hits["/v1/pinned.ova"] != 1 {
		t.Fatalf("API down: %s %+v %v, hits %v", path, rec, err, hits)
	}
	api = listing(pinnedSum, "pinned.ova")
	if path2, rec, err := l.FactoryContainer(context.Background(), spec, say, nil); err != nil || path2 != path || rec != want || hits["/v1/pinned.ova"] != 1 {
		t.Fatalf("API lists the pinned image, already downloaded: %s %+v %v, hits %v", path2, rec, err, hits)
	}

	api = listing(hex.EncodeToString(newerSum[:]), "newer.ova")
	var last int64
	path, rec, err = l.FactoryContainer(context.Background(), spec, say, func(done, total int64) { last = total })
	want = FactoryRecord{URL: srv.URL + "/v2/newer.ova", FileName: "newer.ova", SHA256: hex.EncodeToString(newerSum[:]), Version: "9.9, 2026-12-01"}
	if err != nil || path != filepath.Join(ImageDir(l.AppData), "newer.ova") || rec != want || last != int64(len(newer)) {
		t.Fatalf("API lists a newer image: %s %+v %v, total %d", path, rec, err, last)
	}
	assertImages(t, ImageDir(l.AppData), "newer.ova")

	stray := filepath.Join(ImageDir(l.AppData), "stray.ova")
	if err := os.WriteFile(stray, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	l.FactoryImageOverride = fixture("test.ova")
	if path, rec, err := l.FactoryContainer(context.Background(), spec, say, nil); err != nil || path != l.FactoryImageOverride || rec != (FactoryRecord{FileName: "test.ova"}) {
		t.Fatalf("override: %s %+v %v", path, rec, err)
	}
	assertImages(t, ImageDir(l.AppData), "newer.ova", "stray.ova")
	l.FactoryImageOverride = filepath.Join(t.TempDir(), "missing.ova")
	if _, _, err := l.FactoryContainer(context.Background(), spec, say, nil); err == nil {
		t.Fatal("missing override accepted")
	}
}

func assertImages(t *testing.T, dir string, want ...string) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range entries {
		got = append(got, e.Name())
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("%s holds %v, want %v", dir, got, want)
	}
}

func TestFactoryContainerPrunesImages(t *testing.T) {
	data, sum := testContent()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/pinned.ova" {
			http.NotFound(w, r)
			return
		}
		http.ServeContent(w, r, "pinned.ova", time.Time{}, bytes.NewReader(data))
	}))
	defer srv.Close()
	saved := http.DefaultClient
	http.DefaultClient = srv.Client()
	defer func() { http.DefaultClient = saved }()
	spec, _ := testSpec(t)
	spec.Image = FactoryImage{URL: srv.URL + "/v1/pinned.ova", Bytes: int64(len(data)), SHA256: sum, Version: "pinned"}
	spec.Release = ReleaseSource{API: srv.URL + "/api", Board: "b"}
	l := &Locations{AppData: t.TempDir(), AppVersion: "1"}
	dir := ImageDir(l.AppData)
	if err := os.MkdirAll(filepath.Join(dir, "keep.dir"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"old.ova", "other.zip.part"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("old"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var said []string
	say := func(s string) { said = append(said, s) }

	if _, _, err := l.FactoryContainer(context.Background(), spec, say, nil); err != nil {
		t.Fatal(err)
	}
	assertImages(t, dir, "keep.dir", "pinned.ova")
	if !strings.Contains(strings.Join(said, "\n"), "removed superseded image old.ova") {
		t.Errorf("said %q", said)
	}

	if err := os.WriteFile(filepath.Join(dir, "old.ova"), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := l.FactoryContainer(context.Background(), spec, say, nil); err != nil {
		t.Fatal(err)
	}
	assertImages(t, dir, "keep.dir", "pinned.ova")
}
