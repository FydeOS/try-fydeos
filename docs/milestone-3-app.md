# Milestone 3: app

Date: 2026-10-16. Host: Apple M4, 10 cores, 24 GiB, macOS 27.0.1, Swift 6.4
(Command Line Tools). Runtime and firmware from milestone 1. Factory spec at
build time: `fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin`
(sha256 `22587891…`, kernel patch 025).

Everything was run over ssh in `~/Workspace/try-fydeos`. The app was pointed
at the milestone 2 workspace, never at the default `VM/v1`:

```sh
defaults write io.fydeos.tryfydeos workspace "$HOME/Library/Application Support/Try FydeOS/VM/m2"
```

`VM/m2` was cloned from the previous factory image (`34cc093f…`). `prepare`
leaves a prepared workspace alone, so the app booted it unchanged.

## What was built

| Piece | Where |
|---|---|
| Shared run logic: `LaunchOptions`, `Workspace.prepare(lock:locations:)`, `VMSession` (run directory, supervisor.log, run.json, spawn, QMP wait, ladder once per level, sleep `stop`/`cont`) | `macos/Sources/TryFydeOSCore/Session.swift` |
| Bundle-aware lookup: `Contents/Resources` first, then the repository layout; `TRY_FYDEOS_*` variables override either | `Locations.swift` |
| CLI moved onto `VMSession` (same output and behaviour) | `TryFydeOSCLI/main.swift` |
| AppKit-free app logic: string table, preferences, `AppController` state machine, `CoreVMDriver`, app log | `macos/Sources/TryFydeOSAppModel/` |
| AppKit app: start menu window, menus, sleep/wake observers, quit handling | `macos/Sources/TryFydeOSApp/` (product `TryFydeOSApp`) |
| Info.plist, app entitlements (audio-input, no sandbox), icon SVG | `macos/Resources/` |
| Icon render (qlmanage → sips → iconutil; rsvg-convert when installed) | `macos/scripts/make-icon.sh` |
| Bundle assembly and signing | `macos/scripts/build-app.sh` |
| `make icon`, `make app` (`APP_ARGS=--no-image`), `make app-run` | `Makefile` |

The app's run logic and the CLI's are the same code, `VMSession`. The app
runs it on a background thread and does not spawn the CLI.

App behaviour:

- Starts with the regular activation policy and shows the start menu. The
  CPU choices are 4 to the host's core count (default min(8, cores)).
  Memory runs from 4 GB to host minus 4 GB in 1 GB steps (default 8 GB on
  hosts with 16 GiB or more, else 4 GB). The window also has Full screen,
  Microphone, Launch, Shut Down, Logs, Factory Reset… (type
  "Try FydeOS" to enable Erase), Quit, a status line and the dismissible
  zoom note. Preferences persist in `io.fydeos.tryfydeos`.
- On `starting` (QEMU spawned) the window is hidden and the app switches to
  accessory. When QEMU exits, the app goes back to regular and the window
  shows the reason. Reopening the app while the VM runs brings the window
  back, with Shut Down enabled.
- Quit (Cmd-Q, Quit button, menu, the `quit` AppleEvent, SIGTERM/SIGINT/SIGHUP)
  while a VM is active returns `terminateLater`, runs the ladder, and replies
  only after QEMU has been reaped.
- The storage lock is taken at the first Launch or Factory Reset and held
  until the app exits.
- On `NSWorkspace.willSleep` the app sends QMP `stop` synchronously, but only
  if the guest is running. On `didWake` it sends `cont` only for its own
  stop. Both are logged to the run's `supervisor.log`.
- `~/Library/Logs/Try FydeOS/TryFydeOS.log` is the app log, and `VM runs` in
  that folder is a symlink to the workspace's `runs/`, so the Logs button
  reaches console.log.
- Hidden test hooks:
  - `workspace` default or `TRY_FYDEOS_WORKSPACE`: workspace override.
  - `open "dist/Try FydeOS.app" --args -autoLaunch YES [-cpus 4]`: launches
    without a click. It lives in the argument domain only, so nothing is
    persisted.

## Build and tests

```
$ swift build                      Build complete!
$ swift test                       Test run with 24 tests in 0 suites passed   (TryFydeOSCoreTests)
                                   Test run with 18 tests in 0 suites passed   (TryFydeOSAppModelTests)
$ make test                        Ran 11 tests … OK  (Python) + the two Swift runs above
```

New tests:

- Core: 2 for `Locations` (bundle beats an enclosing repo; repo layout
  plus environment overrides).
- App model: 7 for preferences and strings (choices, host-dependent
  defaults, clamping, persistence and re-clamping on a smaller host,
  workspace override order, launch options, string table completeness).
- App model: 11 for the controller state machine (full cycle, guest
  power-off, unexpected exit, prepare failure, quit while idle, running,
  preparing and preparing-then-failing, sleep only when running, factory
  reset only when idle, status texts).

The first `swift build` failed with
`error: unable to open dependencies file (…/TryFydeOS.build/Debug/TryFydeOS-p.build/…/AppDelegate.d)`.
The app product `TryFydeOS` and the CLI product `tryfydeos` differ only in
case, and on the case-insensitive volume they share `tryfydeos-p.build`
(and would share the binary path). The SwiftPM product is therefore
`TryFydeOSApp`; build-app.sh installs it as `Contents/MacOS/TryFydeOS`.

## Bundle

`make app` (1 min 35 s with the image clone):

```
build-app: cloning fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin
build-app: signing with identity '-'
…/dist/Try FydeOS.app: valid on disk
…/dist/Try FydeOS.app: satisfies its Designated Requirement
build-app: ok: /Users/fydeos/Workspace/try-fydeos/dist/Try FydeOS.app (7.1G logical)
```

Signing order: 15 dylibs and `zstd`, then QEMU with
`runtime/entitlements/qemu.entitlements`, then `Contents/MacOS/TryFydeOS`
and the bundle with `TryFydeOS.entitlements`. No `--deep`. The script then
runs `codesign --verify --strict` on the bundle and on QEMU, and asserts:

- the hypervisor entitlement on QEMU;
- audio-input on the app;
- `TryFydeOS.icns` three levels above the QEMU binary.

```
$ codesign -d --entitlements - "dist/Try FydeOS.app/Contents/Resources/runtime/bin/qemu-system-aarch64"
	[Key] com.apple.security.device.audio-input   [Bool] true
	[Key] com.apple.security.hypervisor           [Bool] true
$ codesign -dv "dist/Try FydeOS.app"
Identifier=io.fydeos.tryfydeos  Format=app bundle with Mach-O thin (arm64)  Signature=adhoc
$ plutil -extract CFBundleIconFile raw "dist/Try FydeOS.app/Contents/Info.plist"
TryFydeOS
```

`Contents/Resources` holds `TryFydeOS.icns` (185 KB, 1024 px with alpha,
transparent corners), `runtime/` (17 files), `firmware/` (the two `.fd`),
and `factory/` (`spec.json` and the APFS-cloned image).

**First launch after each build stalls about 45 s in `_dyld_start`.** The
first `open` sat in `_dyld_start` (per `sample`) from 15:41:56 to 15:42:44.
After a rebuild it took 07:51:08 → 07:51:56. A relaunch of the same build
took under 1 s (07:48:25 → 07:48:25). This is consistent with the system
assessing the new signature, which seals the 7 GB image as a bundle
resource. That cause is inferred, not measured.

## Run from the app

`osascript` GUI scripting is blocked over ssh:

```
System Events got an error: osascript is not allowed assistive access. (-1728)
```

Launch was therefore driven with the `-autoLaunch` hook. The `quit`
AppleEvent (`osascript -e 'quit app id "io.fydeos.tryfydeos"'`) is allowed.

Run `20261016T074629Z` (`open … --args -autoLaunch YES -cpus 4`):

```
  PID  PPID  PGID STAT COMM
60001     1 60001 S    …/dist/Try FydeOS.app/Contents/MacOS/TryFydeOS
60075 60001 60075 Rs   …/dist/Try FydeOS.app/Contents/Resources/runtime/bin/qemu-system-aarch64

qemu-syst 60075 fydeos    7u   REG  …  …/VM/m2/.lock
qemu-syst 60075 fydeos   14u  unix …  …/VM/m2/qmp.sock
qemu-syst 60075 fydeos   16u   REG  1,13 7482718720 …  …/VM/m2/disk.img
TryFydeOS 60001 fydeos    4u   REG  …  …/VM/m2/.lock
TryFydeOS 60001 fydeos    5w   REG  …  …/VM/m2/runs/20261016T074629Z/supervisor.log
```

`TryFydeOS.log`:

```
07:46:29Z [60001] autoLaunch requested on the command line
07:46:29Z [60001] state preparing
07:46:29Z [60001] run: run 20261016T074629Z: QEMU pid 60075, logs in …/VM/m2/runs/20261016T074629Z
07:46:29Z [60001] state starting
07:46:29Z [60001] run: QMP ready on …/VM/m2/qmp.sock
07:46:29Z [60001] state running(since: 2026-10-16 07:46:29 +0000)
```

While running, `lsappinfo` listed the app as `type="UIElement"` (accessory).
At idle before the launch it was `type="Foreground"`. `qemu.log` has
`GL strings: version='OpenGL 4.1 (Metal)' renderer='Apple M4' glsl='4.10'`
and `FINAL VALUES: glsl_level=410, max_samples=4`. `console.log` matches
milestone 2:

```
[    0.000000] ACPI: SPCR: console: pl011,mmio32,0x9000000,9600
[    0.006981] printk: legacy console [ttyAMA0] enabled
[    0.126853] input: QEMU Virtio Tablet as /devices/pci0000:00/0000:00:05.0/virtio4/input/input2
[    0.129153] [drm] features: +virgl +edid -resource_blob -host_visible
[    0.134111] virtio_blk virtio0: [vda] 14614685 512-byte logical blocks (7.48 GB/6.97 GiB)
[    0.323872] frecon[242]: Frecon using drm driver virtio_gpu, version 0.1, date(0), desc(virtio GPU)
```

`ui main process … terminated`: 0 occurrences. `tryfydeos status` reported
`query-status: {"running":true,"status":"running"}` and supervisor pid 60001.

**Dock name: not confirmed; LaunchServices registers QEMU as
`qemu-system-aarch64`.** LaunchServices lists QEMU as
`"qemu-system-aarch64" … type="Foreground"`, with bundle path = the binary.
The app's own entry is `"Try FydeOS" bundleID="io.fydeos.tryfydeos"`.
`screencapture` failed (`could not create image from display`), so what the
Dock shows was not seen. The identity patch calls `setProcessName` after
`TransformProcessType`, so the LaunchServices check-in carries the binary
name. If the Dock label reads `qemu-system-aarch64`, the fix belongs in
`runtime/overlay/qemu-cocoa-product-identity.patch`, not in the app.

### Quit via AppleEvent

```
07:47:53.04 osascript quit app id "io.fydeos.tryfydeos"   (returned 07:48:13, rc 0)
```

`supervisor.log`:

```
2026-10-16T07:47:53Z shutdown requested by the app
2026-10-16T07:47:53Z system_powerdown, waiting 20 s
2026-10-16T07:47:53Z QMP event POWERDOWN
2026-10-16T07:48:13Z quit, waiting 5 s
2026-10-16T07:48:13Z QMP event SHUTDOWN
2026-10-16T07:48:13Z QEMU exit code 0
```

`run.json`: `"end" : "2026-10-16T07:48:13Z", "exitCode" : 0, "pid" : 60075, "supervisorPid" : 60001`.
The app log ends with `QEMU exit code 0`, then `state notRunning(…"Last run
shut down by Try FydeOS (exit code 0).")`, `VM stopped, terminating`, `app exiting`.

### Quit via SIGTERM: one defect found and fixed

The first SIGTERM run (`20261016T074825Z`) failed: QEMU exited at 07:48:57,
but the app stayed in `shuttingDown` and did not exit. The app was killed
by hand; its run.json had already been completed.

Cause: the signal handler is a main-queue GCD block that called
`NSApp.terminate`. `terminateLater` spins a nested run loop inside that
block. The driver's exit event is also a main-queue block, so it could not
run until the handler returned. The handler now schedules terminate with
`performSelector(onMainThread:)`.

After rebuilding, run `20261016T075156Z`:

```
07:52:07 app=61806 qemu=62593      (kill -TERM 61806)
07:52:28 app=gone qemu=gone        (polled every 0.5 s)
```

```
07:52:07Z [61806] received signal 15, quitting
07:52:07Z [61806] state shuttingDown
07:52:07Z [61806] quit requested while the VM runs; running the shutdown ladder
07:52:28Z [61806] state notRunning(Optional("Last run shut down by Try FydeOS (exit code 0)."))
07:52:28Z [61806] VM stopped, terminating
07:52:28Z [61806] app exiting
```

`supervisor.log` ends `07:52:27Z quit, waiting 5 s` / `QMP event SHUTDOWN` /
`07:52:28Z QEMU exit code 0`. `run.json`: `"end" : "2026-10-16T07:52:28Z", "exitCode" : 0`.

### QEMU exiting on its own

Run `20261016T075242Z`: `tryfydeos shutdown --force` stopped the app's QEMU
from outside. The CLI does not recognise the app as a supervisor, so it
adopted QEMU directly. The app logged:

```
07:52:49Z [63328] run: QEMU exit code 0
07:52:49Z [63328] state notRunning(Optional("Last run: FydeOS stopped (exit code 0)."))
```

`lsappinfo` then showed the app `(in front)`. A `quit` AppleEvent ended it
at once (`app exiting`). The CLI's own late `run.json` write dropped the
`exitCode` that the app had written. That is a pre-existing race in the
CLI's adopt path.

## Not verified

- Any click in the window: Launch button, Shut Down button, Logs, Factory
  Reset sheet, first-run note dismissal, popups, Cmd-W, About panel. Wei
  needs to click these.
- Host sleep and wake: the Mac was not put to sleep. The `stop`/`cont` path
  is covered by unit tests at the controller level only.
- What the Dock and menu bar show for the QEMU window (see above).
- Microphone opt-in and its TCC prompt.
- Whether the first-launch stall comes from the sealed 7 GB resource. To
  check, compare against a `--no-image` bundle.

## Deviations from design.md

- The SwiftPM product is `TryFydeOSApp`, not `TryFydeOS`, because of the
  case clash with the `tryfydeos` CLI. The bundle executable is still
  `TryFydeOS`.
- Sleep uses `NSWorkspace` willSleep/didWake, not an IOKit power
  notification. The `stop` is sent before the notification handler
  returns, but macOS does not wait for it the way an IOKit
  `IOAllowPowerChange` handshake would.
- The storage lock is taken at the first Launch or Factory Reset, not at
  app start, so a foreign default workspace shows up as an error on Launch
  rather than at startup.
- The bundle has no zstd-compressed factory image and no scripts; the raw
  image is APFS-cloned. Packaging belongs to milestone 4.
- `-autoLaunch` is an extra hidden test hook.
