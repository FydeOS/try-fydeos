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

## D8. Guest mode in backing pixels, scale carried by EDID density (2026-10-16)

The guest always gets the window's backing-pixel size, as upstream does.
Upstream's Cocoa patch encodes the host's backing scale in the virtual
display's EDID physical size at 110 DPI per scale unit (a 2x window reads
~220 DPI), the same contract Try Omarchy's guest uses to pick Hyprland's
scale. FydeOS picks its device scale factor from that density through
`project-vmware` chromium patch 0173 (`display_change_observer.cc`): a
virtual connector made external by `--drm-virtual-connector-is-external`
takes the closest supported scale factor to dpi/110 instead of the fixed
1.0 Chrome gives external displays. Measured on the m4 VM: 1776x999 points
→ mode 3552x1998, EDID 41x23 cm, Chrome logs `device_scale_factor:2
dpi:220.051`.

Rejected: reporting the mode in points (milestone 2's first fix). It made
text readable without a guest change but every pixel was resampled twice
(guest → 2x backing store → panel), so text was soft in full screen.
Rejected: a static `--fydeos-default-dsf`; it cannot know the host scale.

Windowed aspect ratio: `resizeWindow` locks the window to the guest's
ratio only once the guest shows the window's own mode, so a transient
firmware mode cannot pin the window (the ratchet of milestone 2), and
free resize stays available until then.

## D9. Image bundled zstd-compressed, unpacked per VM, 64 GiB sparse disk (2026-10-19)

The app carries the factory image as `Contents/Resources/factory/<file>.zst`
(zstd -19). Preparing a VM runs the bundled `runtime/bin/zstd` into
`.disk.img.preparing` in the workspace, checks the exact raw byte count,
renames it to `disk.img` and extends it with `truncate` to `diskBytes`
(64 GiB, sparse); the guest grows its stateful partition on first boot.
Free space of raw size + 1 GiB is required up front. There is no image
store, no Install step and no `import-image`.

No SHA-256 after unpacking: zstd checks its frame checksums while
decompressing and the bundle is code-signed. `rawSha256` in `spec.json` is
provenance only; `make app` checks the `.zst` size and SHA-256.

Measured on the M4: the compressed image is 1.36 GB, 18% of the 7.48 GB
raw image; unpacking takes 3.2 s, a SHA-256 of the raw image 13.3 s.
Gatekeeper's first-launch scan took 47 s for a 7.5 GB bundle against
1.8 s for 173 MB, which is why the raw image never goes into the bundle.

Rejected: the raw image beside the app in the DMG plus an import into an
Application Support store (milestone 4). It needed an Install step, a 7.5 GB
copy or clone and a 13 s verification before the first boot.
