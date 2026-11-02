package core

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"tryfydeos.io/windows/internal/payload"
	"tryfydeos.io/windows/internal/payload/payloadtest"
)

// packagedExe appends a runtime.zip and a spec to a fake PE.
func packagedExe(t *testing.T) (string, *FactorySpec) {
	spec, _ := testSpec(t)
	dir := t.TempDir()
	var zipped bytes.Buffer
	zw := zip.NewWriter(&zipped)
	for name, content := range map[string]string{"bin/qemu-system-x86_64w.exe": "qemu", "bin/share/edk2-i386-vars.fd": "vars"} {
		w, _ := zw.Create(name)
		w.Write([]byte(content))
	}
	zw.Close()
	specJSON, _ := json.Marshal(spec)
	write := func(name string, data []byte) string {
		p := filepath.Join(dir, name)
		os.WriteFile(p, data, 0o644)
		return p
	}
	exe := write("plain.exe", payloadtest.FakePE())
	out := filepath.Join(dir, "Try FydeOS.exe")
	if _, err := payload.Append(exe, out, []payload.File{
		{Name: payload.RuntimeEntry, Path: write("runtime.zip", zipped.Bytes())},
		{Name: payload.SpecEntry, Path: write("spec.json", specJSON)},
	}); err != nil {
		t.Fatal(err)
	}
	return out, spec
}

func TestPackagedLocationsExtractAndPrepare(t *testing.T) {
	exe, spec := packagedExe(t)
	p, err := payload.Open(exe)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	env := map[string]string{"LOCALAPPDATA": t.TempDir()}
	l, err := DiscoverLocations(func(k string) string { return env[k] }, filepath.Dir(exe), p)
	if err != nil {
		t.Fatal(err)
	}
	e, _ := p.Lookup(payload.RuntimeEntry)
	if l.Runtime != filepath.Join(l.AppData, "runtime", e.SHA256[:12]) || l.Spec != "" || !l.RuntimeFromPayload() || l.RuntimeExtracted() {
		t.Fatalf("packaged defaults %+v", l)
	}
	if s, err := l.LoadSpec(); err != nil || s.Image.SHA256 != spec.Image.SHA256 {
		t.Fatalf("spec from payload %+v %v", s, err)
	}

	ws := &Workspace{Dir: filepath.Join(l.AppData, "VM", "v1")}
	lock, err := ws.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Release()
	var lines []string
	var stages []PrepareStage
	l.FactoryImageOverride = fixture("test.ova")
	m, _, err := l.PrepareWorkspace(ws, lock, func(s string) { lines = append(lines, s) },
		func(s PrepareStage, done, total int64) { stages = append(stages, s) })
	if err != nil {
		t.Fatal(err)
	}
	if q, _ := os.ReadFile(l.QEMU()); string(q) != "qemu" || !l.RuntimeExtracted() || len(lines) != 4 {
		t.Fatalf("runtime %q extracted %t, log %q", q, l.RuntimeExtracted(), lines)
	}
	if m.Factory != (FactoryRecord{FileName: "test.ova", RawBytes: fixtureRawBytes}) || len(stages) == 0 || stages[0] != StageConverting {
		t.Fatalf("metadata %+v, stages %v", m.Factory, stages)
	}
	if done, err := l.EnsureRuntime(); done || err != nil {
		t.Fatalf("second extraction %t %v", done, err)
	}
	if leftovers, _ := filepath.Glob(filepath.Join(l.AppData, "runtime", "*.extracting-*")); len(leftovers) != 0 {
		t.Fatalf("staging left behind: %v", leftovers)
	}

	env["TRY_FYDEOS_RUNTIME"] = "/env/runtime"
	env["TRY_FYDEOS_SPEC"] = "/env/spec.json"
	if l, err = DiscoverLocations(func(k string) string { return env[k] }, filepath.Dir(exe), p); err != nil ||
		l.Runtime != "/env/runtime" || l.RuntimeFromPayload() || l.Spec != "/env/spec.json" {
		t.Fatalf("overrides %+v %v", l, err)
	}
	if done, err := l.EnsureRuntime(); done || err != nil {
		t.Fatalf("extracted despite TRY_FYDEOS_RUNTIME: %t %v", done, err)
	}
}
