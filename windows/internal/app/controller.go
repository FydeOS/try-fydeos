package app

import (
	"errors"
	"fmt"
	"time"

	"tryfydeos.io/windows/internal/core"
)

type Phase int

const (
	NotRunning Phase = iota
	Preparing
	Starting
	Running
	ShuttingDown
	Failed
)

func (p Phase) String() string {
	return [...]string{"notRunning", "preparing", "starting", "running", "shuttingDown", "failed"}[p]
}

// State is the start menu's state. Message belongs to NotRunning (optional) and
// Failed, Bytes/Total to Preparing, Since to Running.
type State struct {
	Phase   Phase
	Message string
	Bytes   int64
	Total   int64
	Since   time.Time
}

func (s State) Active() bool { return s.Phase != NotRunning && s.Phase != Failed }

func (s State) String() string {
	switch s.Phase {
	case Preparing:
		return fmt.Sprintf("preparing %d/%d", s.Bytes, s.Total)
	case NotRunning, Failed:
		if s.Message != "" {
			return s.Phase.String() + ": " + s.Message
		}
	}
	return s.Phase.String()
}

func (s State) StatusText() string {
	switch s.Phase {
	case NotRunning:
		if s.Message == "" {
			return L(StatusNotRunning)
		}
		return L(StatusNotRunningAfter, s.Message)
	case Preparing:
		if s.Total > 0 {
			return L(StatusUnpacking, int(min(1, float64(s.Bytes)/float64(s.Total))*100))
		}
		return L(StatusPreparing)
	case Starting:
		return L(StatusStarting)
	case Running:
		return L(StatusRunningSince, s.Since.Format("15:04"))
	case ShuttingDown:
		return L(StatusShuttingDown)
	default:
		return s.Message
	}
}

func (s State) LaunchTitle() string {
	switch s.Phase {
	case Preparing:
		return L(LaunchPreparing)
	case Starting:
		return L(LaunchStarting)
	case Running:
		return L(LaunchRunning)
	case ShuttingDown:
		return L(LaunchShuttingDown)
	default:
		return L(Launch)
	}
}

type EventKind int

const (
	EventPreparing EventKind = iota
	EventStarting
	EventRunning
	EventExited
	EventFailed
)

// Event is what the driver reports. EventExited and EventFailed both mean nothing runs any more.
type Event struct {
	Kind    EventKind
	Bytes   int64
	Total   int64
	Pid     int
	Exit    core.Exit
	Message string
}

func ExitDescription(e core.Exit) string { return fmt.Sprintf("exit code %d, %s", e.Code, e.Reason) }

// Driver runs the VM; events must be delivered on the UI thread.
type Driver interface {
	Launch(o core.LaunchOptions, events func(Event))
	ShutDown()
	PauseForSleep()
	ResumeAfterWake()
	FactoryReset() error
}

// Controller is the start menu's state machine. UI thread only.
type Controller struct {
	OnStateChange func(State)
	OnError       func(title, message string)
	OnReadyToQuit func()
	Now           func() time.Time

	state       State
	quitPending bool
	vmPid       int
	driver      Driver
}

func NewController(driver Driver, lastRun string) *Controller {
	return &Controller{driver: driver, Now: time.Now, state: State{Phase: NotRunning, Message: lastRun}}
}

func (c *Controller) State() State      { return c.state }
func (c *Controller) QuitPending() bool { return c.quitPending }

// VMPid is the QEMU process of the current run, from EventStarting until it exits.
func (c *Controller) VMPid() int { return c.vmPid }

func (c *Controller) setState(s State) {
	if s == c.state {
		return
	}
	c.state = s
	if c.OnStateChange != nil {
		c.OnStateChange(s)
	}
}

func (c *Controller) CanLaunch() bool       { return !c.state.Active() && !c.quitPending }
func (c *Controller) CanFactoryReset() bool { return !c.state.Active() && !c.quitPending }
func (c *Controller) CanShutDown() bool {
	return c.state.Phase == Starting || c.state.Phase == Running
}

func (c *Controller) Launch(o core.LaunchOptions) {
	if !c.CanLaunch() {
		return
	}
	c.setState(State{Phase: Preparing})
	c.driver.Launch(o, c.Handle)
}

func (c *Controller) ShutDown() {
	if !c.CanShutDown() {
		return
	}
	c.setState(State{Phase: ShuttingDown})
	c.driver.ShutDown()
}

// RequestQuit is true when the app may exit now; otherwise the VM is being
// stopped and OnReadyToQuit fires once nothing runs any more.
func (c *Controller) RequestQuit() bool {
	if !c.state.Active() {
		return true
	}
	c.quitPending = true
	c.ShutDown()
	return false
}

func (c *Controller) WillSleep() {
	if c.state.Phase == Running {
		c.driver.PauseForSleep()
	}
}

func (c *Controller) DidWake() {
	if c.state.Active() {
		c.driver.ResumeAfterWake()
	}
}

func (c *Controller) FactoryReset() error {
	if !c.CanFactoryReset() {
		return errors.New(L(ErrorBusy))
	}
	if err := c.driver.FactoryReset(); err != nil {
		return err
	}
	c.setState(State{Phase: NotRunning, Message: L(ResetDone)})
	return nil
}

func (c *Controller) Handle(ev Event) {
	switch ev.Kind {
	case EventPreparing:
		if c.state.Phase != Preparing {
			return
		}
		c.setState(State{Phase: Preparing, Bytes: ev.Bytes, Total: ev.Total})
	case EventStarting:
		if c.state.Phase != Preparing {
			return
		}
		c.vmPid = ev.Pid
		c.setState(State{Phase: Starting})
		if c.quitPending {
			c.ShutDown()
		}
	case EventRunning:
		if c.state.Phase != Starting {
			return
		}
		c.setState(State{Phase: Running, Since: c.Now()})
	case EventExited:
		c.vmPid = 0
		d := ExitDescription(ev.Exit)
		switch {
		case c.state.Phase == ShuttingDown:
			c.setState(State{Phase: NotRunning, Message: L(LastRunShutDown, d)})
		case ev.Exit.Code == 0:
			c.setState(State{Phase: NotRunning, Message: L(LastRunStopped, d)})
		default:
			c.fail(L(ErrorUnexpectedExit, d), L(ErrorAlertTitle))
		}
		c.finishQuit()
	case EventFailed:
		c.vmPid = 0
		c.fail(ev.Message, L(ErrorLaunchTitle))
		c.finishQuit()
	}
}

func (c *Controller) fail(message, title string) {
	c.setState(State{Phase: Failed, Message: message})
	if !c.quitPending && c.OnError != nil {
		c.OnError(title, message)
	}
}

func (c *Controller) finishQuit() {
	if c.quitPending && c.OnReadyToQuit != nil {
		c.OnReadyToQuit()
	}
}

// LastRunMessage describes a finished run record for the status line of a fresh start.
func LastRunMessage(r *core.RunRecord) string {
	if r == nil || r.ExitCode == nil {
		return ""
	}
	d := ExitDescription(core.Exit{Code: *r.ExitCode, Reason: r.Reason})
	switch {
	case r.ShutdownRequest != "":
		return L(LastRunShutDown, d)
	case *r.ExitCode == 0:
		return L(LastRunStopped, d)
	default:
		return L(ErrorUnexpectedExit, d)
	}
}
