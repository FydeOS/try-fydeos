# Milestone 4: package

Date: 2026-10-16. Host: Apple M4, 10 cores, 24 GiB, macOS 27.0.1 (26A434),
Command Line Tools Swift. Runtime and firmware from milestone 1. Factory
spec: `fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin`, 7482718720
bytes, sha256 `22587891305d2ffcb9b7db0b5935fd7f29fe70aad75e235e0f27ec2dda4f1dea`.

Everything ran over ssh in `~/Workspace/try-fydeos`. The app was pointed at
`VM/m4` (`defaults write io.fydeos.tryfydeos workspace …/VM/m4`), and the
default was deleted afterwards.

## What was built

| Piece | Where |
|---|---|
| Image store: `<store>/<file>` plus `<file>.verified.json` (sha256, bytes, mtime); state from size and mtime only; atomic import (temp name, SHA-256 check against spec.json, rename, then the record); `clonefile` on the same volume, else a streaming copy hashed on the fly; progress callbacks | `macos/Sources/TryFydeOSCore/FactoryStore.swift` |
| Store directory (`TRY_FYDEOS_FACTORY_DIR`, default `~/Library/Application Support/Try FydeOS/factory`), import candidates in order, QEMU as `bin/Try FydeOS` or `bin/qemu-system-aarch64`, original bundle path under App Translocation | `Locations.swift` |
| `Workspace.prepare(lock:locations:)` clones from the verified store and passes its record, so preparation does not hash again | `Session.swift`, `Workspace.swift` |
| `tryfydeos import-image [PATH]`, store state in `doctor` | `TryFydeOSCLI/main.swift` |
| `ImageController` (notInstalled → importing(progress) → installed, failure back to notInstalled with the error), `CoreImageDriver` (background import, app log lines), launch gated on the image, combined status text, 11 new strings | `TryFydeOSAppModel/ImageController.swift`, `AppController.swift`, `Strings.swift` |
| "FydeOS image" row (version or "Not installed" + Install…), determinate progress row, NSOpenPanel when nothing was found, hidden `-autoImport YES` hook; `-autoLaunch` waits for a running import | `TryFydeOSApp/StartMenuWindow.swift`, `AppDelegate.swift` |
| Bundle without the image by default (`--with-image` for development), QEMU installed as `runtime/bin/Try FydeOS`, `--version` run as a check | `macos/scripts/build-app.sh` |
| DMG: stage, sha256 check of the image, ULFO, ad-hoc or identity signature, optional notarization | `macos/scripts/package-dmg.sh` |
| `make dmg`, `make dmg-stage`, `make import-image` | `Makefile` |

Import sources, in order (the store itself comes first): `TRY_FYDEOS_FACTORY_IMAGE`,
the bundle's `Resources/factory/<file>` (only `--with-image` builds have one),
the repository's `factory/<file>`, then `<folder of the app>/<file>` and
`<folder of the app>/FydeOS/<file>`. The first one that exists is used.

`prepare` and `run` need the store only when the workspace still has to be
cloned. A workspace that is already prepared boots without it, so existing
VMs (Wei's `VM/v1`) are unaffected.

## Tests

```
$ make test   (Linux)          Ran 14 tests … OK
$ make test   (Mac)            Ran 14 tests … OK
                               ✔ Test run with 32 tests in 0 suites passed   (TryFydeOSCoreTests, was 24)
                               ✔ Test run with 23 tests in 0 suites passed   (TryFydeOSAppModelTests, was 18)
```

New core tests (3 MiB fake images, fake specs): empty store names
`import-image`; import through clone and through streaming copy
(parameterized) writes the image and the record, leaves no temp file, and
reports monotonic progress ending at 1.0; digest mismatch leaves the store
empty; size mismatch fails before any progress; a changed mtime or a missing
record makes the store unverified, and a stale temp file is replaced;
candidate order for the repository and the DMG layouts; `prepare` fails on
an empty store and clones without hashing after an import; QEMU name
selection.

New app-model tests: installed at start; sibling detected, import progress,
installed, Launch gated until then; no source needs a file choice; failed
import returns to notInstalled with the error in the status line and one
alert, retry clears it, an import that does not verify is a failure; VM
status wins while the VM is active.

## Bundle

`make app`, 7.1 s wall:

```
…/dist/Try FydeOS.app: valid on disk
…/dist/Try FydeOS.app: satisfies its Designated Requirement
build-app: bundled QEMU: QEMU emulator version 11.1.1
build-app: ok: /Users/fydeos/Workspace/try-fydeos/dist/Try FydeOS.app (173M)
```

```
$ ls "dist/Try FydeOS.app/Contents/Resources" ".../runtime/bin" ".../factory"
factory  firmware  runtime  TryFydeOS.icns
Try FydeOS  zstd
spec.json
$ codesign -dv ".../runtime/bin/Try FydeOS"
Identifier=Try FydeOS-55554944dade877f56133dbcb6bb241007b89ff8
CodeDirectory v=20400 size=47372 flags=0x2(adhoc) hashes=1469+7 location=embedded
$ codesign -d --entitlements - ".../runtime/bin/Try FydeOS"
	[Key] com.apple.security.device.audio-input   [Bool] true
	[Key] com.apple.security.hypervisor           [Bool] true
$ otool -L ".../runtime/bin/Try FydeOS"
	@executable_path/../lib/libpixman-1.0.dylib
	@executable_path/../lib/libepoxy.0.dylib
	@executable_path/../lib/libslirp.0.dylib
	@executable_path/../lib/libglib-2.0.0.dylib
	@executable_path/../lib/libSDL2-2.0.0.dylib
	@executable_path/../lib/libvirglrenderer.1.dylib
	@executable_path/../lib/libusb-1.0.0.dylib
	(plus system frameworks)
```

## First launch with an empty store

The store did not exist yet (`~/Library/Application Support/Try FydeOS/`
held only `VM/`).

`open "dist/Try FydeOS.app"`, polled for the app log line:

```
open at 09:15:44 (1792142144.94)
app started seen after .22 s
2026-10-16T09:15:45Z [91864] app started, version 0.1.0, workspace …/VM/m4
2026-10-16T09:15:45Z [91864] image store …/Try FydeOS/factory: empty
2026-10-16T09:15:45Z [91864] image import source: none found
```

That launch did not trigger a scan. The bundle scan had already run at
build time, when build-app.sh executed the bundled QEMU for `--version`:

```
17:15:32.863696 syspolicyd: GK performScan: PST: (path: e11d09439277545d) …
17:15:33.152654 XprotectService: Xprotect is performing a direct malware and dylib scan: <private>
17:15:33.442744 syspolicyd: GK Xprotect results: … XPScan: 0,…,file:///Users/fydeos/Workspace/try-fydeos/dist/Try%20FydeOS.app/
17:15:33.442758 syspolicyd: GK scan complete: PST: (path: e11d09439277545d) … 0, 0, 0
```

To measure a launch that does pay for the scan, a copy got a new bundle
signature (`CFBundleVersion` changed, outer bundle re-signed ad hoc) in
`out/latency/` and was opened:

```
open at 17:16:17 local (1792142177.05)
app started seen after 1.77 s
2026-10-16T09:16:18Z [91927] app started, version 0.1.0, workspace …/VM/m4

17:16:17.105231 syspolicyd: GK performScan: PST: (path: 9dfc92776fae9327) …
17:16:18.414351 XprotectService: Xprotect is performing a direct malware and dylib scan: <private>
17:16:18.699951 syspolicyd: GK Xprotect results: … file:///Users/fydeos/Workspace/try-fydeos/out/latency/Try%20FydeOS.app/
17:16:18.699965 syspolicyd: GK scan complete: PST: (path: 9dfc92776fae9327) … 0, 0, 0
```

So the scan takes 1.6 s and the first launch 1.8 s, down from a 43 s scan
and a 47 s stall in milestone 3.

## Import from the DMG layout, then boot

`make dmg-stage` (4.3 s, including the sha256 check of the source) produced
`dist/stage/{Try FydeOS.app, FydeOS/<file>, Applications -> /Applications, README.txt}`.

With the store still empty, an unprepared workspace fails as intended:

```
$ tryfydeos prepare --workspace out/ws-test
tryfydeos: the FydeOS image is not installed in /Users/fydeos/Library/Application Support/Try FydeOS/factory (no fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin); run 'tryfydeos import-image [PATH]' or Install… in the app
rc=1
```

(`run` prints the same.) `VM/m4` was reset with `tryfydeos reset --yes`
so that the launch would clone from the store. Then:
`open "dist/stage/Try FydeOS.app" --args -autoImport YES -autoLaunch YES -cpus 4`

```
09:16:58Z [92092] app started, version 0.1.0, workspace …/VM/m4
09:16:58Z [92092] image store …/Try FydeOS/factory: empty
09:16:58Z [92092] image import source: /Users/fydeos/Workspace/try-fydeos/dist/stage/FydeOS/fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin
09:16:58Z [92092] autoImport requested on the command line
09:16:58Z [92092] autoLaunch requested on the command line
09:16:58Z [92092] image import from …/dist/stage/FydeOS/… into …/Try FydeOS/factory started
09:16:58Z [92092] image import: copying 100%
09:16:58Z [92092] image import: verifying 0%
09:16:59Z [92092] image import: verifying 10%
…
09:17:03Z [92092] image import: verifying 100%
09:17:03Z [92092] image import done in 4.3 s, sha256 22587891305d2ffcb9b7db0b5935fd7f29fe70aad75e235e0f27ec2dda4f1dea
09:17:03Z [92092] image installed(version: "R150-16700.56.0 dev 2026-10-16 (kernel patch 025)")
09:17:03Z [92092] state preparing
09:17:03Z [92092] run: run 20261016T091703Z: QEMU pid 92110, logs in …/VM/m4/runs/20261016T091703Z
09:17:03Z [92092] state starting
09:17:03Z [92092] run: QMP ready on …/VM/m4/qmp.sock
09:17:03Z [92092] state running(since: 2026-10-16 09:17:03 +0000)
```

Same volume, so the import was a `clonefile` plus a 4.3 s hash. Store afterwards:

```
-rw-r--r--  7482718720 Oct 16 15:34 fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin
-rw-r--r--         206 Oct 16 17:17 fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin.verified.json
{ "bytes" : 7482718720, "file" : "fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin",
  "mtime" : 1792136043.912789, "sha256" : "22587891305d2ffcb9b7db0b5935fd7f29fe70aad75e235e0f27ec2dda4f1dea" }
```

`VM/m4/metadata.json` has the same factory record (`created 2026-10-16T09:17:03Z`).
Processes:

```
  PID  PPID  PGID STAT COMM
92092     1 92092 S    …/dist/stage/Try FydeOS.app/Contents/MacOS/TryFydeOS
92110 92092 92110 Rs   …/dist/stage/Try FydeOS.app/Contents/Resources/runtime/bin/Try FydeOS
```

`console.log` matches milestones 2 and 3, and boot went on into userspace
(`chromeos_startup`, zram at 3.96 s). `qemu.log` has
`GL strings: version='OpenGL 4.1 (Metal)' renderer='Apple M4' glsl='4.10'`
and `FINAL VALUES: glsl_level=410, max_samples=4`.

```
[    0.000000] ACPI: SPCR: console: pl011,mmio32,0x9000000,9600
[    0.007117] printk: legacy console [ttyAMA0] enabled
[    0.108494] input: QEMU Virtio Tablet as /devices/pci0000:00/0000:00:05.0/virtio4/input/input2
[    0.110525] [drm] features: +virgl +edid -resource_blob -host_visible
[    0.114432] virtio_blk virtio0: [vda] 14614685 512-byte logical blocks (7.48 GB/6.97 GiB)
[    0.264028] frecon[280]: Frecon using drm driver virtio_gpu, version 0.1, date(0), desc(virtio GPU)
```

Shutdown with `osascript -e 'quit app id "io.fydeos.tryfydeos"'` at 17:17:30:

```
2026-10-16T09:17:30Z shutdown requested by the app
2026-10-16T09:17:30Z system_powerdown, waiting 20 s
2026-10-16T09:17:30Z QMP event POWERDOWN
2026-10-16T09:17:50Z quit, waiting 5 s
2026-10-16T09:17:50Z QMP event SHUTDOWN
2026-10-16T09:17:50Z QEMU exit code 0
```

`run.json` has `"end" : "2026-10-16T09:17:50Z", "exitCode" : 0`. The app
log ends with `VM stopped, terminating` and `app exiting`.

## Launch Services name of QEMU

While the VM ran (`lsappinfo list`):

```
106) "Try FydeOS" ASN:0x0-0x8ce8ce:
    bundleID="io.fydeos.tryfydeos"
    bundle path="/Users/fydeos/Workspace/try-fydeos/dist/stage/Try FydeOS.app"
    executable path="…/dist/stage/Try FydeOS.app/Contents/MacOS/TryFydeOS"
    pid = 92092 … type="UIElement" flavor=3 Version="1" fileType="APPL" …
107) "Try FydeOS" ASN:0x0-0x8cf8cf:
    bundleID=[ NULL ]
    bundle path="…/dist/stage/Try FydeOS.app/Contents/Resources/runtime/bin/Try FydeOS"
    executable path="…/dist/stage/Try FydeOS.app/Contents/Resources/runtime/bin/Try FydeOS"
    pid = 92110 … type="Foreground" flavor=2 Version=[ NULL ] fileType="????" …
$ lsappinfo info -only name ASN:0x0-0x8cf8cf
"Try FydeOS" ASN:0x0-0x8cf8cf:
```

Milestone 3 had `"qemu-system-aarch64"` for the same process. What the Dock
tile and menu bar actually draw was not seen (no screen capture over ssh).

## DMG

`make dmg`, 41.6 s wall:

```
package-dmg: checking sha256 of …/factory/fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin
package-dmg: staged …/dist/stage
package-dmg: hdiutil create Try FydeOS-0.1.0.dmg
package-dmg: not notarized (no --notarize-profile)
package-dmg: ok: …/dist/Try FydeOS-0.1.0.dmg 1570022295 bytes (1.5G) in 42 s
```

Format choice, measured on a 2 GiB slice of the image:

| Format | create | size | read back the file from the mounted image |
|---|---|---|---|
| UDZO (zlib) | 25 s | 1076252673 | 2.28 s |
| ULFO (LZFSE) | 17 s | 1041882249 | 1.83 s |

ULFO is 20% faster to decompress, 3% smaller and faster to build. It needs
macOS 10.11, and the app's minimum is 15. The script uses ULFO.

```
$ codesign -dv "dist/Try FydeOS-0.1.0.dmg"
Identifier=Try FydeOS-0-ea4c6610ea10a0855d8a94d12d799322bc876173
Format=disk image
Signature=adhoc
$ codesign --verify -v "dist/Try FydeOS-0.1.0.dmg"
dist/Try FydeOS-0.1.0.dmg: valid on disk
dist/Try FydeOS-0.1.0.dmg: satisfies its Designated Requirement
$ hdiutil attach -nobrowse -readonly -mountpoint /tmp/tfo-dmg "dist/Try FydeOS-0.1.0.dmg"
/dev/disk5s1  41504653-0000-11AA-AA11-0030654  /private/tmp/tfo-dmg
$ ls -la /tmp/tfo-dmg /tmp/tfo-dmg/FydeOS
lrwxr-xr-x  Applications -> /Applications
drwxr-xr-x  FydeOS
-rw-r--r--  238 README.txt
drwxr-xr-x  Try FydeOS.app
-rw-r--r--  7482718720 fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin
/dev/disk5s1 on /private/tmp/tfo-dmg (apfs, local, nodev, nosuid, read-only, journaled, noowners, nobrowse, mounted by fydeos)
$ codesign --verify --strict --verbose=2 "/tmp/tfo-dmg/Try FydeOS.app"
/tmp/tfo-dmg/Try FydeOS.app: valid on disk
/tmp/tfo-dmg/Try FydeOS.app: satisfies its Designated Requirement
```

`hdiutil create -srcfolder` made an APFS volume on this host.

README.txt:

```
Drag Try FydeOS to Applications.
Keep the FydeOS folder next to the app, or move it there; otherwise the app asks for the image and imports it.
The first launch copies the ~7 GB FydeOS image into ~/Library/Application Support/Try FydeOS.
```

Launching the app from the mounted DMG, with the store filled: the app
started and showed the menu (`type="Foreground"`). It was not translocated,
because the locally built DMG has no quarantine attribute (`xattr` shows
only `com.apple.FinderInfo`):

```
"Try FydeOS" ASN:0x0-0x8d18d1:
    bundle path="/private/tmp/tfo-dmg/Try FydeOS.app"
    pid = 92320 … type="Foreground" …
09:19:05Z [92320] app started, version 0.1.0, workspace …/VM/m4
09:19:05Z [92320] image store …/Try FydeOS/factory: verified(… sha256: "22587891…", bytes: 7482718720, mtime: 1792136043.912789)
17:19:04.502975 syspolicyd: GK performScan: PST: (path: 3cdc13b9488e3a9f) …
17:19:05.421300 syspolicyd: GK Xprotect results: … file:///tmp/tfo-dmg/Try%20FydeOS.app/
17:19:05.421313 syspolicyd: GK scan complete: … 0, 0, 0
```

The scan from the read-only volume took 0.9 s. The app was quit with the
AppleEvent (`app exiting` at 09:22:36).

The streaming-copy path was measured from the same mount, with the CLI
importing into a scratch store:

```
$ TRY_FYDEOS_FACTORY_DIR=$PWD/out/store-dmg tryfydeos import-image /tmp/tfo-dmg/FydeOS/fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin
tryfydeos: importing /tmp/tfo-dmg/FydeOS/… into …/out/store-dmg (7482718720 bytes)
tryfydeos: copying 0%
…
tryfydeos: copying 100%
imported …/out/store-dmg/fydeos-arm64-vmware-io-R150-16700.56.0-d20261016.bin sha256 22587891305d2ffcb9b7db0b5935fd7f29fe70aad75e235e0f27ec2dda4f1dea in 5.6 s
```

`clonefile` across volumes failed, and the copy ran with the hash computed
on the fly. 5.6 s for 7.5 GB (decompression included) is with the freshly
built DMG file in the page cache. A downloaded DMG read cold from disk may
take longer. The scratch store was deleted and the DMG detached.

## Not verified

- Clicks: Install… with a detected sibling, Install… → NSOpenPanel, the
  progress bar while it fills, the failure alert, and the window layout
  with the two new rows. The import ran through `-autoImport` only.
- A quarantined (downloaded) DMG: App Translocation and the
  `SecTranslocateCreateOriginalPathForURL` lookup that is meant to find
  `FydeOS/` beside the original app. With an ad-hoc signature Gatekeeper
  would refuse a quarantined app anyway, so this needs a Developer ID build.
- `--sign-identity` and `--notarize-profile`: no credentials. With an
  identity, build-app.sh signs with `--options runtime --timestamp`, which
  notarization requires; whether QEMU and its dylibs run under the hardened
  runtime with only the current entitlements is untested.
- The Dock tile and menu bar labels as drawn on screen; only Launch
  Services' name was checked.

## Deviations

- `prepare`/`run` fail on an empty store only when the workspace still
  needs cloning (see above).
- The bundle's `Resources/factory/<file>` is an import source, placed
  after `TRY_FYDEOS_FACTORY_IMAGE` and before the repository layout.
- `import-image` without PATH is a no-op when the store is already
  verified. With PATH it re-imports.
- Two imports running at the same time would share one temp file name.
  Quitting during an import leaves the temp file, and the next import
  deletes it first.
- `package-dmg.sh` checks the image's sha256 (openssl, about 4 s) before
  staging.
- design.md's Packaging paragraph still describes the image inside the
  bundle. design.md was not edited.
