# Try FydeOS for Windows

Go launcher for the Windows port; architecture and the QEMU contract are in
`../docs/windows/design.md`. Built on the workstation, run on a Windows 10/11 x64
host with the Windows Hypervisor Platform enabled.

```
internal/core/      factory spec, release API, download, locations, workspace, lock, argv, QMP, session, host probe
internal/vmdk/      VMDK decoder (streamOptimized, monolithicSparse) and .ova/.zip member access
internal/payload/   payload appended to the GUI exe: PE overlay, index, verified readers, Append
internal/app/       GUI model without Win32: strings, preferences, state machine, core driver, app log
cmd/tryfydeos/      console CLI: doctor, prepare, run, inspect, shutdown, reset
cmd/tryfydeos-pack/ workstation packer: trimmed runtime.zip + spec appended to the GUI exe
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
make win-dist      # dist/Try FydeOS-<version>.exe + .sha256 (see Packaging)
make win-sync      # exe, factory/amd64-vmware-$(EDITION).json and windows/ -> NUC D:\try-fydeos\dev\
```

`EDITION=com` on `win-build`, `win-dist` and `win-sync` builds the com
edition: spec `factory/amd64-vmware-com.json` (`-com` image, .com release
API) and `dist/Try FydeOS-<version>-com.exe`. The default `io` is unchanged.

No image is built or copied: the launcher downloads the published VMware
image on the first Launch. To test without downloading, copy an `.ova` (or a
VMware `.zip`) to the NUC once and point `TRY_FYDEOS_FACTORY_IMAGE` at it.

## Run on the NUC

```powershell
$env:TRY_FYDEOS_WORKSPACE = "D:\try-fydeos\dev\vm"
$env:TRY_FYDEOS_RUNTIME = "D:\try-fydeos\runtime"
$env:TRY_FYDEOS_FACTORY_IMAGE = "D:\try-fydeos\factory\FydeOS-VMWare-v23.1-Preview1-x86_64-io.ova"  # optional
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
runtime `runtime\` and spec `factory\amd64-vmware-io.json`
(`amd64-vmware-com.json` in the com edition) next to the exe;
`%LOCALAPPDATA%\Try FydeOS\preferences.json` may set `workspace` and
`forwards` (`["2201:22"]`); `TRY_FYDEOS_FORWARDS` takes `2201:22,8080:80`.

## GUI

`Try FydeOS.exe` is the start menu of the Mac app on Win32: cores and memory
steppers, full screen and microphone switches, factory reset behind a
confirmation, the last-run status and Launch with the download and
conversion progress. When the release API lists a newer image than the one
the VM was converted from, the reset section says so and the reset
confirmation names the version a reset installs. About,
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
It needs `make win-runtime` and `factory/amd64-vmware-io.json`; the exe
carries no image. Sizes for 0.1.0: GUI exe 7.5 MB, runtime.zip 43.5 MB (171
files, 120.4 MB unpacked), so 51.0 MB in total. The zip leaves out the
console QEMU, qemu-img and the firmware for other architectures.

Layout: the payload starts at the PE overlay start, which is the end of the
last section's raw data (or of the COFF symbol table), rounded to
FileAlignment. It is never located from the end of the file, so an
Authenticode table appended later does not move it. At that offset:
`TRYFYDEOS-PAYLOAD-1`, a little-endian u32 index length, and the index JSON
`{"entries":[{"name","offset","length","sha256"}]}` with offsets from the
overlay start. Then come the entries `runtime.zip` and `spec.json`. The
packer refuses an exe that already has trailing data or a certificate
table, so sign after packing.

Packaged and development builds:

- **No payload (development build):** the runtime and spec come from next
  to the exe, or from the `TRY_FYDEOS_*` overrides.
- **With a payload:**
  - The spec is read from the payload.
  - The first Launch (or `tryfydeos prepare`) extracts `runtime.zip` into
    `%LOCALAPPDATA%\Try FydeOS\runtime\<first 12 hex of its sha256>\`. It
    extracts into a temporary directory, then renames it; a `.complete`
    file marks a finished extraction. While it extracts, the start menu
    shows "Preparing FydeOS…".
  - Each payload entry is checked against its sha256 when read.
  - `TRY_FYDEOS_RUNTIME` and `TRY_FYDEOS_SPEC` still win when set.
  - A newer exe brings its own runtime directory next to the old one, and
    the VM is not touched. Old directories are not removed automatically;
    delete `%LOCALAPPDATA%\Try FydeOS\runtime\` while the app is closed to
    reclaim them (the next Launch extracts again).
- `tryfydeos doctor --exe "<path>\Try FydeOS-0.1.0.exe"` lists the payload
  entries and says whether the runtime is extracted yet.

## FydeOS image

Both builds prepare a new VM the same way:

1. **Choose the image.** `TRY_FYDEOS_FACTORY_IMAGE` names a local `.ova` or
   VMware `.zip`, used as is (no download, no hash check); the spec is still
   looked for next to it unless `TRY_FYDEOS_SPEC` is set. Otherwise the
   launcher asks the release API in the spec (`release.api`, board
   `release.board`, 5 s timeout, User-Agent `Try FydeOS/<version>`) and takes
   its entry when the checksum differs from the pinned `image`, else the
   pinned image. An unreachable or malformed API answer is logged and the
   pinned image is used.
2. **Download** into `%LOCALAPPDATA%\Try FydeOS\images\<file name>`, unless
   a file of that name and the expected size is there. The transfer goes
   to `<file>.part`, resumes with an HTTP range after an interruption, and
   is checked against the sha256 once complete; a mismatch deletes the part.
   It needs the image size plus 10 GiB free. The status line reads
   "Downloading FydeOS… N%".
3. **Convert** the container's VMDK into the sparse `disk.raw`, skipping
   all-zero grains ("Converting FydeOS… N%", 10 GiB free needed). The
   published disk is the FydeOS image followed by zeros up to 50 GiB; the
   launcher cuts it at the end of the image's GPT (alternate header LBA + 1
   sectors) and refuses a disk with data beyond that, then grows the file
   to `diskBytes` (64 GiB, sparse). `metadata.json` records the image's
   url, file name, sha256, version and that length (`rawBytes`).

Downloaded images stay in `images\` so a factory reset converts again
without a download. `tryfydeos doctor` prints the pinned image, the files
in `images\` and the release API's current entry.

### Fresh-user test on the NUC

Setup of the 2026-10-27 test (exe with the image inside, 1.65 GB): Windows
10 IoT Enterprise LTSC 21H2 (19044), Intel NUC with 4 threads and 16 GB,
Defender real-time protection on, no exclusions for the test directory.
The exe carried the Mark of the Web (`Zone.Identifier`, ZoneId=3). It was
started with `LOCALAPPDATA` pointing at an empty directory and no
`TRY_FYDEOS_*` overrides, from the desktop session through ShellExecute.
The 51 MB exe that downloads the image was tested on 2026-11-02 from the
desktop session through the scheduled task, without the Mark of the Web
and with the runtime already extracted, so the prompt and extraction
numbers below are still those of the 2026-10-27 run.

- **The prompt is the classic "Open File - Security Warning", not
  SmartScreen's "Windows protected your PC".** Its text: "The publisher could
  not be verified. Are you sure you want to run this software?",
  Publisher: Unknown Publisher, buttons Run / Cancel, checkbox "Always ask
  before opening this file". The SmartScreen endpoints were reachable, and
  smartscreen.exe ran during the delay.
- **First start:** to be measured (with the 1.65 GB exe: 10.5 s from the
  double-click to the prompt, then 14.9 s from Run to the start menu while
  Windows checked the file; the app itself is up within 0.4 s of process
  start).
- **Second start with the Mark of the Web still present:** to be measured
  (with the 1.65 GB exe the prompt came again after 10.3 s; Run with
  "Always ask" unchecked removes the Mark of the Web).
- **Starts without the Mark of the Web:** to be measured (0.2 s before).
- **First Launch** (4 cores, 8 GB):
  - Runtime extracted in 1.2 s: 192 files, 120.5 MB on disk (2026-10-27).
  - Image download (1.91 GB) and its sha256 check: 154.2 s on the NUC's
    link (12.4 MB/s average), 2026-11-02; the start menu showed
    "Downloading FydeOS… NN%" with the progress bar.
  - Conversion into `disk.raw`: 21.7 s (image length 7,314,946,560 bytes
    from the GPT; the workstation converts the same OVA in 27 s).
  - QEMU started within 1 s of the conversion, QMP ready 10 s later, the
    OOBE Terms of Service page 147 s after that; 3 min 7 s from the click
    to QMP ready. `disk.raw` is sparse: 4.3 GB allocated one minute into
    the first boot, 4.8 GB after two boots.
- **Quit from the window menu while FydeOS runs:** the ladder shut the guest
  down in 14-17 s (`guest-shutdown`, exit 0), then the app exited
  (2026-10-27).
- **Restart and Launch:** no extraction, no download, no conversion; QEMU
  0.2 s after the click (2026-10-27).
- **Second Launch** (2026-11-02): the release check found the installed
  image current (no update notice), no download and no conversion, QMP
  ready 10 s after the click.
- **Factory reset, then Launch:** converts again from `images\` without a
  download: to be measured.

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
- Preparation progress: the button says "Preparing FydeOS…", the status
  line "Downloading FydeOS… N%" and then "Converting FydeOS… N%", and a
  progress bar sits under the button; core reports progress in 1 % steps.
- Exit descriptions read "exit code N, reason" (the Mac shows "exit code N").
- A fresh start shows the newest run's outcome in the status line (the run
  record now keeps `shutdownRequest`); the Mac starts at "Not running".
- Defaults are 4 cores and 8192 MiB (docs/windows/design.md), clamped to the host,
  instead of the Mac's min(8, cores) and 4/8 GiB by host RAM.
- Strings: Mac texts verbatim except `subtitle` ("FYDEOS · WINDOWS") and
  `aboutCredits`. Hide is not in the menu (Windows minimises instead).

## Own runtime

`windows/runtime/` builds the Windows QEMU runtime ourselves instead of
fetching Try Omarchy's zip: a cross-build on the workstation in Docker, with
QEMU's Fedora 43 mingw64 recipe (`tests/docker/dockerfiles/fedora-win64-cross.docker`)
as the toolchain. Same layout as the published zip, so the packer and core
take either.

```
runtime/lock.json           every input by hash: Docker base image digest, the Try Omarchy recipe
                            tarball (its 24 QEMU and 5 virglrenderer patches), the QEMU and
                            virglrenderer fork commits, libslirp, spice-protocol, SDL2, libepoxy +
                            MSYS2's patches, the Fedora packages whose DLLs ship, our overlay
runtime/Dockerfile          Fedora 43 + mingw64 toolchain and libraries
runtime/build.sh            host side: fetch + verify, docker build, build without network, zip
runtime/container-build.sh  inside the container: patch, build, collect DLLs/firmware/licenses
runtime/overlay/            our patches (below)
```

```sh
make win-runtime-build                 # out/win-runtime/ + out/win-runtime-<lock sha256 prefix>.zip (+ .sha256)
make win-runtime                       # our pinned zip from out/ into out/win-runtime/ (default)
make win-runtime WIN_RUNTIME=omarchy   # Try Omarchy's pinned zip into out/win-runtime/
```

The first run fetches about 30 MB of tarballs, the QEMU and virglrenderer
forks (shallow) and three QEMU subprojects, and builds the Docker image
(about 1 min each). The build itself runs with `--network=none` and takes
about 4 min on the workstation (64 cores); it is reproducible (three builds
gave the same zip). `windows/runtime.lock.json` pins Try Omarchy's zip at
the top level and ours under `own`; `make win-dist` packs whatever is in
`out/win-runtime/`. `tryfydeos doctor` prints the runtime's build from its
`README.txt` ("Try FydeOS runtime for Windows, lock.json sha256 …" or
"WINQ-EMU runtime for Try Omarchy").

Sizes (lock 773a7bbe5b5a): zip 41 MB (42,338,931 bytes), 116 MB unpacked
(QEMU 82 MB unstripped, as in Try Omarchy's zip), runtime.zip in the
packaged exe 43.5 MB.

Stack: QEMU 11.0.0 (cmspam/winq-emu-qemu `2ce303cf` + Try Omarchy's 0001-0024),
virglrenderer 1.3.0 (cmspam/winq-emu-virglrenderer `e80354b8` + 0001-0005),
SDL2 2.32.10, libepoxy 1.5.10 with MSYS2's four patches, libslirp 4.9.3, all
built from source, and the spice-protocol 0.14.5 headers for `qemu-vdagent`;
glib 2.86.5, pixman, zstd, libfdt, libffi, pcre2, gettext, win-iconv, zlib
and the gcc runtime from Fedora 43 (+ updates).

Overlay (`windows/runtime/overlay/`, applied after the Try Omarchy patches):

- `qemu-sdl-product-identity.patch`: window title is the `-name` value
  ("Try FydeOS", plus the grab/stopped hint), version resource
  FileDescription/ProductName "Try FydeOS", CompanyName FydeOS (Task Manager
  shows it), our icon (`cmd/TryFydeOSApp/TryFydeOS.ico`) as the exe and SDL
  window icon. The exe keeps its name `qemu-system-x86_64w.exe`.
- `qemu-sdl-close-powerdown.patch`: the close button asks "Shut down
  FydeOS?" (Shut down / Cancel, Cancel default) in a MessageBox owned by the
  window; Shut down presses the ACPI power button (QMP `POWERDOWN`). The
  launcher takes an unrequested `POWERDOWN` as the first press and runs the
  rest of the ladder: second press 2 s later, quit at 20 s, TerminateProcess
  at 30 s; `run.json` keeps reason `guest-shutdown` and records
  `shutdownRequest` "host-close: Shut down chosen in the FydeOS window".
- `qemu-sdl-edid-density.patch`: the EDID density follows the window's
  Windows scale, 110 DPI per scale unit as on the Mac (D8), so 100 % reads
  110 DPI (QEMU's default was 100; both give Chrome scale 1) and 150 % reads
  165 DPI (scale 1.5). The guest mode stays in window pixels; resizing
  already followed the window.
- `qemu-msvcrt-utf8-paths.patch`: Try Omarchy's 0009 aborts unless the
  UCRT accepts a UTF-8 locale; Fedora's toolchain targets msvcrt, which
  needs no locale for UTF-8 paths (checked with a non-ASCII disk path).
- `qemu-sdl-window-frame.patch`: the window opens with the rule of Try
  Omarchy's Cocoa window: unit = floor(min(usable width * 0.75 / 16,
  usable height * 0.75 / 9)), a 16 x 9 unit client area centered in the
  display's usable bounds, sent to the guest at once, so the EDID prefers
  that mode from the start. From then on the window keeps its size (the
  firmware's 1280x800 is scaled into it, pillarboxed) and the guest follows
  the window. Dragging the frame keeps 16:9 (an edge sizes the other axis,
  a corner follows the axis the pointer moved more), maximize gives the
  largest 16:9 window inside the work area, centered. A window procedure in
  front of SDL's does this: SDL2 has no WM_SIZING handling, fills
  WM_GETMINMAXINFO itself, and its message hook only sees queued messages.
  Full screen and programmatic resizes are not constrained.
- `qemu-sdl-clipboard.patch`: SDL2 has no clipboard peer, so `qemu-vdagent`
  had no host side. `ui/sdl2-clipboard.c` shares the CLIPBOARD selection
  as plain text both ways: a host copy is announced to the guest and read
  when the guest pastes, a guest copy is fetched at once and written to
  the host clipboard.
- `virglrenderer-without-venus.patch`: the fork only links with Venus;
  Fedora's Vulkan headers are too old for it, so Venus is off.

Differences from Try Omarchy's MSYS2 build: msvcrt instead of UCRT; no
Venus, no D3D11 video decode, no libusb; the zip carries only the windowed
QEMU (no console QEMU, no `qemu-img`).

Measuring the density on a scaled display: set `TRY_FYDEOS_EDID_DEBUG=1` in
the environment of `tryfydeos run` (or the app); `qemu-stderr.log` in the
run directory then logs `edid-density: window created: console 0, 165 DPI`
at 150 %, and on every resize `edid-density: resized: …, W x H px, w x h mm`.
In the guest, Chrome logs the chosen scale (`device_scale_factor:1.5`) in
`/var/log/chrome/chrome`. The window frame logs
`edid-density: initial frame: console 0, … px, … mm` once.

Verified on the NUC (2026-10-27, monitor at 100 %): `--version` 11.0.0,
`-accel help` lists whpx, `-display help` lists sdl, `virtio-vga-gl`
has blob/hostmem; boot to OOBE with `+virgl`, HDA and QMP; title "Try FydeOS"
with our icon in the title bar and taskbar, `Get-Process` Description and
Product "Try FydeOS"; resize followed by the guest (EDID 340x170 mm for
1484x721 px); close button → prompt, Cancel keeps running, Shut down →
`guest-shutdown` 16 s later, launcher exit 0; `tryfydeos shutdown` still
runs the two-press ladder.

Window frame on the NUC (2026-10-28, display at 100 %, LogPixels unset,
1920x1080, work area 1920x1040, so unit 86): the window opens at client
1376x774 at 272,133 (margins 272/272/133/133) and keeps that size through
the boot (sampled every 500 ms: firmware pillarboxed, no resize), EDID
`initial frame: 1376x774 px, 320x180 mm` at 110 DPI, OOBE in 1376x774;
real frame drags keep 16:9 within 0.5 px and the EDID follows (corner
+300/+40 → 1644x925, left edge → 1844x1037, top edge → 1886x1061, corner
-200/-20 → 1176x662, corner +30/+150 → 1444x812); maximize → client
1780x1001 in a 1796x1040 window, centered horizontally, restore back to
1444x812; `--full-screen` → 1920x1080 for the guest, no frame logic; the
close prompt and `tryfydeos shutdown` still end with `guest-shutdown`,
exit 0; the packaged exe extracts runtime 37b8aebc677e (lock 4aa76191872f)
and opens the same 1376x774 window.
