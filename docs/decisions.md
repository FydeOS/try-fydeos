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

Superseded by D14 on 2026-11-02 for the image source; the 64 GiB sparse
disk and the per-VM preparation stay.

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

## D10. One repository for every platform (2026-10-27)

Wei's call. The macOS and Windows launchers share the guest contract, the
factory specs, the decisions log and the QEMU findings, so they live in one
tree under `macos/` and `windows/`, with a Linux port expected to join as
`linux/`. Try Omarchy keeps separate repos per platform; we tag releases
per platform instead. Reopen if the platforms diverge in release cadence
or ownership.

## D11. Windows: Try Omarchy's published runtime first, own build later (2026-10-27)

Start on `winq-emu-alpha10-portable.zip` (release `runtime-v1-r25`, pinned
by sha256 in `windows/runtime.lock.json`); it booted the stock image with
GPU, input, audio and network on the first attempt. Our own cross-build on
the workstation (QEMU's Fedora mingw recipe in Docker) comes once branding,
window-close routing and HiDPI density need runtime patches. See
`windows/design.md`.

## D12. Windows: image bundled, unsigned portable zip, UEFI only (2026-10-27)

The bundled image is superseded by D14 on 2026-11-02; the single exe,
the missing certificate and UEFI-only boot stand.

The amd64 image ships inside the app like the DMG (no raw image is
published for download yet; an online download is a later split): one
self-contained exe with the runtime and the image appended as a payload,
no zip and no installer, because one file is the simplest thing for the
user (Wei, 2026-10-27). No code-signing certificate exists, so testers
click through SmartScreen.
The guest boots through UEFI only; the image's legacy syslinux path is
unsupported by FydeOS. Full screen defaults to on for parity with the Mac.

## D13. Windows: the runtime is our Docker cross-build (2026-10-27)

Milestone 5 replaces Try Omarchy's zip with `make win-runtime-build`:
QEMU's Fedora 43 mingw64 cross image in Docker, the same pinned QEMU and
virglrenderer forks with all of Try Omarchy's patches, SDL2, libepoxy and
libslirp from source, and our overlay (window title and icon, the close
prompt feeding the shutdown ladder, EDID density from the Windows scale,
the Mac's 75 % 16:9 first frame with the ratio kept while resizing).
Every input is pinned by hash in `windows/runtime/lock.json`; the build
runs offline and is reproducible. Try Omarchy's zip stays pinned as a
fallback (`WIN_RUNTIME=omarchy`).

Accepted differences from Try Omarchy's MSYS2 build: msvcrt instead of
the UCRT (Fedora has no UCRT glib), no Venus (Fedora's Vulkan headers are
older than the fork's protocol; no Vulkan consumer in the guest today), no
D3D11 video decode, no libusb. Revisit Venus when a guest needs it or a
UCRT toolchain becomes available in the image.

## D14. The apps download FydeOS's published VMware image and convert it themselves (2026-11-02)

Neither app carries an image any more. The factory spec (schema 2) pins
the VMware download FydeOS publishes for the board by URL, size and
SHA-256, and names the board in the release API
(`release-api.fydeos.io/api/downloads`, the same list the fydeos.io
download pages read). At first launch the launcher asks the API and takes
its image when the checksum differs from the pinned one, else the pinned
one; offline it uses what it has. The download is resumable, verified by
hash and kept in the app's `images` directory, so a factory reset never
downloads again; a newer download replaces the old one once it is
verified. When the API lists a newer image than the one installed,
the reset section says so and the reset installs it.

The download is a VMware disk, not a raw image: an `.ova` with a
streamOptimized VMDK for x86_64, a zip of a Fusion `.vmwarevm` folder with
a monolithicSparse VMDK for arm64. Both launchers decode either layout
themselves (`windows/internal/vmdk`, `TryFydeOSCore/VMDK.swift`), reading
the member straight out of the container into the sparse disk, instead of
shipping qemu-img. The published disk is `chromiumos_image.bin` followed
by zeros to 50 GiB, so the launcher cuts it at the GPT's alternate header
and refuses a disk with data beyond that; the result is byte-identical to
qemu-img's conversion. Wei chose the in-launcher decoder over shipping
qemu-img, and the API with the pinned image as fallback over scraping the
download page or a new manifest.

Measured: the Windows exe went from 1.65 GB to 51 MB, the Mac app from
1.4 GB to 173 MB; the NUC downloaded 1.91 GB in 154 s and converted it in
21.7 s, the M4 Mac 1.57 GB in 128 s and 5.4 s. The July 2026 amd64 OVA
could not boot under Try FydeOS because its kernel lacked virtio; the
v23.1 images carry the same drivers as our own builds, which is why this
split became possible.

## D15. Clipboard sharing over QEMU's built-in vdagent, text only (2026-11-03)

Both launchers add `-chardev qemu-vdagent,clipboard=on,mouse=off` with a
`virtio-serial-pci` controller and a `virtserialport` named
`com.redhat.spice.0`. The guest half already ships in the v23.1 images:
Yang Tsao's port of spice-vdagent to the vmware boards (project-vmware,
2026-08) with a Wayland backend that drives `wl-copy`/`wl-paste` against
Chrome's exo socket, plus Chromium patch 0172 giving exo the data-control
protocol; its only requirement is that port name, and its hypervisor gate
(DMI or device-tree saying "qemu") passes on both machines. `mouse=off` is
mandatory: with the vdagent pointer enabled QEMU routes absolute pointer
events through the agent instead of the virtio tablet.

QEMU terminates the vdagent protocol itself and hands the data to its
clipboard core, so no SPICE server, display or client is involved; the
only build cost is the header-only spice-protocol package, now pinned in
both runtime locks and configured with `--enable-spice-protocol`. The
Cocoa backend already carries a clipboard peer. SDL2 has none upstream
(two proposals, 2023 and 2025, never merged), so the Windows runtime adds
one as the overlay patch `qemu-sdl-clipboard.patch`: a host copy is
announced to the guest and handed over on request, a guest copy is
fetched at once and written to the host clipboard, and the text the peer
last wrote is remembered so a backend that reports its own writes does
not bounce them back. SDL on Windows only re-checks the host clipboard
when the QEMU window gains focus, which still covers copying elsewhere
and clicking back into the VM.

Text only, both directions: QEMU's clipboard core has a single content
type, so images would need QEMU changes. Rejected: Try Omarchy's own
bridges (JSON over a private virtio port on macOS, two slirp TCP ports on
Windows, each with a custom guest daemon), because they would add guest
code to the FydeOS image for no gain over the agent it already ships.

## D16. GitHub Actions build the runtimes and the installers (2026-11-04)

Development moved to github.com/FydeOS/try-fydeos: issues, pull requests
and releases. Three workflows under `.github/workflows/`:

- `checks` runs the unit tests (`make test`, `make win-test`,
  `make win-build`, `make app-test`) on every pull request and push to
  main; the three jobs are required before merge.
- `runtime` builds a QEMU runtime whenever its lock changes (or on
  dispatch) and publishes it as a pre-release named by the first twelve
  hex digits of the lock's SHA-256: `win-runtime-<hash>` carries the zip
  the Docker cross-build produces, `mac-runtime-<hash>` a tarball of the
  runtime tree and its `provenance.json`. A published hash is never
  rebuilt. The Windows job then checks that `windows/runtime.lock.json`
  pins the published zip, so a recipe lock bump is followed by a pin
  update in the same pull request, taken from the job's failure message
  or from a local build: the cross-build reproduces byte for byte across
  machines (verified 2026-11-04 against the workstation's zip) now that
  the build image's package list travels beside the zip as
  `.packages.txt` instead of inside it. The Mac job passes `--no-smoke`:
  GitHub's macOS runners have no hypervisor, so the HVF boot check is
  left to a real Mac before each release.
- `installers` builds the four installers (io and com for each platform)
  on every pull request, push to main and `v*` tag, fetching the runtime
  its lock names from the pre-release. The Mac job installs the tarball
  with `runtime.py install`, which refuses a runtime built from another
  lock and re-hashes every file against the provenance. On a tag, after
  checking that `windows/versioninfo.rc` and `Info.plist` carry the tag's
  version, it creates the GitHub Release with the io installers as
  `TryFydeOS-<version>.exe` and `.dmg` plus `.sha256` files written
  against those names: GitHub replaces spaces in asset names with dots,
  which would leave the checksums naming files nobody has. The com
  installers are built on every run and kept as workflow artifacts; they
  are not released yet.

Rejected: building the runtimes by hand and uploading them, because the
only reason to was the HVF smoke test, which belongs to release testing
anyway; and building the runtime inside the installer workflow, which
would cost half an hour per pull request for an input that changes a few
times a year. Installers stay unsigned for now.
