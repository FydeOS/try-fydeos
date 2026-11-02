package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ImageDir keeps the downloaded FydeOS images.
func ImageDir(appData string) string { return filepath.Join(appData, "images") }

// contentRange parses "bytes first-last/total" or "bytes */total"; first is -1 for the latter.
func contentRange(h string) (first, total int64, err error) {
	spec, ok := strings.CutPrefix(h, "bytes ")
	rng, size, ok2 := strings.Cut(spec, "/")
	if !ok || !ok2 {
		return 0, 0, fmt.Errorf("malformed Content-Range %q", h)
	}
	if total, err = strconv.ParseInt(size, 10, 64); err != nil {
		return 0, 0, fmt.Errorf("malformed Content-Range %q", h)
	}
	if rng == "*" {
		return -1, total, nil
	}
	start, _, _ := strings.Cut(rng, "-")
	if first, err = strconv.ParseInt(start, 10, 64); err != nil {
		return 0, 0, fmt.Errorf("malformed Content-Range %q", h)
	}
	return first, total, nil
}

// RemoteSize asks for the first byte of url and reads the total from the answer's Content-Range.
func RemoteSize(ctx context.Context, url string) (int64, error) {
	ctx, cancel := context.WithTimeout(ctx, releaseTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Range", "bytes=0-0")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusPartialContent:
		_, total, err := contentRange(resp.Header.Get("Content-Range"))
		if err != nil {
			return 0, fmt.Errorf("%s: %w", url, err)
		}
		return total, nil
	case http.StatusOK:
		if resp.ContentLength >= 0 {
			return resp.ContentLength, nil
		}
	}
	return 0, fmt.Errorf("%s: %s, no size", url, resp.Status)
}

// Download fetches url into dest through dest.part, resuming a part left by an
// earlier attempt, and checks the finished file's size and sha256 before the
// rename. A mismatch deletes the part.
func Download(ctx context.Context, url string, size int64, sha256 string, dest string, progress func(done, total int64)) error {
	if size <= 0 {
		return fmt.Errorf("%s: no expected size", url)
	}
	part := dest + ".part"
	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return err
	}
	var have int64
	if st, err := os.Stat(part); err == nil {
		have = st.Size()
	}
	if have > size {
		have = 0
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	if have > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", have))
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		have = 0
		if resp.ContentLength >= 0 && resp.ContentLength != size {
			return fmt.Errorf("%s is %d bytes, expected %d", url, resp.ContentLength, size)
		}
	case http.StatusPartialContent:
		first, total, err := contentRange(resp.Header.Get("Content-Range"))
		if err != nil {
			return fmt.Errorf("%s: %w", url, err)
		}
		if first != have || total != size {
			return fmt.Errorf("%s: asked for bytes %d- of %d, got Content-Range %q", url, have, size, resp.Header.Get("Content-Range"))
		}
	case http.StatusRequestedRangeNotSatisfiable:
		if have != size {
			os.Remove(part)
			return fmt.Errorf("%s: %s for bytes %d- of %d", url, resp.Status, have, size)
		}
	default:
		return fmt.Errorf("%s: %s", url, resp.Status)
	}
	if resp.StatusCode != http.StatusRequestedRangeNotSatisfiable {
		if err := receive(resp.Body, part, have, size, progress); err != nil {
			return fmt.Errorf("downloading %s: %w", url, err)
		}
	}
	got, err := SHA256File(part)
	if err != nil {
		return err
	}
	if got != sha256 {
		os.Remove(part)
		return fmt.Errorf("%s: downloaded sha256 %s, expected %s", url, got, sha256)
	}
	if progress != nil {
		progress(size, size)
	}
	return os.Rename(part, dest)
}

// receive writes body to part from offset have on and reports progress every 1 %.
func receive(body io.Reader, part string, have, size int64, progress func(done, total int64)) error {
	f, err := os.OpenFile(part, os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := f.Truncate(have); err != nil {
		return err
	}
	if _, err := f.Seek(have, io.SeekStart); err != nil {
		return err
	}
	buf := make([]byte, 1<<20)
	done, lastStep := have, int64(-1)
	for {
		n, err := body.Read(buf)
		if n > 0 {
			if done+int64(n) > size {
				return fmt.Errorf("more than the expected %d bytes", size)
			}
			if _, werr := f.Write(buf[:n]); werr != nil {
				return werr
			}
			done += int64(n)
			if progress != nil && done*100/size != lastStep {
				lastStep = done * 100 / size
				progress(done, size)
			}
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
	}
	if done != size {
		return fmt.Errorf("got %d of %d bytes", done, size)
	}
	return f.Close()
}
