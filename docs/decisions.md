# Decisions

One entry per decision, newest last. Each states the choice, the evidence,
and what would reopen it.

## D1. Fresh tree, not a fork of Try Omarchy (2026-10-16)

Wei's call. We borrow Try Omarchy's runtime recipe by pin and hash, and
its ideas for launcher, storage and lifecycle, but write our own code.
Reference clones stay read-only: `~/workspace/try-omarchy` on the
workstation (e1a0dbe) and the three earlier Try FydeOS attempts on the Mac
(`~/try-fydeos`, `~/Workspace/try-fydeos.backup`, `.../cli-v2`).

## D2. Runtime pinned to upstream v0.6.0 (2026-10-16)

Tag `v0.6.0` = `6166ca0759aad5c56d4c71128a0aea13dbcb67ad`. Its runtime
recipe (build, prepare, bottles, relocation, verification scripts, 24
patches, virgl regression tests) is byte-identical to `e315a740`, which the
cli-v2 attempt built offline on this Mac on 2026-10-15 and booted FydeOS
with. Reopen when upstream changes the recipe or we need a QEMU feature it
lacks (first candidate: spice-protocol for `qemu-vdagent`).

## D3. Cocoa `gl=on` (native OpenGL) is the default display backend (2026-10-16)

Evidence from the cli-v2 record (VALIDATION.md, 2026-10-14/15):

| Backend | Capability | Chrome failure observed |
|---|---|---|
| `gl=es`, bundled ANGLE to Metal | GLSL 130, max_samples 1 | New tab freezes: `Failed to complete framebuffer 0x8d56`, GL error 1286, CLEAR fails. Reproduced with and without QMP. |
| `gl=on`, OpenGL.framework 4.1 to Metal | GLSL 410, max_samples 4 | 16-minute WebGL2 MSAA soak passed. crosh (xterm WebGL renderer) corrupts the GPU process; parked, guest-side workaround = libapps a1ff7b76 (canvas renderer). |

Upstream Try Omarchy also moved to native GL (`virgl-native-opengl.patch`,
`gl=on` in its 0.5.0 launch script). UTM's SPICE+Metal stack is clean but
requires the CocoaSpice controller, rejected as out of scope. Reopen if
native GL shows a second Chrome-wide failure.

## D4. Pointer is `virtio-tablet-pci`, enabled by guest kernel patch 025 (2026-10-16)

Stock virtio-tablet advertises BTN_TOUCH plus ABS_X/Y, so Chrome's evdev
probe classifies it as a touchscreen (`TouchEventConverterEvdev`,
`quirk_left_mouse_button=0`) and drops clicks and wheel. Three earlier
attempts worked around this on the host (relative virtio-mouse, USB
tablet+mouse, vdagent, a QEMU pointer patch); none passed drag and wheel
together. The defect's owner is the guest, so the fix is guest-side:
`project-vmware` kernel patch 025 makes virtio_input present the tablet as
a pen tablet plus a wheel-only mouse, the same disguise FydeOS already uses
for VMware's USB tablet, vmmouse and spice-vdagent. Verified by Wei under
QEMU on 2026-10-16 (cursor, clicks, drag, wheel). Host contract is
therefore Try Omarchy's: `virtio-keyboard-pci` + `virtio-tablet-pci`, no
USB HID, no agent. Reopen only if Cocoa's absolute-pointer grab misbehaves
with this contract (attempt A reported that with an older runtime; to be
re-measured in milestone 2).

## D5. Disk is virtio-blk, firmware is the QEMU-bundled edk2 pair (2026-10-16)

virtio-blk and NVMe both booted in earlier attempts; virtio-blk is the
simpler device and what Try Omarchy uses. Firmware: `edk2-aarch64-code.fd`
and `edk2-arm-vars.fd` extracted from the pinned QEMU 11.1.1 tarball,
byte-identical to Homebrew's (`47765fe3…` / `b3b855c5…`). The pristine vars
template leaves Secure Boot in Setup Mode, which the unsigned GRUB needs.

## D6. Audio is intel-hda with an output-only codec by default (2026-10-16)

The arm64 kernel has no virtio-snd driver; `snd_hda_intel` is present.
`hda-output` avoids opening the host microphone at launch, which on macOS
needs a permission prompt. `hda-micro` is used when the user opts in.

## D7. Bundle identity (provisional)

Display name "Try FydeOS", bundle identifier `io.fydeos.tryfydeos`, process
name "Try FydeOS". Provisional until Wei confirms. The icon is attempt A's
original SVG (no FydeOS or ChromeOS trademark assets) until replaced.
