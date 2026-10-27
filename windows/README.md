# Try FydeOS for Windows

Go launcher for the Windows port; architecture and the QEMU contract are in
`../docs/windows/design.md`. Built on the workstation, run on a Windows 10/11 x64
host with the Windows Hypervisor Platform enabled.

```
internal/core/      factory spec, locations, workspace, lock, argv, QMP, session, host probe
internal/payload/   payload appended to the GUI exe: PE overlay, index, verified readers, Append
internal/app/       GUI model without Win32: strings, preferences, state machine, core driver, app log
cmd/tryfydeos/      console CLI: doctor, prepare, run, inspect, shutdown, reset
cmd/tryfydeos-pack/ workstation packer: trimmed runtime.zip + image + spec appended to the GUI exe
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
make win-dist      # dist/Try FydeOS-<version>.exe + .sha256 (see Packaging)
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

## Packaging

`make win-dist` builds the GUI and runs `cmd/tryfydeos-pack`, which writes
`dist/Try FydeOS-<version>.exe` and `<that>.sha256`. The version is
`ProductVersion` in `versioninfo.rc`, the one source the Makefile reads
(`appVersion` in `cmd/TryFydeOSApp/main_windows.go` must still match it).
It needs `make win-runtime` and the factory `.zst` named in
`factory/amd64-vmware-io.json`. The packer refuses an image whose size or
sha256 differs from the spec. Sizes for 0.1.0: GUI exe 4.4 MB, runtime.zip
44.3 MB (191 files, 120.5 MB unpacked), image.zst 1604.0 MB, so 1652.8 MB in
total. The zip leaves out the console QEMU, qemu-img and the firmware for
other architectures. Packing takes about 11 s on the workstation.

Layout: the payload starts at the PE overlay start, which is the end of the
last section's raw data (or of the COFF symbol table), rounded to
FileAlignment. It is never located from the end of the file, so an
Authenticode table appended later does not move it. At that offset:
`TRYFYDEOS-PAYLOAD-1`, a little-endian u32 index length, and the index JSON
`{"entries":[{"name","offset","length","sha256"}]}` with offsets from the
overlay start. Then come the entries `runtime.zip`, `image.zst` and
`spec.json`. The packer refuses an exe that already has trailing data or a
certificate table, so sign after packing.

Packaged and development builds:

- **No payload (development build):** nothing changes. The runtime and spec
  come from next to the exe, or from the `TRY_FYDEOS_*` overrides.
- **With a payload:**
  - The spec is read from the payload.
  - Launch streams `image.zst` from the exe straight into `disk.raw`.
  - The first Launch (or `tryfydeos prepare`) extracts `runtime.zip` into
    `%LOCALAPPDATA%\Try FydeOS\runtime\<first 12 hex of its sha256>\`. It
    extracts into a temporary directory, then renames it; a `.complete`
    file marks a finished extraction. While it extracts, the start menu
    shows "Preparing FydeOS…".
  - Each payload entry is checked against its sha256 when read, and the
    image also against the spec's sha256 and size. A mismatch fails the
    unpack before the disk counts as prepared (this check now applies to
    development builds too).
  - `TRY_FYDEOS_RUNTIME`, `TRY_FYDEOS_SPEC` and `TRY_FYDEOS_FACTORY_IMAGE`
    still win when set; the image comes from the override, else the
    payload.
  - A newer exe brings its own runtime directory next to the old one, and
    the VM is not touched. Old directories are not removed automatically;
    delete `%LOCALAPPDATA%\Try FydeOS\runtime\` while the app is closed to
    reclaim them (the next Launch extracts again).
- `tryfydeos doctor --exe "<path>\Try FydeOS-0.1.0.exe"` lists the payload
  entries and says whether the runtime is extracted yet.

### Fresh-user test on the NUC (2026-10-27)

Setup: Windows 10 IoT Enterprise LTSC 21H2 (19044), Intel NUC with 4 threads
and 16 GB, Defender real-time protection on, no exclusions for the test
directory. The exe carried the Mark of the Web (`Zone.Identifier`,
ZoneId=3). It was started with `LOCALAPPDATA` pointing at an empty
directory and no `TRY_FYDEOS_*` overrides, from the desktop session through
ShellExecute.

- **The prompt is the classic "Open File - Security Warning", not
  SmartScreen's "Windows protected your PC".** Its text: "The publisher could
  not be verified. Are you sure you want to run this software?",
  Publisher: Unknown Publisher, buttons Run / Cancel, checkbox "Always ask
  before opening this file". The SmartScreen endpoints were reachable, and
  smartscreen.exe ran during the delay.
- **First start:** 10.5 s from the double-click to the prompt. Then
  **14.9 s from Run to the start menu**: Windows checks the 1.65 GB file
  before it creates the process; the app itself is up within 0.4 s of
  process start.
- **Second start with the Mark of the Web still present:** the prompt again
  after 10.3 s, so the delay is not cached. Run with "Always ask" unchecked
  (which removes the Mark of the Web) brought the start menu up in under
  0.3 s.
- **Starts without the Mark of the Web:** 0.2 s from ShellExecute to the
  start menu.
- **First Launch** (4 cores, 8 GB):
  - Runtime extracted in 1.2 s: 192 files, 120.5 MB on disk.
  - Image unpacked from the exe in 20.0 s, including the sha256 check.
  - QEMU started 22 s after the click, QMP ready 10 s later.
  - The OOBE frame appeared about 1 min 47 s after the click, the Terms of
    Service page at about 2 min.
- **Quit from the window menu while FydeOS runs:** the ladder shut the guest
  down in 14-17 s (`guest-shutdown`, exit 0), then the app exited.
- **Restart and Launch:** no extraction, no unpack, QEMU 0.2 s after the
  click.
- **Factory reset, then Launch:** re-unpacked from the exe in 20.5 s, the
  runtime was not extracted again, and the guest booted to the fresh OOBE
  language screen.

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
