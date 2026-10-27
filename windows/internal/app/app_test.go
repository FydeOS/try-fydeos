package app

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"tryfydeos.io/windows/internal/core"
)

type fakeDriver struct {
	calls  []string
	events func(Event)
	reset  error
}

func (f *fakeDriver) Launch(o core.LaunchOptions, events func(Event)) {
	f.calls = append(f.calls, "launch")
	f.events = events
}
func (f *fakeDriver) ShutDown()           { f.calls = append(f.calls, "shutdown") }
func (f *fakeDriver) PauseForSleep()      { f.calls = append(f.calls, "pause") }
func (f *fakeDriver) ResumeAfterWake()    { f.calls = append(f.calls, "resume") }
func (f *fakeDriver) FactoryReset() error { f.calls = append(f.calls, "reset"); return f.reset }

func newTestController() (*Controller, *fakeDriver, *[]string) {
	d := &fakeDriver{}
	c := NewController(d, "")
	c.Now = func() time.Time { return time.Date(2026, 10, 27, 9, 5, 0, 0, time.UTC) }
	var log []string
	c.OnStateChange = func(s State) { log = append(log, s.String()) }
	c.OnError = func(title, message string) { log = append(log, "error "+title+": "+message) }
	c.OnReadyToQuit = func() { log = append(log, "quit") }
	return c, d, &log
}

func TestLaunchToShutdown(t *testing.T) {
	c, d, log := newTestController()
	if c.State().StatusText() != "Not running" || c.State().LaunchTitle() != "Launch FydeOS" {
		t.Fatalf("initial %q %q", c.State().StatusText(), c.State().LaunchTitle())
	}
	c.Launch(core.LaunchOptions{})
	if c.State().StatusText() != "Preparing…" || c.State().LaunchTitle() != "Preparing FydeOS…" || c.CanLaunch() || c.CanFactoryReset() {
		t.Fatalf("preparing %+v", c.State())
	}
	d.events(Event{Kind: EventPreparing, Bytes: 42, Total: 100})
	if got := c.State().StatusText(); got != "Unpacking FydeOS… 42%" {
		t.Fatalf("unpacking %q", got)
	}
	d.events(Event{Kind: EventStarting, Pid: 77})
	if c.VMPid() != 77 || c.State().LaunchTitle() != "Launching FydeOS…" || c.State().StatusText() != "Starting…" {
		t.Fatalf("starting %+v", c.State())
	}
	d.events(Event{Kind: EventRunning})
	if c.State().StatusText() != "Running since 09:05" || c.State().LaunchTitle() != "Running" {
		t.Fatalf("running %q", c.State().StatusText())
	}
	d.events(Event{Kind: EventStarting, Pid: 78})
	if c.State().Phase != Running || c.VMPid() != 77 {
		t.Fatalf("a relaunch after a guest reboot changed the state: %+v", c.State())
	}
	c.ShutDown()
	if c.State().LaunchTitle() != "Shutting down…" {
		t.Fatal(c.State())
	}
	d.events(Event{Kind: EventExited, Exit: core.Exit{Code: 0, Reason: "guest-shutdown"}})
	want := "Not running. Last run shut down by Try FydeOS (exit code 0, guest-shutdown)."
	if c.State().StatusText() != want || !c.CanLaunch() || c.VMPid() != 0 {
		t.Fatalf("got %q", c.State().StatusText())
	}
	if !reflect.DeepEqual(d.calls, []string{"launch", "shutdown"}) {
		t.Fatalf("calls %v", d.calls)
	}
	if len(*log) != 6 {
		t.Fatalf("state log %v", *log)
	}
}

func TestExitWithoutRequest(t *testing.T) {
	c, d, log := newTestController()
	c.Launch(core.LaunchOptions{})
	d.events(Event{Kind: EventStarting, Pid: 1})
	d.events(Event{Kind: EventRunning})
	d.events(Event{Kind: EventExited, Exit: core.Exit{Code: 0, Reason: "host-ui"}})
	if got := c.State().StatusText(); got != "Not running. Last run: FydeOS stopped (exit code 0, host-ui)." {
		t.Fatal(got)
	}
	c.Launch(core.LaunchOptions{})
	d.events(Event{Kind: EventStarting, Pid: 1})
	d.events(Event{Kind: EventExited, Exit: core.Exit{Code: 1, Reason: "terminated"}})
	want := "FydeOS stopped unexpectedly (exit code 1, terminated). See the logs via Open Logs Folder in the window menu."
	if c.State().Phase != Failed || c.State().StatusText() != want || !c.CanLaunch() {
		t.Fatal(c.State())
	}
	if last := (*log)[len(*log)-1]; last != "error Try FydeOS: "+want {
		t.Fatalf("last %q", last)
	}
	c.Launch(core.LaunchOptions{})
	d.events(Event{Kind: EventFailed, Message: "no image"})
	if last := (*log)[len(*log)-1]; last != "error Try FydeOS couldn’t start: no image" {
		t.Fatalf("last %q", last)
	}
}

func TestQuit(t *testing.T) {
	c, d, log := newTestController()
	if !c.RequestQuit() {
		t.Fatal("idle quit refused")
	}
	c.Launch(core.LaunchOptions{})
	if c.RequestQuit() || !c.QuitPending() || c.CanLaunch() {
		t.Fatal("quit while preparing")
	}
	if len(d.calls) != 1 {
		t.Fatalf("shutdown before QEMU exists: %v", d.calls)
	}
	d.events(Event{Kind: EventStarting, Pid: 9})
	if c.State().Phase != ShuttingDown || d.calls[1] != "shutdown" {
		t.Fatalf("starting with quit pending: %+v %v", c.State(), d.calls)
	}
	d.events(Event{Kind: EventExited, Exit: core.Exit{Code: 1, Reason: "terminated"}})
	for _, l := range *log {
		if strings.HasPrefix(l, "error") {
			t.Fatalf("error alert while quitting: %v", *log)
		}
	}
	if (*log)[len(*log)-1] != "quit" {
		t.Fatalf("log %v", *log)
	}
}

func TestSleepAndReset(t *testing.T) {
	c, d, _ := newTestController()
	c.WillSleep()
	c.DidWake()
	if err := c.FactoryReset(); err != nil || c.State().StatusText() != "Not running. FydeOS has been reset." {
		t.Fatal(err, c.State())
	}
	c.Launch(core.LaunchOptions{})
	c.WillSleep()
	d.events(Event{Kind: EventStarting})
	d.events(Event{Kind: EventRunning})
	c.WillSleep()
	c.DidWake()
	if err := c.FactoryReset(); err == nil || err.Error() != L(ErrorBusy) {
		t.Fatalf("reset while running: %v", err)
	}
	if !reflect.DeepEqual(d.calls, []string{"reset", "launch", "pause", "resume"}) {
		t.Fatalf("calls %v", d.calls)
	}
	d.events(Event{Kind: EventExited})
	d.reset = errors.New("denied")
	before := c.State()
	if err := c.FactoryReset(); err == nil || c.State() != before {
		t.Fatal("failed reset changed the state")
	}
}

func TestLastRunMessage(t *testing.T) {
	zero, one := 0, 1
	for _, tc := range []struct {
		r    *core.RunRecord
		want string
	}{
		{nil, ""},
		{&core.RunRecord{Reason: ""}, ""},
		{&core.RunRecord{ExitCode: &zero, Reason: "guest-shutdown", ShutdownRequest: "shutdown requested by the app"}, "Last run shut down by Try FydeOS (exit code 0, guest-shutdown)."},
		{&core.RunRecord{ExitCode: &zero, Reason: "host-ui"}, "Last run: FydeOS stopped (exit code 0, host-ui)."},
		{&core.RunRecord{ExitCode: &one, Reason: "exited"}, "FydeOS stopped unexpectedly (exit code 1, exited). See the logs via Open Logs Folder in the window menu."},
	} {
		if got := LastRunMessage(tc.r); got != tc.want {
			t.Errorf("%+v: %q", tc.r, got)
		}
	}
}

func TestStringsMatchTheMacTable(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "macos", "Sources", "TryFydeOSAppModel", "Strings.swift"))
	if err != nil {
		t.Skip("Mac sources not present:", err)
	}
	text := string(data)
	windowsOnly := map[Key]bool{Subtitle: true, AboutCredits: true, FullScreenDetail: true, MicrophoneDetail: true, ErrorUnexpectedExit: true, ErrorNotReady: true}
	for key, value := range English {
		if windowsOnly[key] {
			continue
		}
		mac := strings.ReplaceAll(value, "%s", "%@")
		if !strings.Contains(text, "."+string(key)+": "+strconvQuote(mac)+",") {
			t.Errorf("%s: %q differs from Strings.swift", key, mac)
		}
	}
	if n := strings.Count(text, "    case "); n != len(English) {
		t.Errorf("Strings.swift has %d keys, Go has %d", n, len(English))
	}
}

func strconvQuote(s string) string { return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"` }

var host16 = core.HostInfo{LogicalCPUs: 4, MemoryMiB: 16243}

func TestPreferencesClamping(t *testing.T) {
	if got := CPUChoices(host16); !reflect.DeepEqual(got, []int{2, 3, 4}) {
		t.Fatal(got)
	}
	if got := MemoryChoices(core.HostInfo{MemoryMiB: 6000}); !reflect.DeepEqual(got, []int{2048, 3072}) {
		t.Fatal(got)
	}
	if got := MemoryChoices(core.HostInfo{MemoryMiB: 1024}); !reflect.DeepEqual(got, []int{2048}) {
		t.Fatal(got)
	}
	if d := DefaultPreferences(host16); d != (Preferences{CPUs: 4, MemoryMiB: 8192, FullScreen: true}) {
		t.Fatalf("defaults %+v", d)
	}
	if d := DefaultPreferences(core.HostInfo{LogicalCPUs: 2, MemoryMiB: 8000}); d != (Preferences{CPUs: 2, MemoryMiB: 5120, FullScreen: true}) {
		t.Fatalf("small host defaults %+v", d)
	}
	for _, tc := range []struct{ in, want Preferences }{
		{Preferences{CPUs: 64, MemoryMiB: 99999}, Preferences{CPUs: 4, MemoryMiB: 14336 - 1024}},
		{Preferences{CPUs: 1, MemoryMiB: 100}, Preferences{CPUs: 2, MemoryMiB: 2048}},
		{Preferences{CPUs: 3, MemoryMiB: 3500}, Preferences{CPUs: 3, MemoryMiB: 3072}},
	} {
		if got := tc.in.Clamped(host16); got != tc.want {
			t.Errorf("%+v -> %+v, want %+v", tc.in, got, tc.want)
		}
	}
}

func TestPreferencesFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "Try FydeOS", "preferences.json")
	p, err := LoadPreferences(path, host16)
	if err != nil || p != DefaultPreferences(host16) {
		t.Fatal(p, err)
	}
	os.MkdirAll(filepath.Dir(path), 0o700)
	os.WriteFile(path, []byte(`{"cpus": 2, "memoryMiB": 3072, "fullScreen": false, "forwards": ["2201:22"], "workspace": "D:\\vm"}`), 0o600)
	p, err = LoadPreferences(path, host16)
	if err != nil || p != (Preferences{CPUs: 2, MemoryMiB: 3072}) {
		t.Fatal(p, err)
	}
	p.Microphone = true
	p.CPUs = 3
	if err := p.Save(path); err != nil {
		t.Fatal(err)
	}
	var all map[string]any
	data, _ := os.ReadFile(path)
	json.Unmarshal(data, &all)
	if all["workspace"] != `D:\vm` || !reflect.DeepEqual(all["forwards"], []any{"2201:22"}) || all["cpus"] != 3.0 || all["microphone"] != true {
		t.Fatalf("saved %s", data)
	}
	loc, err := core.DiscoverLocations(func(k string) string {
		return map[string]string{"LOCALAPPDATA": filepath.Dir(filepath.Dir(path))}[k]
	}, "/app")
	if err != nil || loc.Workspace != `D:\vm` || len(loc.Forwards) != 1 {
		t.Fatalf("core reads the shared file: %+v %v", loc, err)
	}
	os.WriteFile(path, []byte(`{nope`), 0o600)
	if p, err := LoadPreferences(path, host16); err == nil || p != DefaultPreferences(host16) {
		t.Fatal("malformed file accepted")
	}
	if err := p.Save(path); err == nil {
		t.Fatal("Save overwrote a malformed file")
	}
}
