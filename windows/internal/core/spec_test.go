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
	if spec.Board != "amd64-vmware-io" || spec.DiskBytes != 64<<30 || !strings.HasSuffix(spec.Image.URL, ".ova") || spec.Release.Board != "amd64-vmware" {
		t.Fatalf("unexpected spec %+v", spec)
	}
}

func TestLoadFactorySpecRejectsMalformed(t *testing.T) {
	good := `{"schema":2,"image":{"url":"https://h/d/a.ova","bytes":1,"sha256":"` + strings.Repeat("ab", 32) +
		`","version":"v"},"release":{"api":"https://h/api","board":"b"},"diskBytes":100,"board":"b"}`
	path := filepath.Join(t.TempDir(), "spec.json")
	os.WriteFile(path, []byte(good), 0o600)
	if _, err := LoadFactorySpec(path); err != nil {
		t.Fatalf("good spec: %v", err)
	}
	for name, edit := range map[string][2]string{
		"schema":     {`"schema":2`, `"schema":1`},
		"http url":   {`"url":"https://h/d/a.ova"`, `"url":"http://h/d/a.ova"`},
		"no file":    {`"url":"https://h/d/a.ova"`, `"url":"https://h/"`},
		"bytes":      {`"bytes":1`, `"bytes":0`},
		"sha":        {`"sha256":"ab`, `"sha256":"XY`},
		"http api":   {`"api":"https://h/api"`, `"api":"http://h/api"`},
		"no board":   {`"board":"b"}`, `"board":""}`},
		"disk bytes": {`"diskBytes":100`, `"diskBytes":0`},
	} {
		body := strings.Replace(good, edit[0], edit[1], 1)
		if body == good {
			t.Fatalf("%s: edit did not apply", name)
		}
		os.WriteFile(path, []byte(body), 0o600)
		if _, err := LoadFactorySpec(path); err == nil {
			t.Errorf("%s: accepted %s", name, body)
		}
	}
}
