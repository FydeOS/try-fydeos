# Findings carried over from the earlier attempts

Facts established by the three September–October 2026 Try FydeOS attempts
on this Mac and by the FydeOS r150 source. Each line names its source so
it can be re-checked. Nothing here is re-verified by the fresh tree until
the milestone that exercises it.

Sources: A = `~/try-fydeos/docs/findings-phase0.md` (2026-09-20);
B = `~/Workspace/try-fydeos.backup/docs/{implementation-comparison,input-validation}.md`;
C = `~/Workspace/try-fydeos.backup/cli-v2/{VALIDATION,RUNTIME-BUILD}.md`;
R = FydeOS r150 source on the workstation.

## Boot and firmware

- Image boots to OOBE under QEMU `virt` + HVF + edk2 UEFI with the stock
  ESP GRUB; no grub.cfg, partition or cmdline edit (A).
- ACPI required; `acpi=off` leaves no PCI host, hence no virtio devices (A, R).
- Serial log works via ACPI SPCR → PL011 console (R: kconfig
  `ACPI_SPCR_TABLE=y`, `arch/arm64/kernel/acpi.c` calls
  `acpi_parse_spcr(…, true)`).
- Firmware pair from the QEMU 11.1.1 tarball is byte-identical to
  Homebrew's; pin `47765fe3…` (code) and `b3b855c5…` (vars) (A).
- Minimum 4 vCPU, 4096 MiB (A, B, C).
- TPM: the guest kernel has no QEMU-providable TPM driver; first boot
  generates a plain encryption key; not blocking (A).
- Secure Boot off; the guest reads `dbx` efivars and logs ENOENT; harmless (A).

## GPU

- Plain `virtio-gpu-pci` is fatal: `ui` respawns every ~6 s with status 2
  because FydeOS passes `--disable-features=FallbackToSWIfGLES3NotSupported`
  and the image has no software GL (A, R).
- `gl=es` ANGLE: new-tab freeze with incomplete multisample framebuffer (C).
- `gl=on` native: WebGL2 MSAA soak passed; crosh corrupts the GPU process
  (C; session 2026-10-16).
- QMP `screendump` of a GL scanout is black; the runtime lacks libpng and
  emits PPM only (A, B).
- `show-cursor=on` draws two cursors because FydeOS draws its own; use
  `show-cursor=off` (A). B noted pointer disappearance with `off` in a USB
  profile; re-check with the virtio tablet.

## Display scale

- `--drm-virtual-connector-is-external` makes the virtio output an external
  monitor, which stays at device scale 1 regardless of EDID DPI. On a
  Retina window the desktop is tiny until the user sets display zoom to 2
  in FydeOS settings, per user profile; OOBE stays small (A).
- Try Omarchy's dynamic-display patch publishes the window's backing size
  and refresh via EDID; FydeOS follows the mode but picks no zoom (A, B).

## Input

- Kernel virtio-input works; BTN_LEFT and REL_WHEEL reach evdev (B).
- Stock virtio-tablet is handled by Chrome's `TouchEventConverterEvdev`
  with `quirk_left_mouse_button=0`; clicks and wheel are dropped (B,
  `chrome://system` on 150.0.7871.208).
- UTM's working clicks come from spice-vdagent's pen tablet and wheel
  mouse, not from its USB devices; UTM drags were also unreliable (B).
- USB tablet + mouse: wheel lands on the tablet and is lost through the
  r150 `007-fix-vmware-usb-mouse.patch` hole in `hidinput_handle_scroll()`;
  slider drag fails (B).
- QEMU `x-query-virtio-status` on virtio-input aborts QEMU 11.1.1; refuse
  `x-*` QMP commands (B).
- `pcie.0` has no hotplug; devices cannot be added live (B).
- Resolution: kernel patch 025 in `project-vmware` (session 2026-10-16).

## Audio

- SDL audiodev + `intel-hda` works; guest has `snd_hda_intel` (A).
- A Mac mini without an input device logs
  `SDL_OpenAudioDevice for recording failed`; output still works (A).
- A GUI-launched app needs `NSMicrophoneUsageDescription` before
  `hda-micro` can open the microphone (A).

## Network

- slirp user NAT with DHCP verified end to end; guest 10.0.2.15, DNS
  10.0.2.3 (A). Use loopback-only `hostfwd` (A, C).

## Storage and lifecycle

- Factory image read-only; per-VM APFS `cp -c` clone of disk and EFI vars
  (A, B, C). Require APFS (C).
- One `flock`, never unlinked, held from preparation through QEMU's life,
  inherited via `-add-fd fd=N,set=1,opaque=storage-lock` (B, C).
- Refuse unmarked or foreign directories; never auto-reset (B, C).
- QMP readiness is not guest readiness (B, C).
- Shutdown ladder: `system_powerdown` → `quit` at 20 s → kill group (B).
- Sleep: IOKit `IORegisterForSystemPower`, synchronous QMP `stop` before
  `IOAllowPowerChange`, resume only an owned stop. Not physically verified (B).
- Guest idle suspend entered at ~1253 s uptime and did not wake (C).

## Packaging

- QEMU owns the window; the identity patch loads the icon from three
  levels above the executable, i.e. `Contents/Resources` (A).
- Sign the bundle without `--deep` so the QEMU hypervisor entitlement
  survives (A). Ad-hoc bundles are rejected by Gatekeeper on other Macs (B).
- Full `make package` with a 7 GiB image takes about 90 s, dominated by
  signing hashes (A).
- Native UI automation cannot bind an unbundled QEMU binary (B).
