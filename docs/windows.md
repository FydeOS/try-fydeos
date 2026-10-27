# Try FydeOS for Windows

Date: 2026-10-27. Owner: Wei. Companion to `design.md` (macOS); this file
holds the Windows architecture and plan. Changes go through `decisions.md`.

## Goal

A Windows app that boots the FydeOS `amd64-vmware-io` image under QEMU on
the Windows Hypervisor Platform (WHPX) with VirGL graphics, working
keyboard and pointer, network, audio, persistent disk and clean shutdown.
Same product shape as the Mac app: a small launcher, a start menu, QEMU
owns the FydeOS window.

Decisions by Wei (2026-10-27):

- Runtime: start on Try Omarchy's published Windows runtime, pinned by
  hash; switch to our own cross-build later (D-W1).
- Image: bundled in the distributable like the DMG; an online download
  comes later, once FydeOS publishes a raw image (the download page only
  serves the VMware OVA today) (D-W2).
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
  stateful auto-expansion on first boot, kernel patches 025/026 and
  chromium 0173 from `project-vmware` (shared with arm64).
- Guest-side changes live in the FydeOS overlays, never here. Open: the
  kernel config change above; `disable_idle_suspend` exists only in the
  arm64 BSP, the amd64 behaviour under WHPX is measured in milestone 2.

### Runtime: Try Omarchy's Windows runtime, pinned (D-W1)

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
- Later (milestone 5): our own build on the workstation with QEMU's
  Fedora mingw cross recipe in Docker, carrying our overlay (exe name
  and icon, window close routed to the shutdown ladder, EDID density from
  the host DPI as the Cocoa window-master patch does).

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
-serial file:<console.log> -D <qemu.log> -monitor none
-qmp unix:<vm>\qmp.sock,server=on,wait=off
```

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
  spec, locations, workspace (zstd unpack with `klauspost/compress` into
  a sparse NTFS file, size check, extend to `diskBytes`; per-VM EFI vars;
  `.lock` via `LockFileEx`), VM config to argv, QMP client, session
  (start, QMP attach, shutdown ladder, run logs), host probe (WHPX
  present, hypervisor running, x86-64, NTFS).
- `windows/cmd/tryfydeos`: console CLI, same verbs as the Mac CLI:
  `doctor`, `prepare`, `run`, `inspect`, `shutdown`.
- `windows/cmd/TryFydeOS`: the GUI exe (`-H windowsgui`). Start menu as a
  fixed-size Win32 window of the same cards as the Mac: processor cores
  and memory, full screen switch, factory reset behind a confirmation,
  last-run status, Launch with unpack progress; Logs and Quit in a system
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
  `TRY_FYDEOS_FACTORY_IMAGE`.

### Factory image

`factory/amd64-vmware-io.json`, same schema as the arm64 `spec.json`
(`image.file/bytes/sha256/rawBytes/rawSha256/version`, `diskBytes` 64 GiB,
`board`, `kernelCommandLine` facts). The `.zst` is produced with
`zstd -T32 -19` (no `--long`, so the Go decoder's default window
suffices) and lives in `factory/` on the workstation, excluded from git
and from sync like the arm64 one.

### Packaging (D-W2, D-W3)

`dist/Try FydeOS-<version>-windows-x64.zip`, assembled on the workstation
by `make win-dist`:

```
Try FydeOS\
  Try FydeOS.exe        launcher (GUI)
  tryfydeos.exe         CLI
  runtime\              bin\, bin\share\, LICENSES\, provenance\ from the pinned zip
  factory\              <image>.zst + amd64-vmware-io.json
  THIRD_PARTY_NOTICES.txt
```

Portable: unzip anywhere on a local NTFS drive and run. Unsigned.

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
3. App: start menu, supervision, sleep pause, logs, focus. Check: every
   path clicked by hand on the NUC.
4. Package: `make win-dist`, unzip-and-run on a fresh Windows user,
   SmartScreen click-through documented in the README.
5. Own runtime: Docker cross-build with our overlay (branding, close →
   ladder, EDID density for HiDPI hosts), `runtime/` recipe extended to
   produce it.
6. Later: image download (D-W2 split), shared folder, clipboard, port
   forwards UI.

## Known risks

- HiDPI hosts: without the density patch the guest sees QEMU's default
  EDID and picks scale 1, so on a 150 % display the FydeOS UI is small.
  Fixed in milestone 5; until then the NUC's 100 % monitor hides it.
- Window close: the stock SDL frontend quits QEMU on close, a hard power
  off for the guest. Milestone 5 routes it to the ladder.
- Branding: the FydeOS window carries SDL's default icon and Task Manager
  shows `qemu-system-x86_64w.exe` until milestone 5 (renaming the exe is
  tried in milestone 4).
- Host prerequisites the launcher must detect and explain: WHPX feature
  off (`dism /enable-feature /featurename:HypervisorPlatform`, elevation,
  reboot), virtualization disabled in firmware, ARM64 Windows, FAT/exFAT
  drive, old Intel GL driver (the NUC runs a 2020 driver; the runtime's
  Intel workarounds are in play).
- Fast startup: Try Omarchy disables it; whether WHPX misbehaves after a
  fast-startup resume is measured in milestone 2.
- Antivirus: a 7 GB sparse write and an 80 MB QEMU binary may be slowed
  or quarantined by Defender on first run; unsigned exe plus SmartScreen.
