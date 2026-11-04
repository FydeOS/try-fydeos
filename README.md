# Try FydeOS

Run FydeOS on a Mac or a Windows PC without installing it. Try FydeOS
wraps QEMU and the host's hypervisor around the stock FydeOS vmware image,
the same image FydeOS publishes for VMware: `arm64-vmware-io` on Apple
Silicon, `amd64-vmware-io` on x86-64 Windows. The app downloads that image
at first launch and converts it itself. The clipboard is shared with the
host (text, both directions). A Linux version is planned.

Modeled on [Try Omarchy](https://tryomarchy.com) (MIT). The QEMU runtimes
are built from Try Omarchy's recipes, pinned by commit and hash, with this
project's overlay patches; the launchers, storage, lifecycle and guest
contract are this project's own.

Status:

- macOS: `make app` assembles an ad-hoc signed `dist/Try FydeOS.app`
  (173 MB) and `make dmg` wraps it in `dist/Try FydeOS-<version>.dmg`.
  No Developer ID yet.
- Windows: `make win-dist` builds the single self-contained
  `dist/Try FydeOS-<version>.exe` (launcher and QEMU runtime in one 51 MB
  file); `make win-runtime-build` cross-builds the runtime in Docker. No
  code-signing certificate yet.

## Layout

```
Makefile          Mac: doctor · fetch · runtime · firmware · prepare · run · icon · app · app-run · dmg · dmg-stage
                  Windows (run on the workstation): win-runtime · win-runtime-build · win-build · win-test · win-rsrc · win-sync · win-dist
                  both: sync · test
docs/             design.md (overview), decisions.md; macos/ and windows/ hold each platform's design.md and records
factory/          one spec per board and edition (<board>-io.json, <board>-com.json) pinning the published image
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
- Images: the VMware downloads FydeOS publishes for the vmware boards,
  fetched by the app at first launch; nothing is built or committed here.

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
make app            # build, assemble and sign dist/Try FydeOS.app
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
make win-sync       # copy the build to the test machine
make win-dist       # dist/Try FydeOS-<version>.exe with the runtime and spec appended
```

## Continuous integration

GitHub Actions (`.github/workflows/`) run the unit tests on every pull
request, build the QEMU runtimes when a lock changes and publish them as
`win-runtime-<hash>` / `mac-runtime-<hash>` pre-releases, and build the
four installers on every push; a `v<version>` tag turns them into a
GitHub Release. The release workflow checks the tag against
`windows/versioninfo.rc` and `macos/Resources/Info.plist`. See decision
D16 in `docs/decisions.md`.

## Image and VM data

At first launch the app asks FydeOS's release API for the board's latest
VMware image, downloads it (the spec's pinned image when the API is
unreachable or lists the same one) into the `images` directory with
resume and a SHA-256 check, and decodes the VMDK inside into the VM disk,
cut at the end of the FydeOS image and grown, sparse, to the 64 GiB
`diskBytes` of the board's spec. The download is kept: factory reset
deletes the disk and the next launch converts again without downloading.
Only the download the VM was prepared from is kept; a newer one replaces
it once verified.
When the API lists a newer image than the installed one, the start menu
says so and a factory reset installs it. `TRY_FYDEOS_FACTORY_IMAGE` points
at a local `.ova` or VMware `.zip` to use instead of a download.

| | macOS | Windows |
|---|---|---|
| Images | `~/Library/Application Support/Try FydeOS/images` | `%LOCALAPPDATA%\Try FydeOS\images` |
| VM workspace | `~/Library/Application Support/Try FydeOS/VM/v1` | `%LOCALAPPDATA%\Try FydeOS\VM\v1` |
| Override | `defaults write io.fydeos.tryfydeos workspace <dir>` or `TRY_FYDEOS_WORKSPACE` | `preferences.json` `workspace` or `TRY_FYDEOS_WORKSPACE` |
| Port forwards | `defaults write io.fydeos.tryfydeos forwards "2200:22"` or `TRY_FYDEOS_FORWARDS` | `preferences.json` `forwards` or `TRY_FYDEOS_FORWARDS` |
| App log | `~/Library/Logs/Try FydeOS/TryFydeOS.log` | `%LOCALAPPDATA%\Try FydeOS\Logs\TryFydeOS.log` |

Forwards are comma-separated `HOSTPORT:GUESTPORT` pairs on 127.0.0.1.
