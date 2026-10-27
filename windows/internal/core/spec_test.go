package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadFactorySpecFromRepository(t *testing.T) {
	path := filepath.Join("..", "..", "..", "factory", SpecFileName)
	if _, err := os.Stat(path); err != nil {
		t.Skip("not in the repository layout:", err)
	}
	spec, err := LoadFactorySpec(path)
	if err != nil {
		t.Fatal(err)
	}
	if spec.Board != "amd64-vmware-io" || spec.DiskBytes != 64<<30 || !strings.HasSuffix(spec.Image.File, ".bin.zst") {
		t.Fatalf("unexpected spec %+v", spec)
	}
}

func TestLoadFactorySpecRejectsMalformed(t *testing.T) {
	good := `{"schema":1,"image":{"file":"a.zst","bytes":1,"sha256":"%s","rawBytes":10,"rawSha256":"%s","version":"v"},"diskBytes":%d,"board":"b"}`
	hex := strings.Repeat("ab", 32)
	for name, text := range map[string]string{
		"schema":   strings.Replace(good, `"schema":1`, `"schema":2`, 1),
		"sha":      strings.Replace(good, `"sha256":"%s"`, `"sha256":"XYZ"`, 1),
		"path":     strings.Replace(good, `"file":"a.zst"`, `"file":"..\\a.zst"`, 1),
		"diskSize": good,
	} {
		disk := 100
		if name == "diskSize" {
			disk = 5
		}
		var body string
		switch strings.Count(text, "%s") {
		case 2:
			body = sprintf(text, hex, hex, disk)
		default:
			body = sprintf(text, hex, disk)
		}
		path := filepath.Join(t.TempDir(), "spec.json")
		os.WriteFile(path, []byte(body), 0o600)
		if _, err := LoadFactorySpec(path); err == nil {
			t.Errorf("%s: accepted %s", name, body)
		}
	}
}
