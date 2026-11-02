package app

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tryfydeos.io/windows/internal/core"
)

const fakeQEMUEnv = "TRYFYDEOS_APP_FAKE_QEMU"

func TestMain(m *testing.M) {
	if os.Getenv(fakeQEMUEnv) != "" {
		runFakeQEMU()
		return
	}
	core.QMPConnectDelay = 100 * time.Millisecond
	core.QMPConnectRetry = 50 * time.Millisecond
	core.PowerButtonRepeatDelay = 100 * time.Millisecond
	core.QuitAfter = time.Second
	core.TerminateAfter = 2 * time.Second
	os.Exit(m.Run())
}

// runFakeQEMU reboots the guest on its first run in a workspace and powers off
// on the second system_powerdown afterwards, as QEMU with -action reboot=shutdown does.
func runFakeQEMU() {
	var sock string
	for i, a := range os.Args {
		if a == "-qmp" {
			sock = strings.TrimSuffix(strings.TrimPrefix(os.Args[i+1], "unix:"), ",server=on,wait=off")
		}
	}
	marker := filepath.Join(filepath.Dir(sock), "rebooted")
	_, err := os.Stat(marker)
	reboot := err != nil
	l, err := net.Listen("unix", sock)
	if err != nil {
		os.Exit(3)
	}
	conn, err := l.Accept()
	if err != nil {
		os.Exit(3)
	}
	send := func(s string) { io.WriteString(conn, s+"\r\n") }
	send(`{"QMP": {"version": {}, "capabilities": []}}`)
	powerdowns := 0
	sc := bufio.NewScanner(conn)
	for sc.Scan() {
		var m struct {
			Execute string `json:"execute"`
			ID      int    `json:"id"`
		}
		json.Unmarshal(sc.Bytes(), &m)
		send(fmt.Sprintf(`{"return": {}, "id": %d}`, m.ID))
		reason := ""
		switch {
		case reboot && m.Execute == "qmp_capabilities":
			time.Sleep(200 * time.Millisecond)
			os.WriteFile(marker, nil, 0o600)
			reason = "guest-reset"
		case m.Execute == "system_powerdown":
			if powerdowns++; powerdowns == 2 {
				reason = "guest-shutdown"
			}
		}
		if reason != "" {
			send(`{"event": "SHUTDOWN", "data": {"guest": true, "reason": "` + reason + `"}}`)
			conn.Close()
			os.Exit(0)
		}
	}
	select {}
}

func TestCoreDriverRelaunchesAfterGuestReboot(t *testing.T) {
	t.Setenv(fakeQEMUEnv, "1")
	self, _ := os.Executable()
	root := t.TempDir()
	rt := filepath.Join(root, "runtime")
	os.MkdirAll(filepath.Join(rt, "bin"), 0o700)
	data, _ := os.ReadFile(self)
	os.WriteFile(filepath.Join(rt, "bin", core.QEMUNames[0]), data, 0o700)

	ws := &core.Workspace{Dir: filepath.Join(root, "vm")}
	lock, err := ws.Open()
	if err != nil {
		t.Fatal(err)
	}
	lock.Release()
	for _, f := range []string{ws.Disk(), ws.EFIVars()} {
		os.WriteFile(f, nil, 0o600)
	}
	os.WriteFile(ws.MetadataFile(), []byte(`{"schema":1,"factory":{"sha256":"`+strings.Repeat("a", 64)+`"},"mac":"52:54:00:12:34:56"}`), 0o600)
	spec := filepath.Join(root, "spec.json")
	os.WriteFile(spec, []byte(`{"schema":2,"image":{"url":"https://h/x.ova","bytes":1,"sha256":"`+strings.Repeat("a", 64)+
		`"},"release":{"api":"https://h/api","board":"b"},"diskBytes":2}`), 0o600)

	events := make(chan Event, 16)
	d := &CoreDriver{
		Locations: &core.Locations{Runtime: rt, Spec: spec, Workspace: ws.Dir},
		Host:      core.HostInfo{LogicalCPUs: 4, MemoryMiB: 8192},
		Log:       OpenAppLog(filepath.Join(root, "Logs")),
		Post:      func(f func()) { f() },
	}
	t.Cleanup(d.Log.Close)
	d.Launch(core.LaunchOptions{CPUs: 2, MemoryMiB: 2048}, func(ev Event) { events <- ev })
	next := func() Event {
		select {
		case ev := <-events:
			return ev
		case <-time.After(10 * time.Second):
			log, _ := os.ReadFile(d.Log.Path)
			t.Fatalf("no event\n%s", log)
			return Event{}
		}
	}
	var kinds []EventKind
	for len(kinds) < 4 {
		ev := next()
		if ev.Kind == EventFailed || ev.Kind == EventExited {
			t.Fatalf("run ended early: %+v", ev)
		}
		kinds = append(kinds, ev.Kind)
	}
	want := []EventKind{EventStarting, EventRunning, EventStarting, EventRunning}
	if fmt.Sprint(kinds) != fmt.Sprint(want) {
		t.Fatalf("events %v, want %v", kinds, want)
	}
	if ws.IsLocked() == false {
		t.Fatal("storage lock not held while running")
	}
	d.ShutDown()
	ev := next()
	if ev.Kind != EventExited || ev.Exit.Reason != "guest-shutdown" {
		t.Fatalf("exit %+v", ev)
	}
	runs, _ := os.ReadDir(ws.RunsDir())
	if len(runs) != 2 {
		t.Fatalf("%d run directories, want 2", len(runs))
	}
	if ws.IsLocked() {
		t.Fatal("storage lock still held after the run")
	}
	if log, _ := os.ReadFile(d.Log.Path); !strings.Contains(string(log), "guest rebooted; relaunching QEMU") {
		t.Fatalf("app log:\n%s", log)
	}
	if err := d.FactoryReset(); err != nil || ws.IsPrepared() {
		t.Fatalf("factory reset: %v", err)
	}
}
