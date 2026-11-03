# Try FydeOS design

Owner: Wei. The product-wide view; each platform has its own document with
the full architecture, QEMU contract and milestones:

| Platform | Host | Guest image | Document | Status (2026-11-02) |
|---|---|---|---|---|
| macOS | Apple Silicon, macOS 15+ | `arm64-vmware-io` | `macos/design.md` | milestones 1–6 done: image downloaded at first launch, DMG for internal testers |
| Windows | x86-64, Windows 10/11 | `amd64-vmware-io` | `windows/design.md` | milestones 1–6 done: image downloaded at first launch, single exe, own runtime |
| Linux | x86-64, KVM | `amd64-vmware-io` | later | not started |

Decisions are logged in `decisions.md`, one entry per decision, newest
last. Each platform directory also keeps its records: `macos/` has the
findings carried over from the pre-repo attempts and the macOS milestone
records; Windows milestone results are inside `windows/design.md`.

## Goal

Run FydeOS on a Mac, a Windows PC and later a Linux PC without installing
it: a small launcher wraps QEMU with the host's hypervisor around the stock
FydeOS vmware image for that architecture. Modeled on Try Omarchy, written
fresh (D1).

## What every platform shares

- **Guest**: the FydeOS vmware board image for the host architecture,
  unmodified at run time, booted through UEFI from its own ESP. Guest-side
  fixes land in the FydeOS overlays (`project-vmware` and the two
  `overlay-*-openfyde_vmware` BSPs), never in this repo.
- **Factory image**: one spec per board in `factory/` (`spec.json` for
  arm64, `amd64-vmware-io.json` for amd64) pins the VMware image FydeOS
  publishes for that board and names it in the release API. The launcher
  downloads it at first launch, verifies it, decodes the VMDK inside into a
  sparse 64 GiB disk and keeps the download for factory resets; FydeOS
  grows its stateful partition into the free space on first boot (D14, D9).
  No image is bundled or committed.
- **QEMU contract**: virtio block, net, GPU with VirGL, keyboard and
  tablet, Intel HDA audio, a vdagent channel for the clipboard (text,
  both directions, D15), a serial console log, QMP for lifecycle. The
  pointer is `virtio-tablet-pci`, which works because of guest kernel patch
  025 (D4). Platform contracts differ only in machine type, accelerator,
  display backend and firmware files.
- **Launcher model**: a start menu (cores, memory, full screen, microphone,
  factory reset, last-run status, Launch), then QEMU owns the FydeOS window
  while the launcher supervises it: the same two-press shutdown ladder
  over QMP, pause on host sleep, per-run logs, a lock on the VM directory.
  The strings table is shared; only platform-specific lines differ.
- **Packaging**: the runtime, firmware and launcher ship together (DMG on
  macOS, one exe with an appended payload on Windows), 173 MB and 51 MB.
  No code signing certificate yet on either platform.

## Platform differences that matter

| | macOS | Windows |
|---|---|---|
| Accelerator | Hypervisor.framework (`-accel hvf`) | Windows Hypervisor Platform (`accel=whpx`) |
| Machine | `virt`, GICv3, ACPI | `q35` |
| Display | Cocoa, `gl=on`, our window-master patch | SDL, `gl=on`, blob resources |
| Runtime | built on the Mac from Try Omarchy's recipe with our overlay | cross-built in Docker on the workstation from Try Omarchy's recipe with our overlay (D13) |
| Launcher | Swift/AppKit | Go, Win32 via syscall, no cgo |
| Guest reboot | QEMU resets in place | QEMU exits, launcher relaunches (WHPX cannot reset vCPUs) |
| Idle suspend | fixed guest-side (arm64 BSP pref) | fatal, parked (see `windows/design.md` TODO) |

## Repository layout

```
Makefile      make targets for every platform (Mac targets run on the Mac, win-* on the workstation)
docs/         design.md (this), decisions.md, macos/ and windows/ (per-platform design.md and records)
factory/      one spec per board pinning the published image; nothing else
runtime/      macOS runtime build: lock.json, runtime.py, overlay patches (Windows: windows/runtime/)
firmware/     edk2 pair for the macOS runtime
macos/        Swift package: TryFydeOSCore, tryfydeos CLI, TryFydeOSAppModel, the AppKit app
windows/      Go module: internal/core, internal/app, tryfydeos CLI, the Win32 app, runtime.lock.json
tests/        contract tests that run without a VM
```

A Linux port would add `linux/` and `docs/linux/design.md` beside these, reuse
`factory/amd64-vmware-io.json`, and most of the Windows launcher's Go
core.
