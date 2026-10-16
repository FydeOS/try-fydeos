# Try FydeOS design

Date: 2026-10-16. Owner: Wei. This is the agreed architecture; changes go
through `decisions.md`.

## Goal

A macOS app (Windows and Linux later) that boots the FydeOS
`arm64-vmware-io` image under QEMU on Apple Silicon with accelerated
graphics, working keyboard and pointer, network, persistent disk and clean
shutdown. Modeled on Try Omarchy, written fresh.

## Components

### Guest: the FydeOS vmware image, unmodified at run time

- Built by `cros build-image --board=arm64-vmware-io` on the FydeOS
  workstation. Raw GPT disk, boots through UEFI (edk2) and GRUB from the
  ESP; GRUB selects "local image A" without dm-verity on dev images.
- ACPI is mandatory: the kernel has no device-tree PCI host, so with
  `acpi=off` no virtio-pci device exists.
- Serial log needs no command-line change. The kernel honours the ACPI
  SPCR table and registers QEMU's PL011 as a console even though the GRUB
  line names VMware's `ttyS0`.
- Guest support already in the image: VirGL Mesa (virgl and svga only, no
  software fallback), built-in virtio block/net/gpu/input, intel-hda audio
  driver, spice-vdagent clipboard on virtio port `com.redhat.spice.0`,
  cros-disks auto-mount of the first virtio-9p share, stateful partition
  auto-expansion on first boot.
- Guest-side changes live in the FydeOS overlays (`project-vmware`), never
  in this repo. Current ones: kernel patch 025 (virtio tablet presented as a
  pen tablet plus a wheel-only mouse), which is what makes QEMU's
  `virtio-tablet-pci` usable by Chrome; chromium patch 0173, which derives
  the device scale factor from the EDID density QEMU reports (D8).

### Runtime: Try Omarchy's QEMU recipe, pinned

- Upstream pin: `omacom/try-omarchy` tag `v0.6.0`
  (`6166ca0759aad5c56d4c71128a0aea13dbcb67ad`, 2026-10-15). Its runtime
  recipe is byte-identical to commit `e315a740`, which was built and run
  on this Mac on 2026-10-15.
- `runtime/lock.json` pins the upstream tarball, every recipe file and
  every source and bottle archive by SHA-256. `runtime/runtime.py` fetches,
  verifies, applies the overlay, runs the upstream build script offline,
  relocates, signs and probes the result.
- Stack: QEMU 11.1.1 (`c3d48b7d`), virglrenderer 1.3.0 from source with the
  startergo patch set and upstream's native-OpenGL patch, libslirp 4.9.4
  with two Darwin fixes, ANGLE 1.0.16 and libepoxy 1.0.5 bottles, Homebrew
  core bottles for glib, pixman, SDL, libusb, compression libraries.
  macOS deployment target 15.0.
- Overlay: our own `qemu-cocoa-product-identity.patch` (process name,
  menus, quit prompt, icon file) and `qemu-cocoa-window-master.patch`
  (resizable window drives the guest mode, ratio locked once settled,
  first UI-info report at launch). Everything else is upstream's patch set
  unchanged; unused patches stay because dropping a Cocoa patch mid-chain
  invalidates the ones after it.
- Later addition: spice-protocol headers and `--enable-spice-protocol`, so
  the `qemu-vdagent` chardev exists for guest clipboard.

### QEMU contract (v1)

```
-name "Try FydeOS"
-machine virt,gic-version=3,acpi=on -accel hvf -cpu host,pmu=off
-smp N,sockets=1,cores=N,threads=1 -m <MiB>M -nodefaults
-action reboot=reset,shutdown=poweroff
-drive if=pflash,format=raw,unit=0,readonly=on,file=<edk2-aarch64-code.fd>
-drive if=pflash,format=raw,unit=1,file=<per-VM efi-vars.fd>
-drive if=none,id=root,file=<disk.img>,format=raw,cache=writeback,discard=unmap
-device virtio-blk-pci,drive=root,serial=TRYFYDEOS,bootindex=0,romfile=
-netdev user,id=net[,hostfwd=tcp:127.0.0.1:H-:G]
-device virtio-net-pci,id=nic,netdev=net,mac=<stable per VM>,romfile=
-device virtio-gpu-gl-pci,id=gpu,max_outputs=1,xres=1920,yres=1080,romfile=
-display cocoa,gl=on,show-cursor=off,zoom-to-fit=on,full-grab=on,immersive=off,swap-opt-cmd=off,full-screen=<on|off>
-device virtio-keyboard-pci,id=keyboard,romfile=
-device virtio-tablet-pci,id=tablet,romfile=
-audiodev sdl,id=audio -device intel-hda,id=hda,romfile=
-device hda-output,bus=hda.0,audiodev=audio          (hda-micro when the microphone is opted in)
-object rng-random,id=rng,filename=/dev/urandom -device virtio-rng-pci,rng=rng,romfile=
-serial file:<console.log> -monitor none
-qmp unix:<qmp.sock>,server=on,wait=off
-add-fd fd=<lock>,set=1,opaque=storage-lock
```

`gl=es` remains available as a diagnostic switch. See `decisions.md` for
why `gl=on` is the default and why the tablet is virtio, not USB.

### Launcher: Swift, QEMU owns the window

- `TryFydeOSCore` (library, unit-tested): VM configuration to argv,
  storage (factory verification, APFS clone, per-VM EFI variables, lock),
  QMP client, lifecycle (powerdown ladder, sleep pause), run logs.
- `TryFydeOS` (AppKit, `LSUIElement`): start menu, then accessory mode
  while QEMU runs. The rebranded QEMU process owns the window, Dock entry
  and menu bar.
- Start menu: CPUs, memory, window or full screen, microphone, launch,
  shut down, logs, factory reset with typed confirmation, first-run note
  about display zoom.
- Storage lock: `flock` on `<vm>/.lock`, taken before preparation, held
  for the app's lifetime and inherited by QEMU through `-add-fd`. Never
  unlinked. Foreign or unmarked directories are refused.
- VM data: `~/Library/Application Support/Try FydeOS/VM/v1/` with
  `disk.img`, `efi-vars.fd`, `metadata.json`, `runs/<id>/{console.log,qemu.log,run.json}`.
  Must be on APFS so the clone is copy-on-write.
- Shutdown ladder: QMP `system_powerdown`, QMP `quit` after 20 s, then
  terminate the process group. Sleep: IOKit power notification, QMP `stop`
  before allowing sleep, `cont` on wake only for a stop the app issued.

### Packaging

`Try FydeOS.app` (~173 MB) holds the runtime, firmware, `spec.json` and
icon under `Contents/Resources`; the QEMU binary is installed as
`runtime/bin/Try FydeOS`. The factory image is NOT in the bundle: the DMG
carries it as `FydeOS/<image>` next to the app, and the start menu
imports it into `~/Library/Application Support/Try FydeOS/factory/`
(clonefile on the same volume, streaming copy otherwise, SHA-256 verified
once, recorded in `<image>.verified.json`). VMs clone from that store.
Ad-hoc signed during development without `--deep`, so the QEMU
hypervisor entitlement survives; Developer ID plus notarization are wired
in `build-app.sh` and `package-dmg.sh` but unexercised. DMG is ULFO via
`hdiutil`, about 1.5 GB.

Why this layout (measured in milestones 3 and 4):
- Install the QEMU binary inside the bundle as
  `Contents/Resources/runtime/bin/Try FydeOS`, as upstream does. Launch
  Services labels the Dock tile and menu bar with the executable's file
  name; the identity patch's `setProcessName` runs too late to change it.
- Keep the factory image OUT of the app bundle. On the first launch of
  every new code signature, Gatekeeper runs an XProtect "direct malware
  and dylib scan" of the whole bundle before `main` runs (measured in the
  system log on 2026-10-16: 43 s of a 47 s stall, the process parked in
  `_dyld_start`; later launches are cached by code hash and start in 1 s).
  Scan time scales with bundle size, so a 7 GB image means ~45 s of
  nothing happening after the click, for ad-hoc and notarized builds
  alike. Ship the image beside the app in the DMG (or download it on
  first run) and copy or clone it into Application Support from the start
  menu, with progress shown. The bundle itself stays ~170 MB.

## Milestones

1. Skeleton and runtime: lockfile, runtime build, firmware, `make doctor`.
   Check: capability probe and a diskless HVF boot.
2. Boot: core library drives QEMU without GUI. Check: OOBE reached, serial
   log, Wei's hands-on input check with a 025 image built on the
   workstation.
3. App: start menu, supervision, shutdown ladder, sleep pause, logs.
   Check: every path clicked by hand.
4. Package: bundle, ad-hoc signature, DMG. Developer ID when available.
5. Integrations: clipboard via `qemu-vdagent`, shared folder, port
   forwards, then guest-side display zoom in `project-vmware`.

## Known risks

- GL backend: both Cocoa backends have one Chrome-specific failure (see
  `decisions.md` D3). Native GL is the default; crosh is the known bad
  case and has a guest-side workaround ready.
- Display scale: fixed by D8 (backing pixels + EDID density + chromium
  patch 0173). Images without 0173 render a Retina window at scale 1.
- Guest suspend: an idle FydeOS guest enters s2idle after ~8 min at the
  login screen (2026-10-14 and again 2026-10-16, console shows the PCI
  suspend sequence) and nothing wakes it: QMP `system_wakeup` answers
  "wake-up from suspend is not supported by this guest" on the virt
  machine and synthetic key/tablet events are ignored. Must be fixed
  guest-side in `project-vmware` (powerd prefs) before any user build;
  dev workaround: `echo 1 > /var/lib/power_manager/disable_idle_suspend`
  and `restart powerd`.
- Clean guest shutdown: QMP `system_powerdown` reaches the guest (the
  kernel has `ACPI_BUTTON`; powerd accepts the ACPI button because the
  vmware boards set `USE=legacy_power_button`, which also gives Chrome
  `--aura-legacy-power-button`). In that mode ash's
  `OnLegacyPowerButtonEvent` opens the power menu on the first press and
  calls `RequestShutdown` on a second press while the menu is open. One
  press therefore only shows the menu, which is why the ladder fell
  through to `quit` in milestone 2. Fixed in the ladder: two
  `system_powerdown` presses 2 s apart; measured on 2026-10-16, the guest
  shut itself down 6.7 s after the second press (`SHUTDOWN` with reason
  `guest-shutdown`). A press is ignored while the guest screen is off.
- Default workspace path: `VM/v1` on Wei's Mac still holds the
  September attempt's VM; the app refuses it as foreign. Decide whether to
  remove it or move the default.
- Window mode sizing: resolved by the window-master overlay patch
  (milestone 2); the initial window is upstream's 75% 16:9 frame.
