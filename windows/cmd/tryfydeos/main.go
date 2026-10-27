package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"tryfydeos.io/windows/internal/core"
	"tryfydeos.io/windows/internal/payload"
)

type usageError string

func (e usageError) Error() string { return string(e) }

const usage = `usage: tryfydeos <command> [options]

  doctor                      check host, WHPX, runtime, firmware, factory image, workspace
  prepare                     unpack the FydeOS image into the VM disk
  run [vm options]            prepare if needed, boot the VM, supervise until QEMU exits
  inspect [vm options]        print the QEMU argv run would use, one argument per line
  shutdown                    ask the running VM's supervisor for the powerdown ladder
  reset --yes                 delete disk.raw, efi-vars.fd and metadata.json

vm options: --cpus N (4)  --memory-mib MiB (8192)  --full-screen  --cpu-fallback
            --forward HOSTPORT:GUESTPORT (repeatable, 127.0.0.1 only)
all commands: --workspace DIR (default %LOCALAPPDATA%\Try FydeOS\VM\v1)
              --runtime DIR (default runtime\ next to the exe)  --spec FILE
              --exe FILE (packaged "Try FydeOS.exe" whose payload supplies runtime, spec and image)`

type options struct {
	loc    *core.Locations
	launch core.LaunchOptions
	yes    bool
}

func parseOptions(args []string, allowed map[string]bool) (*options, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	for i, arg := range args {
		if arg == "--exe" && i+1 < len(args) {
			if exe, err = filepath.Abs(args[i+1]); err != nil {
				return nil, err
			}
		}
	}
	p, err := payload.Open(exe)
	if errors.Is(err, payload.ErrNoPayload) {
		p = nil
	} else if err != nil {
		return nil, err
	}
	loc, err := core.DiscoverLocations(os.Getenv, filepath.Dir(exe), p)
	if err != nil {
		return nil, err
	}
	o := &options{loc: loc, launch: core.LaunchOptions{CPUs: 4, MemoryMiB: 8192}}
	var forwards []core.HostForward
	for i := 0; i < len(args); i++ {
		arg := args[i]
		global := arg == "--workspace" || arg == "--runtime" || arg == "--spec" || arg == "--exe"
		if !allowed[arg] && !global {
			return nil, usageError("unknown option " + arg)
		}
		value := func() (string, error) {
			if i+1 >= len(args) {
				return "", usageError(arg + " needs a value")
			}
			i++
			return args[i], nil
		}
		integer := func() (int, error) {
			v, err := value()
			if err != nil {
				return 0, err
			}
			n, err := strconv.Atoi(v)
			if err != nil {
				return 0, usageError(fmt.Sprintf("%s needs an integer, got '%s'", arg, v))
			}
			return n, nil
		}
		var v string
		switch arg {
		case "--workspace", "--runtime", "--spec":
			if v, err = value(); err == nil {
				v, err = filepath.Abs(v)
			}
			switch arg {
			case "--workspace":
				o.loc.Workspace = v
			case "--runtime":
				o.loc.Runtime = v
			case "--spec":
				o.loc.Spec = v
			}
		case "--exe":
			_, err = value()
		case "--cpus":
			o.launch.CPUs, err = integer()
		case "--memory-mib":
			o.launch.MemoryMiB, err = integer()
		case "--full-screen":
			o.launch.FullScreen = true
		case "--cpu-fallback":
			o.launch.CPUFallback = true
		case "--forward":
			if v, err = value(); err == nil {
				var f core.HostForward
				if f, err = core.ParseHostForward(v); err == nil {
					forwards = append(forwards, f)
				}
			}
		case "--yes":
			o.yes = true
		}
		if err != nil {
			return nil, err
		}
	}
	o.launch.HostForwards = o.loc.Forwards
	if forwards != nil {
		o.launch.HostForwards = forwards
	}
	return o, nil
}

func (o *options) workspace() *core.Workspace { return &core.Workspace{Dir: o.loc.Workspace} }

func say(message string) { fmt.Fprintf(os.Stderr, "tryfydeos: %s\n", message) }

func report(state, what string) { fmt.Printf("%-8s %s\n", state, what) }

func prepare(ws *core.Workspace, lock *core.StorageLock, loc *core.Locations) (*core.Metadata, error) {
	m, spec, err := loc.PrepareWorkspace(ws, lock, say, func(written, total int64) {
		say(fmt.Sprintf("unpacking the FydeOS image: %d%%", written*100/total))
	})
	if err != nil {
		return nil, err
	}
	if m.Factory.SHA256 != spec.Image.SHA256 {
		say(fmt.Sprintf("note: this VM was prepared from factory %.12s; spec now pins %.12s (reset to switch)", m.Factory.SHA256, spec.Image.SHA256))
	}
	return m, nil
}

func cmdDoctor(o *options) (int, error) {
	failed := false
	check := func(ok bool, what string, missing bool) {
		state := "ok"
		if !ok {
			failed = true
			state = "FAIL"
			if missing {
				state = "missing"
			}
		}
		report(state, what)
	}
	host := core.CurrentHost()
	check(host.NativeMachine == "amd64", "x86-64 Windows (native machine "+host.NativeMachine+")", false)
	if host.WHPXInstalled {
		report("info", "Windows Hypervisor Platform feature installed (WinHvPlatform.dll loads)")
	} else {
		report("info", "Windows Hypervisor Platform feature not installed (WinHvPlatform.dll missing)")
	}
	check(host.WHPXPresent, "WHPX: hypervisor running (WHvGetCapability HypervisorPresent)", false)
	report("info", fmt.Sprintf("host %d logical CPUs, %d MiB; VM range cpus %d...%d, memory %d...%d MiB",
		host.LogicalCPUs, host.MemoryMiB, core.MinCPUs, host.LogicalCPUs, core.MinMemoryMiB, host.MemoryMiB-core.HostReserveMiB))
	loc := o.loc
	if p := loc.Payload; p != nil {
		report("info", fmt.Sprintf("payload in %s at offset %d:", p.Path, p.Start))
		for _, e := range p.Entries {
			report("info", fmt.Sprintf("  %-12s %11d bytes  sha256 %s", e.Name, e.Length, e.SHA256))
		}
	} else {
		report("info", "no payload (development build): runtime, spec and image from files")
	}
	if loc.RuntimeFromPayload() && !loc.RuntimeExtracted() {
		report("info", fmt.Sprintf("runtime %s not extracted yet (the first launch or prepare extracts it)", loc.Runtime))
	} else {
		if loc.RuntimeFromPayload() {
			report("info", "runtime extracted from the payload into "+loc.Runtime)
		}
		if out, err := exec.Command(loc.QEMU(), "-version").Output(); err == nil {
			check(true, fmt.Sprintf("runtime %s: %s", loc.QEMU(), strings.SplitN(string(out), "\n", 2)[0]), false)
			if b := loc.RuntimeBuild(); b != "" {
				report("info", "runtime build: "+b)
			}
		} else {
			_, statErr := os.Stat(loc.QEMU())
			check(false, fmt.Sprintf("runtime %s: %v", loc.QEMU(), err), statErr != nil)
		}
		for _, f := range []string{loc.FirmwareCode(), loc.VarsTemplate()} {
			_, err := os.Stat(f)
			check(err == nil, "firmware "+f, err != nil)
		}
	}
	spec, err := loc.LoadSpec()
	if err != nil {
		check(false, "factory spec "+loc.SpecName()+": "+err.Error(), errors.Is(err, os.ErrNotExist))
	} else {
		report("info", fmt.Sprintf("factory spec %s: %s %s %s", loc.SpecName(), spec.Image.File, spec.Image.Version, spec.Board))
		report("info", fmt.Sprintf("factory raw %d bytes, sha256 %s; VM disk %d bytes (sparse)", spec.Image.RawBytes, spec.Image.RawSHA256, spec.DiskBytes))
		if image, err := loc.OpenFactoryImage(spec); err == nil {
			image.Close()
			check(image.Size == spec.Image.Bytes, fmt.Sprintf("factory image %s (%d bytes, spec says %d)", image.Name, image.Size, spec.Image.Bytes), false)
		} else {
			check(false, err.Error(), true)
		}
	}
	ws := o.workspace()
	fs, free, ferr := core.VolumeInfo(ws.Dir)
	fsOK := false
	for _, want := range core.RequiredFilesystems {
		fsOK = fsOK || strings.EqualFold(fs, want)
	}
	where := fmt.Sprintf("on %s, %.1f GB free", fs, float64(free)/1e9)
	if ferr != nil {
		where = "filesystem unknown: " + ferr.Error()
	}
	switch state, why := ws.State(); state {
	case core.WorkspaceAbsent:
		check(fsOK, fmt.Sprintf("workspace %s absent (prepare creates it), %s", ws.Dir, where), false)
	case core.WorkspaceEmpty:
		check(fsOK, fmt.Sprintf("workspace %s empty, %s", ws.Dir, where), false)
	case core.WorkspaceMarked:
		check(fsOK, fmt.Sprintf("workspace %s %s, prepared: %t, in use: %t", ws.Dir, where, ws.IsPrepared(), ws.IsLocked()), false)
	default:
		check(false, fmt.Sprintf("workspace %s: %s", ws.Dir, why), false)
	}
	if failed {
		return 1, nil
	}
	return 0, nil
}

func cmdPrepare(o *options) (int, error) {
	ws := o.workspace()
	lock, err := ws.Open(core.RequiredFilesystems...)
	if err != nil {
		return 1, err
	}
	defer lock.Release()
	m, err := prepare(ws, lock, o.loc)
	if err != nil {
		return 1, err
	}
	fmt.Printf("prepared %s\n", ws.Dir)
	fmt.Printf("factory %s sha256 %s\n", m.Factory.File, m.Factory.SHA256)
	fmt.Printf("disk %s %d bytes\n", ws.Disk(), m.DiskBytes)
	fmt.Printf("mac %s created %s\n", m.MAC, m.Created)
	return 0, nil
}

func cmdInspect(o *options) (int, error) {
	ws := o.workspace()
	mac := "52:54:00:00:00:00"
	if m, err := ws.LoadMetadata(); err == nil {
		mac = m.MAC
	}
	argv, err := o.launch.Config(o.loc, ws, filepath.Join(ws.RunsDir(), "<run-id>"), mac).Argv(core.CurrentHost())
	if err != nil {
		return 1, err
	}
	for _, a := range argv {
		fmt.Println(a)
	}
	return 0, nil
}

func cmdRun(o *options) (int, error) {
	ws := o.workspace()
	lock, err := ws.Open(core.RequiredFilesystems...)
	if err != nil {
		return 1, err
	}
	defer lock.Release()
	m, err := prepare(ws, lock, o.loc)
	if err != nil {
		return 1, err
	}
	var mu sync.Mutex
	var current *core.Session
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt)
	go func() {
		for range interrupts {
			mu.Lock()
			if current != nil {
				current.RequestShutdown("received interrupt, shutting down")
			}
			mu.Unlock()
		}
	}()
	for {
		s, err := core.Launch(o.launch, o.loc, ws, lock, m, core.CurrentHost(), say)
		if err != nil {
			return 1, err
		}
		mu.Lock()
		current = s
		mu.Unlock()
		e := s.Wait()
		if !e.GuestReset() {
			return e.Code, nil
		}
		say("guest rebooted; relaunching QEMU")
		time.Sleep(time.Second)
	}
}

func cmdShutdown(o *options) (int, error) {
	ws := o.workspace()
	if !ws.IsLocked() {
		fmt.Println("not running")
		return 0, nil
	}
	reply, err := core.RequestRemoteShutdown(ws)
	if err != nil {
		return 1, fmt.Errorf("storage is locked but the supervisor's control socket did not answer: %w", err)
	}
	if !strings.HasPrefix(reply, "ok") {
		return 1, fmt.Errorf("supervisor refused: %s", reply)
	}
	say("supervisor accepted; QEMU pid " + strings.TrimSpace(strings.TrimPrefix(reply, "ok")) + " is shutting down")
	start := time.Now()
	for ws.IsLocked() && time.Since(start) < 60*time.Second {
		time.Sleep(200 * time.Millisecond)
	}
	if ws.IsLocked() {
		return 1, errors.New("still running after 60 s")
	}
	_, r, err := ws.LastRun()
	if err != nil || r.ExitCode == nil {
		fmt.Printf("stopped after %.1f s\n", time.Since(start).Seconds())
		return 0, nil
	}
	fmt.Printf("stopped after %.1f s: exit code %d, reason %s\n", time.Since(start).Seconds(), *r.ExitCode, r.Reason)
	return 0, nil
}

func cmdReset(o *options) (int, error) {
	if !o.yes {
		return 2, usageError("reset deletes the VM disk; pass --yes")
	}
	ws := o.workspace()
	if state, why := ws.State(); state != core.WorkspaceMarked {
		if why == "" {
			why = "not marked"
		}
		return 2, usageError(fmt.Sprintf("%s is not a Try FydeOS workspace (%s)", ws.Dir, why))
	}
	lock, err := ws.Open()
	if err != nil {
		return 1, err
	}
	defer lock.Release()
	if err := ws.Reset(lock); err != nil {
		return 1, err
	}
	fmt.Printf("reset %s: disk.raw, efi-vars.fd and metadata.json removed; runs\\ kept\n", ws.Dir)
	return 0, nil
}

func main() {
	vmFlags := map[string]bool{"--cpus": true, "--memory-mib": true, "--full-screen": true, "--cpu-fallback": true, "--forward": true}
	commands := map[string]struct {
		flags map[string]bool
		run   func(*options) (int, error)
	}{
		"doctor": {nil, cmdDoctor}, "prepare": {nil, cmdPrepare}, "run": {vmFlags, cmdRun},
		"inspect": {vmFlags, cmdInspect}, "shutdown": {nil, cmdShutdown}, "reset": {map[string]bool{"--yes": true}, cmdReset},
	}
	args := os.Args[1:]
	if len(args) == 0 {
		fmt.Println(usage)
		os.Exit(2)
	}
	cmd, ok := commands[args[0]]
	if !ok {
		fmt.Println(usage)
		if args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
			os.Exit(0)
		}
		os.Exit(2)
	}
	o, err := parseOptions(args[1:], cmd.flags)
	code := 2
	if err == nil {
		code, err = cmd.run(o)
	}
	if err != nil {
		say(err.Error())
		var u usageError
		if errors.As(err, &u) {
			code = 2
		} else if code == 0 {
			code = 1
		}
	}
	os.Exit(code)
}
