package vmdk

import (
	"archive/tar"
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

type readCloser struct {
	io.Reader
	close func() error
}

func (r readCloser) Close() error { return r.close() }

func containerKind(p string) (string, error) {
	switch ext := strings.ToLower(filepath.Ext(p)); ext {
	case ".ova", ".zip":
		return ext, nil
	}
	return "", fmt.Errorf("%s: unsupported container (want .ova or .zip)", p)
}

func tarMembers(f *os.File, each func(h *tar.Header, tr *tar.Reader) (bool, error)) error {
	tr := tar.NewReader(f)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if h.Typeflag != tar.TypeReg {
			continue
		}
		if stop, err := each(h, tr); stop || err != nil {
			return err
		}
	}
}

func members(p string) ([]string, error) {
	kind, err := containerKind(p)
	if err != nil {
		return nil, err
	}
	var names []string
	if kind == ".zip" {
		zr, err := zip.OpenReader(p)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		defer zr.Close()
		for _, zf := range zr.File {
			if !zf.FileInfo().IsDir() {
				names = append(names, zf.Name)
			}
		}
		return names, nil
	}
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	err = tarMembers(f, func(h *tar.Header, _ *tar.Reader) (bool, error) {
		names = append(names, h.Name)
		return false, nil
	})
	if err != nil {
		return nil, fmt.Errorf("%s: %w", p, err)
	}
	return names, nil
}

func checkUnique(p, member string, names []string) error {
	n := 0
	for _, name := range names {
		if name == member {
			n++
		}
	}
	switch n {
	case 0:
		return fmt.Errorf("%s: no member %q", p, member)
	case 1:
		return nil
	}
	return fmt.Errorf("%s: member %q appears %d times", p, member, n)
}

// OpenMember returns a reader for the named file inside an .ova (tar) or .zip
// container, chosen by the path's extension, plus the member's size when the
// container records it. The caller closes it.
func OpenMember(p, member string) (io.ReadCloser, int64, error) {
	names, err := members(p)
	if err != nil {
		return nil, 0, err
	}
	if err := checkUnique(p, member, names); err != nil {
		return nil, 0, err
	}
	if kind, _ := containerKind(p); kind == ".zip" {
		zr, err := zip.OpenReader(p)
		if err != nil {
			return nil, 0, fmt.Errorf("%s: %w", p, err)
		}
		for _, zf := range zr.File {
			if zf.Name != member || zf.FileInfo().IsDir() {
				continue
			}
			rc, err := zf.Open()
			if err != nil {
				zr.Close()
				return nil, 0, fmt.Errorf("%s: %s: %w", p, member, err)
			}
			return readCloser{rc, func() error { return errors.Join(rc.Close(), zr.Close()) }}, int64(zf.UncompressedSize64), nil
		}
		zr.Close()
		return nil, 0, fmt.Errorf("%s: no member %q", p, member)
	}
	f, err := os.Open(p)
	if err != nil {
		return nil, 0, err
	}
	var out io.ReadCloser
	var size int64
	err = tarMembers(f, func(h *tar.Header, tr *tar.Reader) (bool, error) {
		if h.Name != member {
			return false, nil
		}
		out, size = readCloser{tr, f.Close}, h.Size
		return true, nil
	})
	if err == nil && out == nil {
		err = fmt.Errorf("no member %q", member)
	}
	if err != nil {
		f.Close()
		return nil, 0, fmt.Errorf("%s: %w", p, err)
	}
	return out, size, nil
}

// FindDisk returns the name of the single *.vmdk member of a container.
func FindDisk(p string) (string, error) {
	names, err := members(p)
	if err != nil {
		return "", err
	}
	var disks []string
	for _, name := range names {
		if strings.EqualFold(path.Ext(name), ".vmdk") {
			disks = append(disks, name)
		}
	}
	if len(disks) != 1 {
		return "", fmt.Errorf("%s: found %d .vmdk members, want exactly 1", p, len(disks))
	}
	return disks[0], nil
}
