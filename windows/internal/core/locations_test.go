package core

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDiscoverLocations(t *testing.T) {
	local := t.TempDir()
	env := map[string]string{"LOCALAPPDATA": local}
	getenv := func(k string) string { return env[k] }
	l, err := DiscoverLocations(getenv, "/app")
	if err != nil {
		t.Fatal(err)
	}
	if l.Workspace != filepath.Join(local, "Try FydeOS", "VM", "v1") || l.Runtime != filepath.Join("/app", "runtime") ||
		l.Spec != filepath.Join("/app", "factory", SpecFileName) || l.LogsDir() != filepath.Join(local, "Try FydeOS", "Logs") {
		t.Fatalf("defaults %+v", l)
	}

	os.MkdirAll(l.AppData, 0o700)
	os.WriteFile(l.PreferencesFile(), []byte(`{"forwards":["2201:22"],"workspace":"/prefs/vm"}`), 0o600)
	l, err = DiscoverLocations(getenv, "/app")
	if err != nil {
		t.Fatal(err)
	}
	if l.Workspace != "/prefs/vm" || !reflect.DeepEqual(l.Forwards, []HostForward{{2201, 22}}) {
		t.Fatalf("preferences %+v", l)
	}

	env["TRY_FYDEOS_WORKSPACE"] = "/env/vm"
	env["TRY_FYDEOS_FORWARDS"] = "2202:22, 8080:80"
	env["TRY_FYDEOS_RUNTIME"] = "/env/runtime"
	env["TRY_FYDEOS_FACTORY_IMAGE"] = "/images/x.bin.zst"
	l, err = DiscoverLocations(getenv, "/app")
	if err != nil {
		t.Fatal(err)
	}
	if l.Workspace != "/env/vm" || l.Runtime != "/env/runtime" || l.Spec != filepath.Join("/images", SpecFileName) ||
		!reflect.DeepEqual(l.Forwards, []HostForward{{2202, 22}, {8080, 80}}) {
		t.Fatalf("environment %+v", l)
	}
	spec := &FactorySpec{Image: FactoryImage{File: "x.bin.zst"}}
	if got := l.FactoryImageCandidates(spec); !reflect.DeepEqual(got, []string{"/images/x.bin.zst", filepath.Join("/images", "x.bin.zst")}) {
		t.Fatalf("candidates %v", got)
	}

	env["TRY_FYDEOS_FORWARDS"] = "nope"
	if _, err := DiscoverLocations(getenv, "/app"); err == nil {
		t.Fatal("accepted a malformed forward")
	}
}

func TestQEMUPrefersWindowlessBuild(t *testing.T) {
	rt := t.TempDir()
	l := &Locations{Runtime: rt}
	os.MkdirAll(filepath.Join(rt, "bin"), 0o700)
	if got := filepath.Base(l.QEMU()); got != QEMUNames[0] {
		t.Fatalf("default %s", got)
	}
	os.WriteFile(filepath.Join(rt, "bin", QEMUNames[1]), nil, 0o700)
	if got := filepath.Base(l.QEMU()); got != QEMUNames[1] {
		t.Fatalf("console build only: %s", got)
	}
	os.WriteFile(filepath.Join(rt, "bin", QEMUNames[0]), nil, 0o700)
	if got := filepath.Base(l.QEMU()); got != QEMUNames[0] {
		t.Fatalf("both: %s", got)
	}
}
