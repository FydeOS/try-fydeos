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
  the device scale factor from the EDID density QEMU reports (D8); the
  `disable_idle_suspend` powerd pref in the arm64 vmware BSP (see risks).

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
  menus, quit prompt, icon file), `qemu-cocoa-window-master.patch`
  (resizable window drives the guest mode, ratio locked once settled,
  first UI-info report at launch) and `qemu-virgl-flush-2d-upload.patch`
  (a `glFlush` after each TRANSFER_TO_HOST_2D, see risks). Everything else
  is upstream's patch set unchanged; unused patches stay because dropping
  a Cocoa patch mid-chain invalidates the ones after it.
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
  storage (zstd unpack into a sparse disk, per-VM EFI variables, lock),
  QMP client, lifecycle (powerdown ladder, sleep pause), run logs.
- `TryFydeOS` (AppKit, `LSUIElement`): start menu, then accessory mode
  while QEMU runs. The rebranded QEMU process owns the window, Dock entry
  and menu bar.
- Start menu: CPUs, memory, window or full screen, microphone, launch,
  shut down, logs, factory reset with typed confirmation, first-run note
  about display zoom. Hidden: `forwards` default / `TRY_FYDEOS_FORWARDS`
  (comma-separated host:guest ports on 127.0.0.1), like `workspace`.
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

`Try FydeOS.app` (~1.4 GB) holds the runtime, firmware, `spec.json`,
icon and the factory image zstd-compressed (1.36 GB) under
`Contents/Resources`; the QEMU binary is installed as
`runtime/bin/Try FydeOS`. Preparing a VM unpacks the image with the
bundled `zstd` into the workspace, checks the raw size and extends the
file, sparse, to 64 GiB (D9). There is no image store and no import step.
Ad-hoc signed during development without `--deep`, so the QEMU
hypervisor entitlement survives; Developer ID plus notarization are wired
in `build-app.sh` and `package-dmg.sh` but unexercised. DMG is ULFO via
`hdiutil`.

Why this layout (measured in milestones 3 and 4):
- Install the QEMU binary inside the bundle as
  `Contents/Resources/runtime/bin/Try FydeOS`, as upstream does. Launch
  Services labels the Dock tile and menu bar with the executable's file
  name; the identity patch's `setProcessName` runs too late to change it.
- Bundle the factory image compressed, never raw. On the first launch of
  every new code signature, Gatekeeper runs an XProtect "direct malware
  and dylib scan" of the whole bundle before `main` runs (measured on
  2026-10-16 and 2026-10-19: 47 s for the 7.5 GB bundle with the raw
  image, 1.8 s for 173 MB without it; later launches are cached by code hash). Scan time
  scales with bundle size; zstd -19 brings the image to 18% of raw, and
  unpacking takes 3.2 s on an M4 (D9).

## Milestones

1. Skeleton and runtime: lockfile, runtime build, firmware, `make doctor`.
   Check: capability probe and a diskless HVF boot.
2. Boot: core library drives QEMU without GUI. Check: OOBE reached, serial
   log, Wei's hands-on input check with a 025 image built on the
   workstation.
3. App: start menu, supervision, shutdown ladder, sleep pause, logs.
   Check: every path clicked by hand.
4. Package: bundle with the zstd image (D9), ad-hoc signature, DMG.
   Developer ID when available.
5. Integrations: clipboard via `qemu-vdagent`, shared folder, port
   forwards, then guest-side display zoom in `project-vmware`.

## Known risks

- GL backend: both Cocoa backends have one Chrome-specific failure (see
  `decisions.md` D3). Native GL is the default; crosh is the known bad
  case and has a guest-side workaround ready.
- Display scale: fixed by D8 (backing pixels + EDID density + chromium
  patch 0173). Images without 0173 render a Retina window at scale 1.
- Guest suspend (fixed guest-side): powerd's login-screen policy suspends
  after 8m30s idle. On the QEMU virt machine the guest only has s2idle
  (QEMU's PSCI offers no SYSTEM_SUSPEND, so `mem_sleep` is `[s2idle]` and
  QMP `system_wakeup` has nothing to wake), and in s2idle no interrupt is
  wake-enabled: the GED path of the ACPI power button is requested
  without `enable_irq_wake` (`drivers/acpi/evged.c`) and virtio-input has
  no wakeup support, so key, pointer and power-button events are all
  masked. Measured 2026-10-16: frozen guest, QMP power button, still
  unreachable; UTM shows the same. Fix: `disable_idle_suspend` powerd pref
  in `chromeos-bsp-arm64-openfyde_vmware` (idle becomes a no-op, dim and
  screen-off stay). Follow-up: wake-enable the GED and virtio-input
  interrupts in the kernel so an explicit sleep is wakeable.
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
- Leftover image store: builds before D9 imported the raw image into
  `~/Library/Application Support/Try FydeOS/factory/` (7.5 GB). Nothing
  reads it any more; it is removed by hand. Workspaces prepared from it
  keep working (7.5 GB disk, `tryfydeos prepare` notes the older factory)
  until a factory reset.
- Window mode sizing: resolved by the window-master overlay patch
  (milestone 2); the initial window is upstream's 75% 16:9 frame.
- Console (frecon) updates lost (fixed host-side): with the guest mode in
  backing pixels, typed characters on Ctrl-Alt-F2 appeared only after the
  next modeset. Measured 2026-10-19: frecon issued DIRTYFB per key, the host
  received the flush, dirtied the layer and rendered without GL error, yet
  drew stale pixels. The kernel's 2D upload carries no fence, so
  virglrenderer never flushes its context (its only `glFlush` is in fence
  creation, which Chrome's 3D path triggers every frame) and the Cocoa
  layer's context keeps sampling the old texture; small uploads at the
  points-size mode got through by luck. `qemu-virgl-flush-2d-upload.patch`
  flushes right after the upload. Bisected over the five runtime builds,
  verified by typing in a scratch VM.
