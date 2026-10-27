# Try FydeOS for Windows

Go launcher for the Windows port; architecture and the QEMU contract are in
`../docs/windows/design.md`. Built on the workstation, run on a Windows 10/11 x64
host with the Windows Hypervisor Platform enabled.

```
internal/core/      factory spec, locations, workspace, lock, argv, QMP, session, host probe
internal/app/       GUI model without Win32: strings, preferences, state machine, core driver, app log
cmd/tryfydeos/      console CLI: doctor, prepare, run, inspect, shutdown, reset
cmd/TryFydeOSApp/   GUI "Try FydeOS.exe": start menu (Win32, no cgo), icon + rsrc_windows_amd64.syso
versioninfo.rc      icon, common-controls v6 manifest (TryFydeOS.manifest), version block
runtime.lock.json   pinned Try Omarchy WINQ-EMU runtime (url + sha256)
scripts/            fetch-runtime.sh, make-rsrc.sh
```

## Build and test (workstation)

```sh
make win-runtime   # fetch + verify the pinned runtime, unpack into out/win-runtime/
make win-test      # go vet + go test ./... (OS-independent parts, fake QEMU)
make win-build     # out/win-build/tryfydeos.exe and "Try FydeOS.exe" (GOOS=windows, no cgo)
make win-rsrc      # re-render TryFydeOS.ico and rebuild rsrc_windows_amd64.syso
make win-image     # zstd -T32 -19 the amd64 raw image into factory/
make win-sync      # exe, factory/amd64-vmware-io.json and windows/ -> NUC D:\try-fydeos\dev\
```

The `.zst` itself is copied to the NUC once, by hand, into `D:\try-fydeos\factory\`.

## Run on the NUC

```powershell
$env:TRY_FYDEOS_WORKSPACE = "D:\try-fydeos\dev\vm"
$env:TRY_FYDEOS_RUNTIME = "D:\try-fydeos\runtime"
$env:TRY_FYDEOS_FACTORY_IMAGE = "D:\try-fydeos\factory\fydeos-amd64-vmware-io-R150-16700.56.0-d20261027.bin.zst"
$spec = "D:\try-fydeos\dev\amd64-vmware-io.json"
D:\try-fydeos\dev\tryfydeos.exe doctor --spec $spec
D:\try-fydeos\dev\tryfydeos.exe prepare --spec $spec
D:\try-fydeos\dev\tryfydeos.exe run --spec $spec --cpus 2 --memory-mib 3072 --forward 2201:22
D:\try-fydeos\dev\tryfydeos.exe shutdown          # from a second shell
```

`run` needs the interactive desktop session: QEMU's `sdl,gl=on` display
aborts in session 0 (an SSH login) because no OpenGL provider exists there.

Windows-tagged tests run on the NUC from a copy of this directory:
`D:\Go\bin\go.exe test ./...` in `D:\try-fydeos\dev\src`.

Defaults without the overrides: workspace `%LOCALAPPDATA%\Try FydeOS\VM\v1`,
runtime `runtime\` and spec `factory\amd64-vmware-io.json` next to the exe;
`%LOCALAPPDATA%\Try FydeOS\preferences.json` may set `workspace` and
`forwards` (`["2201:22"]`); `TRY_FYDEOS_FORWARDS` takes `2201:22,8080:80`.

## GUI

`Try FydeOS.exe` is the start menu of the Mac app on Win32: cores and memory
steppers, full screen and microphone switches, factory reset behind a
confirmation, the last-run status and Launch with the unpack progress. About,
Open Logs Folder and Quit are in the window (system) menu. The window hides
while FydeOS runs and comes back when QEMU exits; closing it while a VM runs
quits through the shutdown ladder. A second start brings the running
instance (or the FydeOS window) to the front. Preferences live in
`%LOCALAPPDATA%\Try FydeOS\preferences.json` (`cpus`, `memoryMiB`,
`fullScreen`, `microphone` next to the hidden `workspace` and `forwards`),
the app log in `%LOCALAPPDATA%\Try FydeOS\Logs\TryFydeOS.log`. It reads the
same `TRY_FYDEOS_*` overrides as the CLI, plus `TRY_FYDEOS_SPEC` for the spec
file. Like `run`, it must start in the desktop session.

The icon and version resources are compiled into
`cmd/TryFydeOSApp/rsrc_windows_amd64.syso` by `make win-rsrc` (ImageMagick,
llvm-rc, llvm-cvtres, and rsvg-convert or headless Chrome for the SVG). Unlike
the Mac build, the generated `.ico` and `.syso` are committed: `go build`
links any `.syso` in the package directory and needs no tools, so a plain
checkout builds the exe with its icon.

## Deviations from docs/windows/design.md and the Mac app

- GUI package is `cmd/TryFydeOSApp`, exe `Try FydeOS.exe`: `cmd/TryFydeOS`
  collides with `cmd/tryfydeos` (Go rejects case-insensitive import paths,
  NTFS sees one directory), and `TryFydeOS.exe` and `tryfydeos.exe` are one
  file on NTFS. The exe name matches the packaging layout in docs/windows/design.md.
- The storage lock is held from launch until the run ends (and during a
  reset), not for the app's lifetime as on the Mac, so the CLI sees a free
  workspace while the start menu is idle.
- Sleep handling sits on the start menu window, not a message-only window:
  message-only windows receive no broadcasts such as WM_POWERBROADCAST. The
  window also registers for suspend/resume notifications (Modern Standby).
- Unpack progress shows as on the Mac: the button says "Preparing FydeOS…",
  the status line "Unpacking FydeOS… N%" and a progress bar sits under the
  button; core reports progress in 10 % steps.
- Exit descriptions read "exit code N, reason" (the Mac shows "exit code N").
- A fresh start shows the newest run's outcome in the status line (the run
  record now keeps `shutdownRequest`); the Mac starts at "Not running".
- Defaults are 4 cores and 8192 MiB (docs/windows/design.md), clamped to the host,
  instead of the Mac's min(8, cores) and 4/8 GiB by host RAM.
- Strings: Mac texts verbatim except `subtitle` ("FYDEOS · WINDOWS") and
  `aboutCredits`. Hide is not in the menu (Windows minimises instead).
