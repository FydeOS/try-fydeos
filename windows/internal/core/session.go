package core

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Variables so tests can shorten them.
var (
	// Connecting to QMP during early boot deadlocks WHPX QEMU.
	QMPConnectDelay    = 10 * time.Second
	QMPConnectRetry    = 1 * time.Second
	QMPConnectDeadline = 90 * time.Second
	// FydeOS runs Chrome with --aura-legacy-power-button: the first press opens
	// the power menu, a second press while it is open shuts down.
	PowerButtonRepeatDelay = 2 * time.Second
	QuitAfter              = 20 * time.Second
	TerminateAfter         = 30 * time.Second
)

type LaunchOptions struct {
	CPUs         int
	MemoryMiB    int
	FullScreen   bool
	Microphone   bool
	CPUFallback  bool
	HostForwards []HostForward
}

func (o LaunchOptions) Config(loc *Locations, ws *Workspace, runDir, mac string) *VMConfig {
	return &VMConfig{
		CPUs: o.CPUs, MemoryMiB: o.MemoryMiB, FullScreen: o.FullScreen, Microphone: o.Microphone, CPUFallback: o.CPUFallback,
		HostForwards: o.HostForwards, MAC: mac,
		Paths: VMPaths{
			QEMU: loc.QEMU(), FirmwareCode: loc.FirmwareCode(), EFIVars: ws.EFIVars(), Disk: ws.Disk(),
			Console: filepath.Join(runDir, "console.log"), QEMULog: filepath.Join(runDir, "qemu.log"),
			QMPSocket: ws.QMPSocket(),
		},
	}
}

// Exit is how a run ended. Reason is the SHUTDOWN event's reason (guest-shutdown,
// guest-reset, host-qmp-quit, host-ui, ...), "terminated" after TerminateProcess,
// or "exited" when QEMU ended without either.
type Exit struct {
	Code   int
	Reason string
}

// GuestReset: with reboot=shutdown a guest reboot ends QEMU; the caller relaunches.
func (e Exit) GuestReset() bool { return e.Reason == "guest-reset" }

// Session is one QEMU run: run directory, supervisor.log, run.json, the process,
// its QMP connection, the control socket and the shutdown ladder.
type Session struct {
	ID  string
	Dir string

	ws      *Workspace
	cmd     *exec.Cmd
	started time.Time
	logFile *os.File
	echo    func(string)
	control net.Listener

	exited     chan struct{}
	attached   chan struct{}
	eventsDone chan struct{}

	mu             sync.Mutex
	record         RunRecord
	qmp            *QMPClient
	shutdownReason string
	terminated     bool
	pausedForSleep bool
	shutdownOnce   sync.Once
}

func Launch(o LaunchOptions, loc *Locations, ws *Workspace, lock *StorageLock, m *Metadata, host HostInfo,
	echo func(string)) (*Session, error) {
	if lock == nil || lock.Path != ws.LockFile() {
		return nil, fmt.Errorf("launch needs the workspace lock")
	}
	os.Remove(ws.QMPSocket())
	os.Remove(ws.ControlSocket())
	now := time.Now()
	id, dir, err := ws.NewRunDirectory(now)
	if err != nil {
		return nil, err
	}
	argv, err := o.Config(loc, ws, dir, m.MAC).Argv(host)
	if err != nil {
		return nil, err
	}
	logFile, err := os.OpenFile(filepath.Join(dir, "supervisor.log"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return nil, err
	}
	s := &Session{
		ID: id, Dir: dir, ws: ws, logFile: logFile, echo: echo,
		exited: make(chan struct{}), attached: make(chan struct{}), eventsDone: make(chan struct{}),
		record: RunRecord{ID: id, Argv: argv, SupervisorPid: os.Getpid(), Start: UTCTimestamp(now)},
	}
	s.saveRecord(nil)
	if err := joinKillOnCloseJob(); err != nil {
		logFile.Close()
		return nil, fmt.Errorf("job object: %w", err)
	}
	stderr, err := os.OpenFile(filepath.Join(dir, "qemu-stderr.log"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		logFile.Close()
		return nil, err
	}
	defer stderr.Close()
	s.cmd = exec.Command(argv[0], argv[1:]...)
	s.cmd.Dir = ws.Dir
	s.cmd.Stdout = stderr
	s.cmd.Stderr = stderr
	if err := s.cmd.Start(); err != nil {
		logFile.Close()
		return nil, err
	}
	s.started = time.Now()
	s.saveRecord(func(r *RunRecord) { r.Pid = s.cmd.Process.Pid })
	s.Log(fmt.Sprintf("run %s: QEMU pid %d, logs in %s", id, s.cmd.Process.Pid, dir))
	go func() {
		s.cmd.Wait()
		close(s.exited)
	}()
	go s.attachQMP()
	if l, err := net.Listen("unix", ws.ControlSocket()); err != nil {
		s.Log(fmt.Sprintf("control socket unavailable, 'tryfydeos shutdown' will not reach this run: %v", err))
	} else {
		s.control = l
		go s.serveControl(l)
	}
	return s, nil
}

func (s *Session) Log(message string) {
	if s.echo != nil {
		s.echo(message)
	}
	s.mu.Lock()
	fmt.Fprintf(s.logFile, "%s %s\n", UTCTimestamp(time.Now()), message)
	s.mu.Unlock()
}

func (s *Session) saveRecord(change func(*RunRecord)) {
	s.mu.Lock()
	if change != nil {
		change(&s.record)
	}
	snapshot := s.record
	s.mu.Unlock()
	if err := WriteRunRecord(&snapshot, s.Dir); err != nil {
		s.Log("writing run.json: " + err.Error())
	}
}

func (s *Session) sleepOrExit(d time.Duration) bool {
	select {
	case <-time.After(d):
		return false
	case <-s.exited:
		return true
	}
}

func (s *Session) attachQMP() {
	defer close(s.attached)
	if s.sleepOrExit(time.Until(s.started.Add(QMPConnectDelay))) {
		close(s.eventsDone)
		return
	}
	for {
		c, err := DialQMP(s.ws.QMPSocket(), 2*time.Second)
		if err == nil {
			s.mu.Lock()
			s.qmp = c
			s.mu.Unlock()
			s.saveRecord(func(r *RunRecord) { r.QMPReady = UTCTimestamp(time.Now()) })
			s.Log("QMP ready on " + s.ws.QMPSocket())
			go s.watchEvents(c)
			return
		}
		if time.Since(s.started) >= QMPConnectDeadline {
			s.Log(fmt.Sprintf("QMP not ready %d s after start: %v", int(QMPConnectDeadline.Seconds()), err))
			close(s.eventsDone)
			go s.RequestShutdown("no QMP, terminating QEMU")
			return
		}
		if s.sleepOrExit(QMPConnectRetry) {
			close(s.eventsDone)
			return
		}
	}
}

func (s *Session) watchEvents(c *QMPClient) {
	defer close(s.eventsDone)
	for ev := range c.Events {
		reason, _ := ev.Data["reason"].(string)
		if reason != "" {
			s.Log(fmt.Sprintf("QMP event %s (%s)", ev.Name, reason))
		} else {
			s.Log("QMP event " + ev.Name)
		}
		if ev.Name == "SHUTDOWN" && reason != "" {
			s.mu.Lock()
			s.shutdownReason = reason
			s.mu.Unlock()
		}
		if ev.Name == "POWERDOWN" {
			s.hostPowerdown()
		}
	}
}

func (s *Session) serveControl(l net.Listener) {
	for {
		conn, err := l.Accept()
		if err != nil {
			return
		}
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		line, _ := bufio.NewReader(conn).ReadString('\n')
		if strings.TrimSpace(line) == "shutdown" {
			s.RequestShutdown("shutdown requested on the control socket")
			fmt.Fprintf(conn, "ok %d\n", s.cmd.Process.Pid)
		} else {
			fmt.Fprintf(conn, "unknown request %q\n", strings.TrimSpace(line))
		}
		conn.Close()
	}
}

// RequestShutdown runs the ladder once in the background.
func (s *Session) RequestShutdown(reason string) {
	s.shutdownOnce.Do(func() {
		s.Log(reason)
		s.saveRecord(func(r *RunRecord) { r.ShutdownRequest = reason })
		go s.ladder(false)
	})
}

// HostCloseRequest is the run record's ShutdownRequest after Shut down in the
// FydeOS window's close prompt.
const HostCloseRequest = "host-close: Shut down chosen in the FydeOS window"

// hostPowerdown: a POWERDOWN the ladder did not cause comes from the runtime's
// close prompt, which pressed the power button once; the ladder finishes it.
// The ladder's own presses also emit POWERDOWN and land here after the Once.
func (s *Session) hostPowerdown() {
	s.shutdownOnce.Do(func() {
		s.Log(HostCloseRequest)
		s.saveRecord(func(r *RunRecord) { r.ShutdownRequest = HostCloseRequest })
		go s.ladder(true)
	})
}

func (s *Session) Pid() int { return s.cmd.Process.Pid }

// WaitQMP blocks until the supervisor holds the QMP connection, or says why it never will.
func (s *Session) WaitQMP() error {
	<-s.attached
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.qmp != nil {
		return nil
	}
	select {
	case <-s.exited:
		return errors.New("QEMU exited before QMP answered")
	default:
		return fmt.Errorf("QMP not ready %d s after start", int(QMPConnectDeadline.Seconds()))
	}
}

func (s *Session) qmpClient() *QMPClient {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.qmp
}

// PauseForSleep stops a running guest before the host sleeps; ResumeAfterWake
// continues it only if this stop paused it.
func (s *Session) PauseForSleep() {
	c := s.qmpClient()
	if c == nil {
		s.Log("host sleep: no QMP connection, not stopping the guest")
		return
	}
	raw, err := c.Execute("query-status", nil)
	var status struct {
		Running bool   `json:"running"`
		Status  string `json:"status"`
	}
	if err == nil {
		err = json.Unmarshal(raw, &status)
	}
	if err != nil {
		s.Log("host sleep: query-status: " + err.Error())
		return
	}
	if !status.Running {
		s.Log("host sleep: guest is " + status.Status + ", not stopping it")
		return
	}
	if _, err := c.Execute("stop", nil); err != nil {
		s.Log("host sleep: QMP stop failed: " + err.Error())
		return
	}
	s.mu.Lock()
	s.pausedForSleep = true
	s.mu.Unlock()
	s.Log("host sleep: QMP stop")
}

func (s *Session) ResumeAfterWake() {
	s.mu.Lock()
	ours := s.pausedForSleep
	s.pausedForSleep = false
	c := s.qmp
	s.mu.Unlock()
	if !ours {
		s.Log("host wake: no stop of ours to undo")
		return
	}
	if c == nil {
		return
	}
	if _, err := c.Execute("cont", nil); err != nil {
		s.Log("host wake: QMP cont failed: " + err.Error())
		return
	}
	s.Log("host wake: QMP cont")
}

// ladder: system_powerdown, again 2 s later, QMP quit at 20 s, TerminateProcess
// at 30 s. pressed: the first press already happened, so only the second is sent.
func (s *Session) ladder(pressed bool) {
	select {
	case <-s.attached:
	case <-s.exited:
		return
	}
	s.mu.Lock()
	c := s.qmp
	s.mu.Unlock()
	t0 := time.Now()
	if c != nil {
		if pressed {
			s.Log(fmt.Sprintf("power button pressed in the window; second system_powerdown in %d s, quit at %d s, TerminateProcess at %d s",
				int(PowerButtonRepeatDelay.Seconds()), int(QuitAfter.Seconds()), int(TerminateAfter.Seconds())))
		} else {
			s.Log(fmt.Sprintf("system_powerdown twice, %d s apart; quit at %d s, TerminateProcess at %d s",
				int(PowerButtonRepeatDelay.Seconds()), int(QuitAfter.Seconds()), int(TerminateAfter.Seconds())))
			if _, err := c.Execute("system_powerdown", nil); err != nil {
				s.Log("system_powerdown: " + err.Error())
			}
		}
		if s.sleepOrExit(PowerButtonRepeatDelay) {
			return
		}
		if _, err := c.Execute("system_powerdown", nil); err != nil {
			s.Log("second system_powerdown: " + err.Error())
		}
		if s.sleepOrExit(time.Until(t0.Add(QuitAfter))) {
			return
		}
		s.Log("quit")
		if _, err := c.Execute("quit", nil); err != nil {
			s.Log("quit: " + err.Error())
		}
		if s.sleepOrExit(time.Until(t0.Add(TerminateAfter))) {
			return
		}
	}
	s.Log(fmt.Sprintf("TerminateProcess pid %d", s.cmd.Process.Pid))
	s.mu.Lock()
	s.terminated = true
	s.mu.Unlock()
	s.cmd.Process.Kill()
}

// Wait blocks until QEMU exits, then completes run.json and removes the sockets.
func (s *Session) Wait() Exit {
	<-s.exited
	<-s.attached
	select {
	case <-s.eventsDone:
	case <-time.After(2 * time.Second):
	}
	s.mu.Lock()
	e := Exit{Code: s.cmd.ProcessState.ExitCode(), Reason: s.shutdownReason}
	if e.Reason == "" {
		e.Reason = "exited"
		if s.terminated {
			e.Reason = "terminated"
		}
	}
	c := s.qmp
	s.mu.Unlock()
	if c != nil {
		c.Close()
	}
	if s.control != nil {
		s.control.Close()
	}
	os.Remove(s.ws.QMPSocket())
	os.Remove(s.ws.ControlSocket())
	code := e.Code
	s.saveRecord(func(r *RunRecord) {
		r.End = UTCTimestamp(time.Now())
		r.ExitCode = &code
		r.Reason = e.Reason
	})
	s.Log(fmt.Sprintf("QEMU exit code %d (%s)", e.Code, e.Reason))
	s.logFile.Close()
	return e
}

// RequestRemoteShutdown asks the supervising process of the workspace's running VM to run the ladder.
func RequestRemoteShutdown(ws *Workspace) (string, error) {
	conn, err := net.DialTimeout("unix", ws.ControlSocket(), 5*time.Second)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write([]byte("shutdown\n")); err != nil {
		return "", err
	}
	reply, err := bufio.NewReader(conn).ReadString('\n')
	return strings.TrimSpace(reply), err
}
