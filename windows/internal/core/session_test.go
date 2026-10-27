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

// runFakeQEMU serves QMP like QEMU with -action reboot=shutdown: "guest" powers
// off on the second system_powerdown, "reset" reboots right after the
// handshake, "hang" never exits on its own.
func runFakeQEMU(mode string) {
	var sock string
	for i, a := range os.Args {
		if a == "-qmp" {
			sock = strings.TrimSuffix(strings.TrimPrefix(os.Args[i+1], "unix:"), ",server=on,wait=off")
		}
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
	sc := bufio.NewScanner(conn)
	for sc.Scan() {
		var m struct {
			Execute string `json:"execute"`
			ID      int    `json:"id"`
		}
		json.Unmarshal(sc.Bytes(), &m)
		send(sprintf(`{"return": {}, "id": %d}`, m.ID))
		switch {
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
	if err != nil || r.End == "" || r.QMPReady == "" || r.ExitCode == nil || *r.ExitCode != 0 || r.Reason != "guest-shutdown" || r.Pid == 0 {
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
