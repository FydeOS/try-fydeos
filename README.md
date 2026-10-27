# Try FydeOS

Run FydeOS on a Mac without installing it. Try FydeOS wraps a patched QEMU
with Apple's Hypervisor framework and VirGL graphics around a stock FydeOS
`arm64-vmware-io` image, the same image FydeOS ships for VMware.

Modeled on [Try Omarchy](https://tryomarchy.com) (MIT). The QEMU runtime
recipe is Try Omarchy's, consumed by pinned commit and hash; the launcher,
storage, lifecycle and guest contract are this project's own.

Status: milestone 4, packaging. `make app` assembles an ad-hoc signed
`dist/Try FydeOS.app` (~170 MB, no image inside) and `make dmg` wraps it with
the FydeOS image in `dist/Try FydeOS-<version>.dmg`. No Developer ID yet.

## Layout

```
Makefile          doctor · fetch · runtime · firmware · prepare · run · icon · app · app-run · dmg · dmg-stage · test
runtime/          QEMU runtime build: lock.json, runtime.py, overlay patches, entitlements
firmware/         edk2 UEFI pair pinned by SHA-256
factory/          spec.json describing the pinned FydeOS factory image
macos/            Swift package: TryFydeOSCore, tryfydeos CLI, TryFydeOSAppModel + the AppKit app;
                  Resources/ (Info.plist, entitlements, icon SVG), scripts/ (build-app.sh, package-dmg.sh, make-icon.sh)
windows/          Go module for the Windows port (docs/windows.md): internal/core, tryfydeos CLI, runtime.lock.json
docs/             design.md, decisions.md, carried-over-findings.md
tests/            contract tests that run without a VM
```

## Hosts

- Build and run: Apple Silicon Mac, macOS 15 or newer, Command Line Tools,
  Homebrew `pkg-config` and `python3` 3.12+. No Docker, no Homebrew QEMU.
- Factory image: built on a FydeOS development workstation with
  `cros build-image --board=arm64-vmware-io`. The image is never committed.

## Workflow

The tree is authored on the workstation at `~/workspace/try-fydeos` and
synced to the Mac at `~/Workspace/try-fydeos` with `make sync`. Build output
and caches live only on the Mac under `.cache/`, `out/`, `macos/.build/` and `dist/`.

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

The app carries the FydeOS image zstd-compressed (1.36 GB) in
`Contents/Resources/factory/`. Preparing a VM unpacks it with the bundled
`zstd` into the workspace (about 3 s on an M4), checks the raw size and
grows the file, sparse, to the 64 GiB `diskBytes` of `factory/spec.json`.
`TRY_FYDEOS_FACTORY_IMAGE` points at another `.zst`; in the repository the
image is `factory/<file>`. Factory reset deletes the disk; the next launch
unpacks again.

The app's VM workspace defaults to `~/Library/Application Support/Try FydeOS/VM/v1`;
point it elsewhere with `defaults write io.fydeos.tryfydeos workspace <dir>` or
`TRY_FYDEOS_WORKSPACE=<dir>`. Forward host ports on 127.0.0.1 to the guest with
`defaults write io.fydeos.tryfydeos forwards "2200:22"` or `TRY_FYDEOS_FORWARDS=2200:22`
(comma-separated `HOSTPORT:GUESTPORT`). App log: `~/Library/Logs/Try FydeOS/TryFydeOS.log`.
