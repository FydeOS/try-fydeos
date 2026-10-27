package core

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const fakeQEMUEnv = "TRYFYDEOS_FAKE_QEMU"

func TestMain(m *testing.M) {
	if mode := os.Getenv(fakeQEMUEnv); mode != "" {
		runFakeQEMU(mode)
		return
	}
	QMPConnectDelay = 100 * time.Millisecond
	QMPConnectRetry = 50 * time.Millisecond
	QMPConnectDeadline = 5 * time.Second
	PowerButtonRepeatDelay = 100 * time.Millisecond
	QuitAfter = 1 * time.Second
	TerminateAfter = 2 * time.Second
	os.Exit(m.Run())
}

// runFakeQEMU serves QMP like QEMU with -action reboot=shutdown and emits
// POWERDOWN after each system_powerdown: "guest" powers off on the second
// press, "hostclose" presses once itself after the handshake (the close
// prompt's Shut down) and powers off on the next press, "reset" reboots right
// after the handshake, "hang" never exits on its own.
func runFakeQEMU(mode string) {
	var sock string
	for i, a := range os.Args {
		if a == "-qmp" {
			sock = strings.TrimSuffix(strings.TrimPrefix(os.Args[i+1], "unix:"), ",server=on,wait=off")
		}
	}
	if mode == "exit" {
		os.Exit(1)
	}
	l, err := net.Listen("unix", sock)
	if err != nil {
		os.Exit(3)
	}
	conn, err := l.Accept()
	if err != nil {
		os.Exit(3)
	}
	send := func(s string) { io.WriteString(conn, s+"\r\n") }
	shutdown := func(reason string) {
		send(`{"event": "SHUTDOWN", "data": {"guest": true, "reason": "` + reason + `"}}`)
		conn.Close()
		os.Exit(0)
	}
	send(`{"QMP": {"version": {}, "capabilities": []}}`)
	powerdowns := 0
	running := true
	sc := bufio.NewScanner(conn)
	for sc.Scan() {
		var m struct {
			Execute string `json:"execute"`
			ID      int    `json:"id"`
		}
		json.Unmarshal(sc.Bytes(), &m)
		switch m.Execute {
		case "query-status":
			send(sprintf(`{"return": {"running": %t, "status": "%s"}, "id": %d}`, running, map[bool]string{true: "running", false: "paused"}[running], m.ID))
			continue
		case "stop", "cont":
			running = m.Execute == "cont"
		}
		send(sprintf(`{"return": {}, "id": %d}`, m.ID))
		if m.Execute == "system_powerdown" {
			send(`{"event": "POWERDOWN", "data": {}}`)
		}
		switch {
		case mode == "hostclose" && m.Execute == "qmp_capabilities":
			send(`{"event": "POWERDOWN", "data": {}}`)
			powerdowns = 1
		case mode == "hostclose" && m.Execute == "system_powerdown":
			if powerdowns++; powerdowns == 2 {
				shutdown("guest-shutdown")
			}
		case mode == "reset" && m.Execute == "qmp_capabilities":
			shutdown("guest-reset")
		case mode == "guest" && m.Execute == "system_powerdown":
			if powerdowns++; powerdowns == 2 {
				shutdown("guest-shutdown")
			}
		}
	}
	select {}
}

func launchFake(t *testing.T, mode string) (*Session, *Workspace) {
	t.Setenv(fakeQEMUEnv, mode)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	rt := t.TempDir()
	os.MkdirAll(filepath.Join(rt, "bin"), 0o700)
	data, _ := os.ReadFile(self)
	os.WriteFile(filepath.Join(rt, "bin", QEMUNames[0]), data, 0o700)
	// AF_UNIX paths are short; keep the workspace near the root of the temp dir.
	dir, err := os.MkdirTemp("", "tfws")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	ws := &Workspace{Dir: dir}
	lock, err := ws.Open()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(lock.Release)
	loc := &Locations{Runtime: rt}
	o := LaunchOptions{CPUs: 2, MemoryMiB: 2048}
	s, err := Launch(o, loc, ws, lock, &Metadata{MAC: "52:54:00:12:34:56"}, HostInfo{LogicalCPUs: 4, MemoryMiB: 8192}, nil)
	if err != nil {
		t.Fatal(err)
	}
	return s, ws
}

func waitExit(t *testing.T, s *Session) Exit {
	done := make(chan Exit, 1)
	go func() { done <- s.Wait() }()
	select {
	case e := <-done:
		return e
	case <-time.After(10 * time.Second):
		t.Fatal("QEMU did not exit")
		return Exit{}
	}
}

func TestSessionShutdownThroughControlSocket(t *testing.T) {
	s, ws := launchFake(t, "guest")
	var reply string
	var err error
	for start := time.Now(); time.Since(start) < 3*time.Second; time.Sleep(20 * time.Millisecond) {
		if reply, err = RequestRemoteShutdown(ws); err == nil {
			break
		}
	}
	if !strings.HasPrefix(reply, "ok ") {
		t.Fatalf("control reply %q %v", reply, err)
	}
	e := waitExit(t, s)
	if e.Code != 0 || e.Reason != "guest-shutdown" || e.GuestReset() {
		log, _ := os.ReadFile(filepath.Join(s.Dir, "supervisor.log"))
		t.Fatalf("exit %+v\n%s", e, log)
	}
	_, r, err := ws.LastRun()
	if err != nil || r.End == "" || r.QMPReady == "" || r.ExitCode == nil || *r.ExitCode != 0 || r.Reason != "guest-shutdown" || r.Pid == 0 ||
		r.ShutdownRequest != "shutdown requested on the control socket" {
		t.Fatalf("run.json %+v %v", r, err)
	}
	for _, p := range []string{ws.QMPSocket(), ws.ControlSocket()} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("%s left behind", p)
		}
	}
	if log, _ := os.ReadFile(filepath.Join(s.Dir, "supervisor.log")); !strings.Contains(string(log), "QMP event SHUTDOWN (guest-shutdown)") {
		t.Errorf("supervisor.log:\n%s", log)
	}
}

func TestSessionHostCloseFinishesTheLadder(t *testing.T) {
	s, ws := launchFake(t, "hostclose")
	e := waitExit(t, s)
	log, _ := os.ReadFile(filepath.Join(s.Dir, "supervisor.log"))
	if e.Code != 0 || e.Reason != "guest-shutdown" {
		t.Fatalf("exit %+v\n%s", e, log)
	}
	_, r, err := ws.LastRun()
	if err != nil || r.ShutdownRequest != HostCloseRequest || r.Reason != "guest-shutdown" {
		t.Fatalf("run.json %+v %v", r, err)
	}
	for _, line := range []string{"QMP event POWERDOWN", HostCloseRequest, "power button pressed in the window"} {
		if !strings.Contains(string(log), line) {
			t.Errorf("missing %q:\n%s", line, log)
		}
	}
	if strings.Contains(string(log), "system_powerdown twice") {
		t.Errorf("the ladder pressed the button twice after the window's press:\n%s", log)
	}
}

func TestSessionLadderIgnoresItsOwnPowerdownEvents(t *testing.T) {
	s, _ := launchFake(t, "guest")
	if err := s.WaitQMP(); err != nil {
		t.Fatal(err)
	}
	s.RequestShutdown("test")
	if e := waitExit(t, s); e.Reason != "guest-shutdown" {
		t.Fatalf("exit %+v", e)
	}
	log, _ := os.ReadFile(filepath.Join(s.Dir, "supervisor.log"))
	if strings.Contains(string(log), HostCloseRequest) || strings.Count(string(log), "QMP event POWERDOWN") != 2 {
		t.Errorf("supervisor.log:\n%s", log)
	}
}

func TestSessionGuestReset(t *testing.T) {
	s, _ := launchFake(t, "reset")
	if e := waitExit(t, s); !e.GuestReset() || e.Code != 0 {
		t.Fatalf("exit %+v", e)
	}
}

func TestSessionLadderTerminatesAHungQEMU(t *testing.T) {
	s, _ := launchFake(t, "hang")
	start := time.Now()
	s.RequestShutdown("test")
	e := waitExit(t, s)
	if e.Reason != "terminated" {
		t.Fatalf("exit %+v", e)
	}
	if took := time.Since(start); took < TerminateAfter {
		t.Fatalf("terminated after %v, before the ladder's %v", took, TerminateAfter)
	}
	log, _ := os.ReadFile(filepath.Join(s.Dir, "supervisor.log"))
	for _, step := range []string{"system_powerdown twice", "quit", "TerminateProcess"} {
		if !strings.Contains(string(log), step) {
			t.Errorf("ladder step %q missing:\n%s", step, log)
		}
	}
}

func TestSessionSleepPause(t *testing.T) {
	s, _ := launchFake(t, "guest")
	if err := s.WaitQMP(); err != nil {
		t.Fatal(err)
	}
	if s.Pid() == 0 {
		t.Fatal("no pid")
	}
	status := func() bool {
		raw, err := s.qmpClient().Execute("query-status", nil)
		if err != nil {
			t.Fatal(err)
		}
		return strings.Contains(string(raw), `"running":true`) || strings.Contains(string(raw), `"running": true`)
	}
	s.ResumeAfterWake()
	if !status() {
		t.Fatal("wake without our stop paused the guest")
	}
	s.PauseForSleep()
	if status() {
		t.Fatal("guest still running after PauseForSleep")
	}
	s.ResumeAfterWake()
	if !status() {
		t.Fatal("guest not continued after our stop")
	}
	s.qmpClient().Execute("stop", nil)
	s.PauseForSleep()
	s.ResumeAfterWake()
	if status() {
		t.Fatal("cont although the guest was paused by someone else")
	}
	s.RequestShutdown("test")
	waitExit(t, s)
	log, _ := os.ReadFile(filepath.Join(s.Dir, "supervisor.log"))
	for _, line := range []string{"host wake: no stop of ours to undo", "host sleep: QMP stop", "host sleep: guest is paused, not stopping it", "host wake: QMP cont"} {
		if !strings.Contains(string(log), line) {
			t.Errorf("missing %q:\n%s", line, log)
		}
	}
}

func TestWaitQMPReportsEarlyExit(t *testing.T) {
	s, _ := launchFake(t, "exit")
	if err := s.WaitQMP(); err == nil || !strings.Contains(err.Error(), "exited before QMP") {
		t.Fatalf("WaitQMP %v", err)
	}
	waitExit(t, s)
}
