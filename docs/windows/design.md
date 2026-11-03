# Try FydeOS for Windows

Date: 2026-10-27. Owner: Wei. The Windows architecture and plan; the
product-wide view is `../design.md`, the macOS app is `../macos/design.md`,
decisions go through `../decisions.md`.

## Goal

A Windows app that boots the FydeOS `amd64-vmware-io` image under QEMU on
the Windows Hypervisor Platform (WHPX) with VirGL graphics, working
keyboard and pointer, network, audio, persistent disk and clean shutdown.
Same product shape as the Mac app: a small launcher, a start menu, QEMU
owns the FydeOS window.

Decisions by Wei (2026-10-27):

- Runtime: start on Try Omarchy's published Windows runtime, pinned by
  hash; switch to our own cross-build later (D-W1). Done in milestone 5:
  the runtime is our Docker cross-build (D13), Try Omarchy's zip stays a
  fallback (`make win-runtime WIN_RUNTIME=omarchy`).
- Image: bundled in the distributable like the DMG; an online download
  comes later, once FydeOS publishes a raw image (the download page only
  serves the VMware OVA today) (D-W2). Revised 2026-11-02: the launcher
  downloads the published VMware OVA at the first Launch and converts its
  VMDK itself, so the exe carries no image (milestone 6).
- No code-signing certificate: the exe is unsigned, testers click through
  SmartScreen (D-W3).
- UEFI only; FydeOS does not support legacy BIOS boot (D-W4).

## What was measured (2026-10-27, Intel NUC8i5BEH, Windows 10 LTSC 21H2)

Try Omarchy's unmodified runtime boots the stock release image
R150-16700.56.0-d2026_10_27_112641-a1 (v23.1 Preview1, 16700.56.23.28)
with the command line below. Verified by hand: UEFI boot from the disk,
OOBE, mouse and keyboard, GPU acceleration, window resize followed by the
guest, network, audio through Intel HDA, guest sshd reachable through a
user-mode port forward. The guest needs no change to run on Windows.

Two findings that shape the design:

- The amd64 QEMU kernel config builds virtio-gpu and HDA as modules
  (`DRM_VIRTIO_GPU=m`, `SND_HDA_INTEL=m`), unlike the arm64 config. The
  display appears ~34 s into boot and frecon runs headless (no boot
  splash, no Ctrl-Alt-F2 console). Follow-up in `overlay-amd64-openfyde_vmware`
  `kconfig/vmware-r150-6_12-qemu-def-r2`: build both in.
- edk2 stores the disk's boot entry by PCI path in the per-VM variable
  store. Inserting a device shifted the slots and the firmware fell
  through to PXE. Every device therefore gets a fixed `addr=`.

## Components

### Guest: the FydeOS vmware image, unmodified at run time

- `amd64-vmware-io` release build from the FydeOS release tree. Raw GPT
  hybrid disk: ESP with `efi/boot/bootx64.efi` + GRUB (`cros_efi`) and a
  syslinux tree (`cros_legacy`, unused). GRUB boots image A without
  dm-verity on release images; console on `ttyS0`.
- Guest support already in the image: Mesa VirGL (mesa-reven 26.1.8),
  virtio block/net/input built in, virtio-gpu and HDA as modules,
  spice-vdagent clipboard on virtio port `com.redhat.spice.0`,
  stateful auto-expansion on first boot, kernel patches 025/026 and
  chromium 0173 from `project-vmware` (shared with arm64).
- Guest-side changes live in the FydeOS overlays, never here. Open: the
  kernel config change above; `disable_idle_suspend` exists only in the
  arm64 BSP, the amd64 behaviour under WHPX is measured in milestone 2.

### Runtime: our cross-build, Try Omarchy's zip as fallback (D-W1, D13)

Since milestone 5 the runtime is built on the workstation by
`make win-runtime-build` from `windows/runtime/` (recipe in
`windows/README.md`, "Own runtime"): QEMU's Fedora 43 mingw64 cross
toolchain in Docker, the same pinned QEMU and virglrenderer forks and all
29 Try Omarchy patches, plus SDL2, libepoxy and libslirp from source and
our overlay. Every input is pinned by hash in `windows/runtime/lock.json`,
the build runs without network and is reproducible, so the zip is named
after the lock (`out/win-runtime-<lock sha256 prefix>.zip`) and pinned
under `own` in `windows/runtime.lock.json`. 41 MB zipped, 116 MB unpacked;
only the windowed QEMU, its DLLs, the x86 firmware, licenses and
provenance. `tryfydeos doctor` names the runtime build from its README.txt.

Overlay (`windows/runtime/overlay/`):

- product identity: window title is the `-name` value ("Try FydeOS"), our
  icon on the window and the exe, version resource FileDescription and
  ProductName "Try FydeOS" (what Task Manager shows);
- close button: a "Shut down FydeOS?" prompt owned by the window; Shut
  down presses the ACPI power button, and the launcher completes its
  ladder from the unrequested QMP `POWERDOWN` (second press, quit,
  terminate); Cancel keeps the guest running, which never stops while the
  prompt is open;
- EDID density: 110 DPI per unit of the window's Windows scale, rounded
  to whole centimetres, applied to the default EDID and every resize, as
  the Mac's D8 contract does;
- msvcrt UTF-8 paths: Fedora's toolchain targets msvcrt, not the UCRT, so
  Try Omarchy's UCRT-locale check runs on the UCRT only;
- virglrenderer without Venus: Fedora's Vulkan headers are too old for the
  fork's Venus, so Venus is off (no Vulkan consumer in the guest today);
- window frame: the first window opens at 75 % of the display's usable
  area, 16:9 and centered, the rule of Try Omarchy's Cocoa window, and the
  EDID prefers that mode before the guest reads it, so FydeOS boots
  straight into the frame. The window is then the master as on the Mac: a
  guest mode change (the firmware's 1280x800) is scaled into it, the guest
  follows the window. Dragging keeps the client area 16:9 (an edge sizes
  the other axis, a corner follows the axis the pointer moved more),
  maximize gives the largest 16:9 window in the work area, centered. Full
  screen stays the whole display. Done with a window procedure in front of
  SDL's: SDL2 ignores WM_SIZING, fills WM_GETMINMAXINFO itself and its
  message hook only sees posted messages.

Differences from Try Omarchy's MSYS2 build: msvcrt instead of UCRT, no
Venus, no D3D11 video decode, no libusb, no `qemu-img.exe`. Two Fedora
packages were unusable and are built from source instead: the release
glib could not read files on msvcrt (fixed by 2.86.5 from updates, so the
updates repo is on and the 11 shipped Fedora packages are pinned by
version), and libepoxy 1.5.10 crashed at the first GL call without the
upstream null-EGL fix, so it carries MSYS2's four patches like Try
Omarchy's runtime.

The fallback remains pinned at the top level of `windows/runtime.lock.json`:

- `winq-emu-alpha10-portable.zip` from release `runtime-v1-r25` of
  `omacom/try-omarchy-windows`, sha256
  `ee4ee430f9b060552a2636197fe23598052559c946127ae293dfe447cd930f72`,
  83 MB. Pinned in `windows/runtime.lock.json`, fetched and verified by
  `make win-runtime` on the workstation, unpacked into `out/win-runtime/`.
- Contents: QEMU 11.0.0 fork (24 WINQ-EMU patches: WHPX nested-virt
  fallback, SDL fixes, Windows 9p/unicode, balloon free-page reporting,
  slirp FD_SETSIZE), virglrenderer 1.3.0 fork with Venus, SDL2, libepoxy,
  libslirp, firmware incl. `edk2-x86_64-code.fd` and `edk2-i386-vars.fd`,
  `qemu-img.exe`, licenses and provenance. Built by upstream in MSYS2
  UCRT64; guest-agnostic, only its pinch device and virtio-serial names are
  Omarchy-specific and we do not use them.

### QEMU contract (v1, Windows)

```
-name "Try FydeOS"
-machine q35,accel=whpx -cpu host -smp N -m <MiB>M -nodefaults
-action reboot=shutdown,shutdown=poweroff
-drive if=pflash,format=raw,unit=0,readonly=on,file=<edk2-x86_64-code.fd>
-drive if=pflash,format=raw,unit=1,file=<per-VM efi-vars.fd>
-drive if=none,id=root,file=<disk.raw>,format=raw,cache=writeback,discard=unmap
-device virtio-blk-pci,drive=root,serial=TRYFYDEOS,bootindex=0,romfile=,addr=0x3
-netdev user,id=net[,hostfwd=tcp:127.0.0.1:H-:G]
-device virtio-net-pci,id=nic,netdev=net,mac=<stable per VM>,romfile=,addr=0x4
-device virtio-vga-gl,id=gpu,blob=on,hostmem=<1|2|4>G,addr=0x5
-display sdl,gl=on,show-cursor=off[,full-screen=on]
-device virtio-keyboard-pci,id=keyboard,romfile=,addr=0x6
-device virtio-tablet-pci,id=tablet,romfile=,addr=0x7
-audiodev sdl,id=audio -device intel-hda,id=hda,romfile=,addr=0x1b
-device hda-output,bus=hda.0,audiodev=audio
-device virtio-rng-pci,id=rng,romfile=,addr=0x8
-chardev qemu-vdagent,id=vdagent,clipboard=on,mouse=off
-device virtio-serial-pci,id=vserial,romfile=,addr=0x9
-device virtserialport,chardev=vdagent,name=com.redhat.spice.0
-serial file:<console.log> -D <qemu.log> -monitor none
-qmp unix:<vm>\qmp.sock,server=on,wait=off
```

The vdagent channel is the host clipboard bridge (text only, both
directions; SDL on Windows re-reads the host clipboard when the QEMU window
gains focus) for the spice-vdagent the image ships; `mouse=off` keeps
pointer input on the virtio tablet.

Differences from the Mac contract and why: `q35`/WHPX/`-cpu host` (the
runtime's patch 0019 honours the CPU model, `-cpu host` works on the NUC;
the `qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes` fallback stays available
for hosts where WHPX refuses XSAVE); `virtio-vga-gl` instead of
`virtio-gpu-gl-pci` so the firmware has a VGA console; blob resources with
host memory like Try Omarchy; `reboot=shutdown` because a guest reset
wedges WHPX QEMU (Try Omarchy finding), the launcher relaunches on a
reboot exit; QMP over an AF_UNIX socket (Windows 10 1803+), connected no
earlier than 10 s after start (connecting during early boot deadlocks WHPX
QEMU, Try Omarchy finding); `hostmem` sized 1/2/4 GiB by guest RAM.
Display backend options are verified against `-display help` of the
pinned runtime in milestone 1.

### Launcher: Go, QEMU owns the window

- `windows/` is a Go module (`go 1.24` so the NUC's Go can run the
  Windows-tagged tests), no cgo, Win32 through `syscall.NewLazyDLL` as Try
  Omarchy does. Cross-compiled on the workstation with
  `GOOS=windows GOARCH=amd64`; icon and version block from
  `windows/versioninfo.rc` via `llvm-rc` + `llvm-cvtres` into a `.syso`.
- `windows/internal/core` (unit-tested on Linux where possible): factory
  spec, release API, resumable download, locations, workspace (VMDK
  conversion with `internal/vmdk` into a sparse NTFS file, cut at the
  image's GPT end, extend to `diskBytes`; per-VM EFI vars; `.lock` via
  `LockFileEx`), VM config to argv, QMP client, session
  (start, QMP attach, shutdown ladder, run logs), host probe (WHPX
  present, hypervisor running, x86-64, NTFS).
- `windows/cmd/tryfydeos`: console CLI, same verbs as the Mac CLI:
  `doctor`, `prepare`, `run`, `inspect`, `shutdown`.
- `windows/cmd/TryFydeOS`: the GUI exe (`-H windowsgui`). Start menu as a
  fixed-size Win32 window of the same cards as the Mac: processor cores
  and memory, full screen switch, factory reset behind a confirmation,
  last-run status, Launch with download and conversion progress, a notice
  when the release API lists a newer image; Logs and Quit in a system
  menu. Hidden while QEMU runs, shown again when it exits. DPI-aware
  (per-monitor v2) so the menu is crisp on scaled displays.
- Supervision: the launcher joins a kill-on-close Job object before it
  starts QEMU, so a dead launcher never leaves a VM behind (verified on
  the NUC). Shutdown ladder as on the Mac: two `system_powerdown` 2 s apart
  (legacy power button: first press opens the menu, second shuts down),
  QMP `quit` after 20 s, then `TerminateProcess`; measured 13 s to a
  clean guest power-off. QEMU serves one QMP client, and the supervisor
  keeps it to see the SHUTDOWN event, so `tryfydeos shutdown` asks the
  supervisor over `<vm>\control.sock` instead of QMP. A `guest-reset` exit
  (the guest rebooted) makes `run` start QEMU again in a new run
  directory, which is what `reboot=reset` gives the Mac. Sleep:
  `WM_POWERBROADCAST` suspend → QMP `stop`, resume → `cont` (milestone 3).
- VM data: `%LOCALAPPDATA%\Try FydeOS\VM\v1\` with `disk.raw`,
  `efi-vars.fd`, `metadata.json`, `.lock`, `.try-fydeos` marker and
  `runs\<id>\{console.log,qemu.log,qemu-stderr.log,supervisor.log,run.json}`;
  the newest run directory is the last run (no symlink, which needs a
  privilege on Windows). Limits: 2 to all logical CPUs, 2048 MiB to total
  RAM minus 2048 MiB; defaults 4 CPUs and 8192 MiB.
  Must be on NTFS or ReFS for sparse files. App log:
  `%LOCALAPPDATA%\Try FydeOS\Logs\TryFydeOS.log`. Hidden preferences in
  `%LOCALAPPDATA%\Try FydeOS\preferences.json` (`forwards`, `workspace`),
  env overrides `TRY_FYDEOS_FORWARDS`, `TRY_FYDEOS_WORKSPACE`,
  `TRY_FYDEOS_FACTORY_IMAGE` (a local `.ova` or `.zip`). Downloaded
  image (only the current one): `%LOCALAPPDATA%\Try FydeOS\images\`.

### Factory image

`factory/amd64-vmware-io.json`, schema 2: `image` pins the published
download (`url`, `bytes`, `sha256` of the OVA, `version` text), `release`
names the release API (`api`, `board` `amd64-vmware`), and `diskBytes`
(64 GiB), `board` and the `kernelCommandLine` facts stay as before. Nothing
is built or stored on the workstation.

A new VM is prepared in three steps:

1. Choose: `TRY_FYDEOS_FACTORY_IMAGE` (a local `.ova`/`.zip`, no download,
   no hash check); otherwise the release API's entry for the board when its
   checksum differs from the pinned one, else the pinned image. The API
   call has a 5 s timeout; any failure falls back to the pinned image. The
   API gives no size, so the size of its download is read from a one-byte
   range request.
2. Download into `%LOCALAPPDATA%\Try FydeOS\images\<file name>` through a
   `.part` file that resumes with `Range` (a 200 answer restarts it), then
   check the sha256; a mismatch deletes the part. An existing file of the
   expected size is used without a download. Needs the image size plus
   10 GiB free. The directory keeps only the image the VM is prepared
   from: once that file is verified or found, superseded downloads and
   stale parts are removed.
3. Convert the container's single VMDK (streamOptimized in the OVA,
   monolithicSparse in a VMware zip) into `disk.raw`, writing only
   non-zero grains into the sparse file. The published disk is 50 GiB:
   `chromiumos_image.bin` followed by zeros. Its length is (GPT alternate
   header LBA + 1) * 512 (7,314,946,560 bytes for v23.1 Preview1); a disk
   with non-zero data beyond it is refused as foreign. The file is cut
   there, then extended to `diskBytes`. Needs 10 GiB free.

`metadata.json` records `factory` `{url, fileName, sha256, version,
rawBytes}`. The app asks the release API once at start; when the prepared
VM's `sha256` differs from the API's checksum, the reset section names the
newer version and a factory reset installs it.

The com edition is a build-time choice (`make ... EDITION=com`, which
sets `core.Edition` through `-ldflags -X`), never a runtime switch. It uses
`factory/amd64-vmware-com.json`: the `-com` OVA and the release API at
`release-api.fydeos.com` (`l=zh`), same board and disk facts. The exe is
`Try FydeOS-<version>-com.exe`, with the same version resource; the About
box shows "Version <version> (com)" and `tryfydeos doctor` prints the
edition.

### Packaging (D-W2, D-W3, revised 2026-11-02)

One file for the user: `dist/Try FydeOS-<version>.exe` (about 51 MB),
assembled on the workstation by `make win-dist`. It is the GUI exe with a
payload appended after the PE image, the way self-extracting installers
work, so the Go build stays small:

```
[PE image: Try FydeOS.exe]
[payload header at the overlay start: magic "TRYFYDEOS-PAYLOAD-1", u32 index length, index JSON]
[entry: runtime.zip]      trimmed runtime: bin\qemu-system-x86_64w.exe, bin\*.dll, bin\share\ (x86 firmware only), LICENSES\, provenance\
[entry: spec.json]        factory/amd64-vmware-io.json
```

The index lists every entry's name, offset (from the overlay start),
length and sha256. The launcher finds the overlay start from the PE
section table (end of the last section's raw data), not from the end of
the file, so an Authenticode signature appended later does not move it.
No payload header means a development build: runtime and spec next to
the exe or the `TRY_FYDEOS_*` overrides, as today.

At run time: the index hash is checked at start; the runtime is extracted
once into `%LOCALAPPDATA%\Try FydeOS\runtime\<sha256 prefix>\` (hash
verified while extracting), so a newer exe brings its own runtime without
touching the VM; Launch downloads and converts the image as above. The
CLI stays a development tool and is not shipped.

Unsigned (D-W3): SmartScreen shows "Windows protected your PC" once, the
user clicks More info, Run anyway. Defender scans the download; with the
image out of the exe the scan covers 51 MB instead of 1.7 GB (to be
measured on the NUC).

### Workflow

Build on the workstation, test on the NUC (`ssh -p 2223 wei@localhost`,
everything under `D:\try-fydeos`). `make win-sync` copies a build into
`D:\try-fydeos\dev\`. GUI processes must be started in the desktop session
(Scheduled Task `TryFydeOS-VM` during the experiment phase; the CLI's
`run` is fine from SSH only for serial-log checks since its window stays
in session 0).

## Milestones

1. Core and CLI: module, runtime lock + fetch, spec, workspace (unpack,
   sparse extend, EFI vars, lock), argv, QMP, session with the ladder.
   Check: `tryfydeos doctor/prepare/run` on the NUC boots to OOBE from a
   64 GiB sparse disk (stateful grows), `tryfydeos shutdown` ends the guest
   cleanly within 10 s, serial and QEMU logs in `runs\`.
   Done 2026-10-27: prepare 14 s (3.7 GB on disk for the 64 GiB file),
   boot to the login screen, stateful 61 GiB, shutdown 13 s, Job object
   kill verified. A VM started from an SSH session has no OpenGL (session
   0), so boot tests run through a desktop-session Scheduled Task.
2. Guest behaviour under WHPX: idle for 10 min on the login screen (S3 vs
   s2idle, wake by input), restart from the guest menu, hard window close,
   Venus on/off. Decide the amd64 `disable_idle_suspend` follow-up.
   Done 2026-10-27: idle suspend is fatal (see TODO, parked); restart
   from the guest menu exits QEMU with `guest-reset` and the supervisor
   relaunches it 2 s later, new run directory, QMP attached again; the
   window's close button ends the run with reason `host-ui`, exit 0, the
   launcher exits and releases the lock, the next boot replays the FAT
   and ext4 journals. Venus not measured (no Vulkan consumer in the
   guest yet; revisit with the own runtime).
3. App: start menu, supervision, sleep pause, logs, focus. Check: every
   path clicked by hand on the NUC.
   Done 2026-10-27: Launch, guest restart (relaunch), window close, Shut
   down, About, logs folder, factory reset and the preferences all driven
   on the NUC with screenshots (`out/nuc-gui/`); the sleep pause is
   unit-tested only. Wei's own hands-on pass is still open.
4. Package: `make win-dist` builds the single exe with the appended
   payload; fresh-Windows-user test on the NUC: download-like copy with
   the Mark of the Web, SmartScreen click-through, first start time,
   runtime extraction, Launch, all documented in the README with timings.
   Done 2026-10-27: 1.65 GB exe, Windows 10's "Open File - Security
   Warning" (not SmartScreen) after a 10.5 s scan, 14.9 s from Run to the
   start menu the first time, 0.2 s without the Mark of the Web; runtime
   extracted in 1.2 s, image unpacked in 20 s, OOBE 1 min 47 s after the
   click. Published as `/dist/v23/try-fydeos/Try FydeOS-0.1.0.exe`.
5. Own runtime: Docker cross-build with our overlay (branding, close →
   ladder, EDID density for HiDPI hosts), `runtime/` recipe extended to
   produce it.
   Done 2026-10-27: `make win-runtime-build`, 4 min in Docker after a
   1 min fetch, reproducible. On the NUC (100 % monitor): boots to OOBE
   with VirGL, HDA and QMP; title "Try FydeOS" with our icon in the title
   bar and taskbar; resize followed (EDID 340x170 mm for 1484x721 px at
   110 DPI); close button → prompt, Cancel keeps running, Shut down →
   POWERDOWN, second press 2 s later, `guest-shutdown` at 16 s, exit 0.
   2026-10-28: density verified at 150 % (EDID 165 DPI, the FydeOS UI at
   scale 1.5 in `out/nuc-m5/shot-07-150pct-boot.png`, a resize to
   3578x1969 px reported as 550x300 mm). Window frame added the same day
   at Wei's request (Mac parity, ratio kept while resizing): at 100 % on
   1920x1080 the window opens at 1376x774 and the guest boots into that
   mode with no later resize; real drags of corners and edges gave
   1644x925, 1844x1037, 1886x1061, 1176x662 and 1444x812; maximize gave a
   1780x1001 client area; full screen 1920x1080. The packaged exe with this
   runtime booted into the same frame and shut down through the close
   prompt (`out/nuc-m6/`).
6. Image download (D-W2 revised 2026-11-02): spec schema 2, release API,
   resumable download into `images\`, VMDK conversion cut at the GPT end,
   update notice in the reset section; the exe drops `image.zst`.
   Done on the workstation 2026-11-02: unit tests on VMDK fixtures with a
   GPT, the v23.1 Preview1 OVA converted in 27 s (3.3 GB allocated) and
   identical to qemu-img's conversion over its 7,314,946,560 bytes; exe
   51.0 MB. On the NUC 2026-11-02 (`out/nuc-dl/`): download 154 s at
   12.4 MB/s, sha256 verified, conversion 21.7 s, QMP ready 10 s after
   QEMU start, OOBE 147 s later; the second launch found the image current
   and skipped straight to QEMU; both shutdowns exit 0.
7. Later: shared folder, clipboard, port forwards UI.

## Known risks

- Window as master: the window no longer follows guest mode changes, so
  a resolution picked inside FydeOS is scaled into the window, and SDL's
  Ctrl-Alt-0 (window to guest size) does nothing in a framed window; a
  full-screen start keeps SDL's behaviour. Windows lets a drag push the
  window past the work area (the lock only fixes the ratio), and a
  maximized window keeps its invisible resize borders inside the work
  area, about 16 px narrower than a stock maximize.
- Close button under grab: with the pointer captured by the guest, the X
  cannot be reached until Ctrl-Alt-G; the Mac has no grab.
- Runtime drift: the shipped Fedora packages are pinned by version and the
  build stops when one moves; a Fedora 43 rebase of glib, pixman or the
  gcc runtime needs the pins refreshed and the NUC check rerun.
- Host prerequisites the launcher must detect and explain: WHPX feature
  off (`dism /enable-feature /featurename:HypervisorPlatform`, elevation,
  reboot), virtualization disabled in firmware, ARM64 Windows, FAT/exFAT
  drive, old Intel GL driver (the NUC runs a 2020 driver; the runtime's
  Intel workarounds are in play).
- Fast startup: Try Omarchy disables it; whether WHPX misbehaves after a
  fast-startup resume is measured in milestone 2.
- Antivirus: a 1.9 GB download, a 7 GB sparse write and an 80 MB QEMU
  binary may be slowed or quarantined by Defender on first run; unsigned
  exe plus SmartScreen.
- Image source: the first Launch needs download.fydeos.io (or a mirror
  reached through it) and the release API; offline first launches fail
  unless `TRY_FYDEOS_FACTORY_IMAGE` names a local image. If the file behind
  the pinned URL is replaced while the API is unreachable, the download
  fails its sha256 check until the spec is updated.

## TODO (parked)

- **Idle suspend is fatal under WHPX** (measured 2026-10-27, parked by Wei).
  powerd's sign-in-screen policy suspends the guest after ~10 idle
  minutes; q35 advertises S3, so the kernel enters real S3 and QEMU parks
  the VM. Host input cannot wake it (virtio-input never requests a
  wake-up; only QMP `system_wakeup`, the RTC and PS/2 do), and a forced
  QMP wake-up kills it: WHPX fails to restart the vCPUs (`WHPX: Unexpected
  VP exit code 4` per vCPU, GUEST_PANICKED, power-off). Try Omarchy's
  `ICH9-LPC.disable_s3=1` would only move the guest to s2idle, which is
  unwakeable for the reasons analysed on arm64. Fix = guest-side, mirror of
  arm64 7c5f8f0: add `files/powerd/disable_idle_suspend` (content `1`) to
  `chromeos-bsp-amd64-openfyde_vmware` and bump r3→r4; needs a new
  amd64-vmware-io image. Until then a VM left idle for 10 minutes is lost.
