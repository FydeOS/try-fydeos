# Try FydeOS

Run FydeOS on a Mac or a Windows PC without installing it. Try FydeOS
wraps QEMU and the host's hypervisor around the stock FydeOS vmware image,
the same image FydeOS ships for VMware: `arm64-vmware-io` on Apple Silicon,
`amd64-vmware-io` on x86-64 Windows. A Linux version is planned.

Modeled on [Try Omarchy](https://tryomarchy.com) (MIT). The QEMU runtimes
are built from Try Omarchy's recipes, pinned by commit and hash, with this
project's overlay patches; the launchers, storage, lifecycle and guest
contract are this project's own.

Status:

- macOS: `make app` assembles an ad-hoc signed `dist/Try FydeOS.app` and
  `make dmg` wraps it with the FydeOS image in `dist/Try FydeOS-<version>.dmg`.
  No Developer ID yet.
- Windows: `make win-dist` builds the single self-contained
  `dist/Try FydeOS-<version>.exe` (launcher, QEMU runtime and the FydeOS
  image in one file); `make win-runtime-build` cross-builds the runtime
  in Docker. No code-signing certificate yet.

## Layout

```
Makefile          Mac: doctor · fetch · runtime · firmware · prepare · run · icon · app · app-run · dmg · dmg-stage
                  Windows (run on the workstation): win-runtime · win-runtime-build · win-build · win-test · win-rsrc · win-image · win-sync · win-dist
                  both: sync · test
docs/             design.md (overview), decisions.md; macos/ and windows/ hold each platform's design.md and records
factory/          one spec per board (spec.json = arm64, amd64-vmware-io.json); images never committed
runtime/          macOS QEMU runtime build: lock.json, runtime.py, overlay patches, entitlements
firmware/         edk2 UEFI pair for the macOS runtime, pinned by SHA-256
macos/            Swift package: TryFydeOSCore, tryfydeos CLI, TryFydeOSAppModel + the AppKit app;
                  Resources/ (Info.plist, entitlements, icon SVG), scripts/ (build-app.sh, package-dmg.sh, make-icon.sh)
windows/          Go module: internal/core, internal/app, internal/payload, cmd/; runtime/ (QEMU cross-build recipe), runtime.lock.json, scripts/
tests/            contract tests that run without a VM
```

## Hosts

- macOS build and run: Apple Silicon Mac, macOS 15 or newer, Command Line
  Tools, Homebrew `pkg-config` and `python3` 3.12+. No Docker, no Homebrew
  QEMU.
- Windows build: any machine with Go 1.24+ (the launcher is pure Go and
  cross-compiles), Docker for the QEMU runtime, plus `llvm-rc`,
  `llvm-cvtres` and ImageMagick to regenerate the icon resources. Windows
  run: 64-bit Windows 10 or 11 on x86-64 with hardware virtualization and
  the Windows Hypervisor Platform enabled, on an NTFS or ReFS drive.
- Factory images: `cros build-image` output for the vmware boards, or the
  release build for the board. The images are never committed.

## Workflow

The tree is authored on the workstation at `~/workspace/try-fydeos`.

macOS: synced to the Mac at `~/Workspace/try-fydeos` with `make sync`;
build output and caches live only on the Mac under `.cache/`, `out/`,
`macos/.build/` and `dist/`.

```sh
make sync           # workstation -> Mac
make doctor         # on the Mac: toolchain, pins, capabilities
make runtime        # build the QEMU runtime (20-40 min first time)
make firmware       # extract the pinned edk2 pair from the pinned QEMU tarball
make app            # build, assemble and sign dist/Try FydeOS.app with factory/<image>.zst inside
make app-run        # open the bundle
make dmg            # dist/Try FydeOS-<version>.dmg (DMG_ARGS='--sign-identity ID --notarize-profile P')
make dmg-stage      # only stage the DMG layout in dist/stage/
```

Windows: built on the workstation, tested on a Windows machine reached
over SSH (see `windows/README.md`).

```sh
make win-runtime-build  # cross-build the QEMU runtime in Docker: out/win-runtime/ + out/win-runtime-<lock>.zip
make win-runtime    # unpack the pinned runtime into out/win-runtime/ (WIN_RUNTIME=own|omarchy)
make win-test       # go vet + go test (OS-independent parts, fake QEMU)
make win-build      # out/win-build/tryfydeos.exe and "Try FydeOS.exe"
make win-image      # compress the amd64 raw image into factory/
make win-sync       # copy the build to the test machine
make win-dist       # dist/Try FydeOS-<version>.exe with runtime, image and spec appended
```

## Image and VM data

Both apps carry the FydeOS image zstd-compressed. Preparing a VM unpacks it
into the workspace, checks the raw size and grows the file, sparse, to the
64 GiB `diskBytes` of the board's spec. `TRY_FYDEOS_FACTORY_IMAGE` points
at another `.zst`. Factory reset deletes the disk; the next launch unpacks
again.

| | macOS | Windows |
|---|---|---|
| VM workspace | `~/Library/Application Support/Try FydeOS/VM/v1` | `%LOCALAPPDATA%\Try FydeOS\VM\v1` |
| Override | `defaults write io.fydeos.tryfydeos workspace <dir>` or `TRY_FYDEOS_WORKSPACE` | `preferences.json` `workspace` or `TRY_FYDEOS_WORKSPACE` |
| Port forwards | `defaults write io.fydeos.tryfydeos forwards "2200:22"` or `TRY_FYDEOS_FORWARDS` | `preferences.json` `forwards` or `TRY_FYDEOS_FORWARDS` |
| App log | `~/Library/Logs/Try FydeOS/TryFydeOS.log` | `%LOCALAPPDATA%\Try FydeOS\Logs\TryFydeOS.log` |

Forwards are comma-separated `HOSTPORT:GUESTPORT` pairs on 127.0.0.1.
