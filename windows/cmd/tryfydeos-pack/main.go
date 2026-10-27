// Command tryfydeos-pack appends the payload (trimmed runtime, factory image,
// spec) to the GUI exe, producing the single-file distribution.
package main

import (
	"archive/zip"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"tryfydeos.io/windows/internal/core"
	"tryfydeos.io/windows/internal/payload"
)

// Firmware for other architectures in bin/share; q35 with -drive if=pflash needs none of it.
var dropShare = []string{"edk2-aarch64*", "edk2-arm*", "edk2-riscv*", "edk2-loongarch*", "openbios-*", "slof.bin",
	"skiboot.lid", "u-boot*", "opensbi-*", "hppa-firmware*", "s390-*", "palcode-*", "pnv-pnor.bin", "qemu-nsis.bmp"}

// keep says whether a runtime file (slash path relative to the runtime root) ships.
func keep(rel string) bool {
	parts := strings.Split(rel, "/")
	switch {
	case len(parts) == 1:
		return rel == "README.txt"
	case parts[0] == "LICENSES" || parts[0] == "provenance":
		return true
	case parts[0] != "bin":
		return false
	case len(parts) == 2:
		return rel == "bin/qemu-system-x86_64w.exe" || strings.HasSuffix(strings.ToLower(rel), ".dll")
	case parts[1] != "share":
		return false
	case len(parts) == 3:
		for _, pattern := range dropShare {
			if ok, _ := path.Match(pattern, parts[2]); ok {
				return false
			}
		}
	}
	return true
}

func buildRuntimeZip(root, out string) (files int, unpacked int64, err error) {
	f, err := os.Create(out)
	if err != nil {
		return 0, 0, err
	}
	zw := zip.NewWriter(f)
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		if !keep(rel) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		h, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}
		h.Name, h.Method = rel, zip.Deflate
		w, err := zw.CreateHeader(h)
		if err != nil {
			return err
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		n, err := io.Copy(w, in)
		files++
		unpacked += n
		return err
	})
	if err == nil {
		err = zw.Close()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return files, unpacked, err
}

func size(p string) int64 {
	st, err := os.Stat(p)
	if err != nil {
		return 0
	}
	return st.Size()
}

func mb(n int64) string { return fmt.Sprintf("%.1f MB", float64(n)/1e6) }

func run(exe, runtimeDir, image, specPath, out string) error {
	spec, err := core.LoadFactorySpec(specPath)
	if err != nil {
		return err
	}
	if n := size(image); n != spec.Image.Bytes {
		return fmt.Errorf("%s is %d bytes, %s says %d", image, n, specPath, spec.Image.Bytes)
	}
	if _, err := os.Stat(filepath.Join(runtimeDir, "bin", core.QEMUNames[0])); err != nil {
		return fmt.Errorf("runtime %s: %w (run make win-runtime)", runtimeDir, err)
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return err
	}
	zipPath := out + ".runtime.zip.tmp"
	defer os.Remove(zipPath)
	files, unpacked, err := buildRuntimeZip(runtimeDir, zipPath)
	if err != nil {
		return err
	}
	fmt.Printf("runtime.zip  %s (%d files, %s unpacked)\n", mb(size(zipPath)), files, mb(unpacked))
	entries, err := payload.Append(exe, out, []payload.File{
		{Name: payload.RuntimeEntry, Path: zipPath},
		{Name: payload.ImageEntry, Path: image, SHA256: spec.Image.SHA256},
		{Name: payload.SpecEntry, Path: specPath},
	})
	if err != nil {
		return err
	}
	fmt.Printf("exe          %s\n", mb(size(exe)))
	for _, e := range entries {
		fmt.Printf("%-12s %s at %d, sha256 %s\n", e.Name, mb(e.Length), e.Offset, e.SHA256)
	}
	sum, err := core.SHA256File(out)
	if err != nil {
		return err
	}
	if err := os.WriteFile(out+".sha256", []byte(sum+"  "+filepath.Base(out)+"\n"), 0o644); err != nil {
		return err
	}
	fmt.Printf("%s  %s, sha256 %s\n", out, mb(size(out)), sum)
	return nil
}

func main() {
	exe := flag.String("exe", "", "built GUI exe (out/win-build/Try FydeOS.exe)")
	runtimeDir := flag.String("runtime", "", "unpacked runtime (out/win-runtime)")
	image := flag.String("image", "", "factory .zst image")
	spec := flag.String("spec", "", "factory spec json")
	out := flag.String("out", "", "output exe")
	flag.Parse()
	if *exe == "" || *runtimeDir == "" || *image == "" || *spec == "" || *out == "" || flag.NArg() != 0 {
		flag.Usage()
		os.Exit(2)
	}
	if err := run(*exe, *runtimeDir, *image, *spec, *out); err != nil {
		fmt.Fprintln(os.Stderr, "tryfydeos-pack:", err)
		os.Exit(1)
	}
}
