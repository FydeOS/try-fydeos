package app

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"tryfydeos.io/windows/internal/core"
)

// AppLog appends timestamped lines to <logs>\TryFydeOS.log.
type AppLog struct {
	Path string
	mu   sync.Mutex
	f    *os.File
}

func OpenAppLog(dir string) *AppLog {
	l := &AppLog{Path: filepath.Join(dir, "TryFydeOS.log")}
	if os.MkdirAll(dir, 0o700) == nil {
		l.f, _ = os.OpenFile(l.Path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	}
	return l
}

func (l *AppLog) Write(message string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f != nil {
		fmt.Fprintf(l.f, "%s [%d] %s\n", core.UTCTimestamp(time.Now()), os.Getpid(), message)
	}
}

func (l *AppLog) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f != nil {
		l.f.Close()
		l.f = nil
	}
}

// CoreDriver runs core sessions on a goroutine. It holds the storage lock from
// launch until the run ends, relaunching QEMU in between when the guest reboots.
type CoreDriver struct {
	Locations *core.Locations
	Host      core.HostInfo
	Log       *AppLog
	// Post runs f on the UI thread.
	Post func(f func())

	mu       sync.Mutex
	session  *core.Session
	stopping bool
}

func (d *CoreDriver) Workspace() *core.Workspace { return &core.Workspace{Dir: d.Locations.Workspace} }

func (d *CoreDriver) current() *core.Session {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.session
}

// Pid is the running QEMU process, 0 between runs.
func (d *CoreDriver) Pid() int {
	if s := d.current(); s != nil {
		return s.Pid()
	}
	return 0
}

func (d *CoreDriver) Launch(o core.LaunchOptions, events func(Event)) {
	deliver := func(ev Event) { d.Post(func() { events(ev) }) }
	d.mu.Lock()
	d.stopping = false
	d.mu.Unlock()
	go func() {
		if err := d.run(o, deliver); err != nil {
			d.Log.Write("launch failed: " + err.Error())
			deliver(Event{Kind: EventFailed, Message: err.Error()})
		}
	}()
}

func (d *CoreDriver) run(o core.LaunchOptions, deliver func(Event)) error {
	loc, ws := d.Locations, d.Workspace()
	d.Log.Write(fmt.Sprintf("launch %d CPUs, %d MiB, full screen %t, microphone %t, forwards %v, workspace %s",
		o.CPUs, o.MemoryMiB, o.FullScreen, o.Microphone, o.HostForwards, ws.Dir))
	lock, err := ws.Open(core.RequiredFilesystems...)
	if err != nil {
		return err
	}
	defer lock.Release()
	m, _, err := loc.PrepareWorkspace(ws, lock, d.Log.Write, func(stage core.PrepareStage, done, total int64) {
		deliver(Event{Kind: EventPreparing, Stage: stage, Bytes: done, Total: total})
	})
	if err != nil {
		return err
	}
	for {
		s, err := core.Launch(o, loc, ws, lock, m, d.Host, func(msg string) { d.Log.Write("run: " + msg) })
		if err != nil {
			return err
		}
		d.mu.Lock()
		d.session = s
		stopping := d.stopping
		d.mu.Unlock()
		if stopping {
			s.RequestShutdown("shutdown requested by the app")
		}
		deliver(Event{Kind: EventStarting, Pid: s.Pid()})
		if err := s.WaitQMP(); err != nil {
			e := s.Wait()
			d.setSession(nil)
			deliver(Event{Kind: EventFailed, Message: L(ErrorNotReady, err.Error(), ExitDescription(e))})
			return nil
		}
		deliver(Event{Kind: EventRunning})
		e := s.Wait()
		d.setSession(nil)
		d.mu.Lock()
		stopping = d.stopping
		d.mu.Unlock()
		if e.GuestReset() && !stopping {
			d.Log.Write("guest rebooted; relaunching QEMU")
			time.Sleep(time.Second)
			continue
		}
		deliver(Event{Kind: EventExited, Exit: e})
		return nil
	}
}

func (d *CoreDriver) setSession(s *core.Session) {
	d.mu.Lock()
	d.session = s
	d.mu.Unlock()
}

func (d *CoreDriver) ShutDown() {
	d.mu.Lock()
	d.stopping = true
	s := d.session
	d.mu.Unlock()
	if s != nil {
		s.RequestShutdown("shutdown requested by the app")
	}
}

func (d *CoreDriver) PauseForSleep() {
	if s := d.current(); s != nil {
		s.PauseForSleep()
	}
}

func (d *CoreDriver) ResumeAfterWake() {
	if s := d.current(); s != nil {
		s.ResumeAfterWake()
	}
}

func (d *CoreDriver) CheckRelease(events func(Event)) {
	go func() {
		spec, err := d.Locations.LoadSpec()
		if err != nil {
			d.Log.Write("release check: " + err.Error())
			return
		}
		r, err := core.FetchRelease(context.Background(), spec.Release.API, spec.Release.Board, d.Locations.AppVersion)
		if err != nil {
			d.Log.Write("release check: " + err.Error())
			return
		}
		d.Log.Write(fmt.Sprintf("release check: %s %s (%s), sha256 %s", r.FileName, r.Version, r.ReleaseDate, r.SHA256))
		d.Post(func() { events(Event{Kind: EventRelease, Release: r}) })
	}()
}

func (d *CoreDriver) PreparedFactory() (core.FactoryRecord, bool) {
	ws := d.Workspace()
	if !ws.IsPrepared() {
		return core.FactoryRecord{}, false
	}
	m, err := ws.LoadMetadata()
	if err != nil {
		return core.FactoryRecord{}, false
	}
	return m.Factory, true
}

func (d *CoreDriver) FactoryReset() error {
	ws := d.Workspace()
	if state, why := ws.State(); state == core.WorkspaceForeign {
		return fmt.Errorf("refusing to reset %s: %s", ws.Dir, why)
	} else if state != core.WorkspaceMarked {
		return nil
	}
	lock, err := ws.Open()
	if err != nil {
		return err
	}
	defer lock.Release()
	if err := ws.Reset(lock); err != nil {
		return err
	}
	d.Log.Write("factory reset " + ws.Dir)
	return nil
}
