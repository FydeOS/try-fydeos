# Milestone 2: display size and scale

Date: 2026-10-16. Host: Apple M4, macOS 27.0.1, one display. Factory image
`fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin`. All runs used
`macos/.build/debug/tryfydeos` over ssh in `~/Workspace/try-fydeos`, workspace
`~/Library/Application Support/Try FydeOS/VM/m4`, `--forward 6322:22`, launch
defaults otherwise (`zoom-to-fit=on`, windowed).

Superseded the same day: the point-mode report below was replaced by
backing pixels plus a guest-side scale factor, see `../decisions.md` D8. The
measurements and the window-master hunks still stand; `TRY_FYDEOS_HIDPI`
no longer exists.

## Defects

1. The window ratchets down. It is created non-resizable, so attaching the
   view runs `resizeWindow`'s fixed-size branch and shrink-wraps the window
   to the bootstrap surface; once resizable, every guest mode change refits
   the frame to that mode's aspect ratio. The guest's preferred mode follows
   the window through EDID, so the window never grows back.
2. The UI is half size. `updateUIInfoLocked` reports the mode in backing
   pixels; FydeOS treats the virtio output as an external monitor at scale 1.

## Fix

`runtime/overlay/qemu-cocoa-window-master.patch`, applied after upstream's
last QEMU patch (`qemu-cocoa-minimum-guest-size.patch`):

- zoom-to-fit creates the window resizable; in the resizable, windowed
  branch `resizeWindow` leaves the frame alone (other modes are letterboxed);
- the guest mode is the view's size in points (800x600 floor kept);
  `TRY_FYDEOS_HIDPI=1` restores the backing-pixel mode; the fixed-size
  branch divides by the same scale so it stays the inverse of the report;
- the first UI-info report is sent from `applicationDidFinishLaunching`.
  `updateUIInfo` drops calls before that point, and the first report used
  to ride on the launch-time resize that the first change removes. Without
  it the guest stays at the device default 1920x1080 (measured, below).

`runtime/runtime.py` stages every extra `runtime/overlay/*.patch` (sorted)
under `macos/patches/try-fydeos/` and inserts, after the single
`patch -d "$source_dir" -p1 -f -i "$minimum_guest_size_patch"` line, a
`verify_file_sha` check plus `patch` line per patch; the build fails if
the anchor is not found exactly once or a staged patch's hash differs.
`provenance.json` records every overlay patch under `overlay.patches`.

## Method

The dev image's sshd refuses the ChromiumOS testing key for root
(`Permission denied (publickey,keyboard-interactive)`, key fingerprint
`SHA256:Fp1qWjFL…` offered and rejected): the image carries
`chromeos-ssh-testkeys` but not `chromeos-test-testauthkeys`, the package
that links `/root/.ssh/authorized_keys` to it. One-time fix inside a VM:
`mount -o remount,rw /; mkdir -p /root/.ssh; ln -s
/usr/share/chromeos-ssh-config/keys/authorized_keys /root/.ssh/authorized_keys`
(non-interactive root shells have no PATH). At the time `/sys/class/drm`
could not be read. Instead, QEMU trace events were enabled over QMP within 0.1 s of the
socket appearing (before the guest kernel starts), and every mode the guest
put on the scanout was read from `qemu.log`:

```
trace-event-set-state virtio_gpu_cmd_set_scanout*, virtio_gpu_cmd_get_edid,
virtio_gpu_cmd_get_display_info
```

The window's frame comes from `CGWindowListCopyWindowInfo` for the QEMU pid
(points, title bar included: 32 pt), the screen from `NSScreen`. Each run
waited until `console.log` was quiet for 120 s and at least 150 s had passed,
then ran `tryfydeos shutdown`. Scripts: `out/scratch/m4/{measure.sh,
winfo.swift,qmp.py}` on the Mac.

Screen facts:

```
screen[0] frame=(0.0, 0.0, 2560.0, 1440.0) visibleFrame=(0.0, 67.0, 2560.0, 1343.0) backingScaleFactor=2.0
        D270H:
          Resolution: 5120 x 2880 (5K/UHD+ - Ultra High Definition Plus)
          UI Looks like: 2560 x 1440 @ 60.00Hz
```

Expected window content from `cocoa_initial_window_frame()`: unit =
floor(min(2560 x 0.75 / 16, 1343 x 0.75 / 9)) = floor(min(120, 111.9)) = 111,
so 1776 x 999 points.

## Results

| Run | Runtime | Window frame (pt) | Content (pt) | Guest mode | Mode / content |
|---|---|---|---|---|---|
| baseline | `20261016T070229Z` | 667 x 408 | 667 x 376 | 1334x752 | 2x, ratcheted to 38% of expected width |
| first fix, no launch report | `20261016T075649Z` | 1776 x 1031 | 1776 x 999 | 1920x1080 | device default, window size never reported |
| new | `20261016T081707Z` | 1776 x 1031 | 1776 x 999 | 1776x999 | 1x |
| new, `TRY_FYDEOS_HIDPI=1` | `20261016T081707Z` | 1776 x 1031 | 1776 x 999 | 3552x1998 | 2x |

The guest's final mode is not a standard EDID timing in the baseline and
new runs, so it is the EDID preferred mode, i.e. what the window asked for.
In every run the guest read the EDID once (`get_edid count: 1`).

Baseline (`TRY_FYDEOS_RUNTIME=…/20261016T070229Z/runtime`):

```
window pid=72862 bounds=["X": 836, "Height": 408, "Y": 233, "Width": 667] onscreen=1
guest set_scanout sizes (count, w, h) in boot order:
   1 640x480
   1 1920x1080
  46 1334x752
get_edid count: 1
QEMU 72862 exited
2026-10-16T08:12:29Z QEMU exit code 0
```

First fix without the launch report (runtime `20261016T075649Z`, run
`20261016T081238Z`):

```
window pid=73046 bounds=["Width": 1776, "Y": 94, "Height": 1031, "X": 142] onscreen=1
guest set_scanout sizes (count, w, h) in boot order:
   1 640x480
  24 1920x1080
get_edid count: 1
QEMU 73046 exited
2026-10-16T08:15:38Z QEMU exit code 0
```

New (default runtime `20261016T081707Z`):

```
window pid=83214 bounds=["Y": 108, "Width": 1776, "Height": 1031, "X": 392] onscreen=1
guest set_scanout sizes (count, w, h) in boot order:
   1 640x480
   1 1920x1080
  24 1776x999
get_edid count: 1
QEMU 83214 exited
2026-10-16T08:21:41Z QEMU exit code 0
```

New with `TRY_FYDEOS_HIDPI=1` (inherited: `VMProcess` passes `environ` to
`posix_spawn`; `ps eww` on the QEMU pid showed `TRY_FYDEOS_HIDPI=1`):

```
window pid=84183 bounds=["Y": 108, "X": 392, "Width": 1776, "Height": 1031] onscreen=1
guest set_scanout sizes (count, w, h) in boot order:
   1 640x480
   1 1920x1080
  23 3552x1998
get_edid count: 1
QEMU 84183 exited
2026-10-16T08:24:51Z QEMU exit code 0
```

Runtime `20261016T081707Z` provenance, overlay section (abridged):

```
"patches": {
  "runtime/overlay/qemu-cocoa-product-identity.patch": "0b087ee51f4164bbe3fc4dfea30ac57876827b8dd6d7e2e909708101030eeeee",
  "runtime/overlay/qemu-cocoa-window-master.patch": "c5dd7a215cc972c202038d682268e01e5872d4289915125ec53337d2f117f9a6"
},
"applied_after_upstream": ["macos/patches/try-fydeos/qemu-cocoa-window-master.patch"]
```

A tampered copy of the staged patch stops at the inserted check:
`Try FydeOS overlay qemu-cocoa-window-master.patch checksum mismatch`.

## Not verified

- The guest's DRM connector (`/sys/class/drm/*/modes`, EDID bytes) was not
  read: no guest shell. The mode is inferred from the scanout as above.
- Nobody looked at the guest screen; text size relative to macOS is
  inferred from the 1:1 mode at device scale 1, not observed.
- Window resize by the user, full screen, the "Zoom To Fit" menu toggle,
  and a guest reboot were not exercised.
- The app bundle in `dist/` was not touched; it gets this runtime only when
  rebuilt from `out/runtime/current`.
