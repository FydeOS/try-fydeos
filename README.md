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
Makefile          doctor · fetch · runtime · firmware · import-image · prepare · run · icon · app · app-run · dmg · dmg-stage · test
runtime/          QEMU runtime build: lock.json, runtime.py, overlay patches, entitlements
firmware/         edk2 UEFI pair pinned by SHA-256
factory/          spec.json describing the pinned FydeOS factory image
macos/            Swift package: TryFydeOSCore, tryfydeos CLI, TryFydeOSAppModel + the AppKit app;
                  Resources/ (Info.plist, entitlements, icon SVG), scripts/ (build-app.sh, package-dmg.sh, make-icon.sh)
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
make import-image   # copy and verify factory/<image> into the app's image store
make app            # build, assemble and sign dist/Try FydeOS.app (APP_ARGS=--with-image for development)
make app-run        # open the bundle
make dmg            # dist/Try FydeOS-<version>.dmg (DMG_ARGS='--sign-identity ID --notarize-profile P')
make dmg-stage      # only stage the DMG layout in dist/stage/
```

The app does not carry the 7 GB FydeOS image: Gatekeeper scans the whole
bundle on the first launch of every new signature, which took 43 s with
the image inside. The image lives in an image store,
`~/Library/Application Support/Try FydeOS/factory/` (`TRY_FYDEOS_FACTORY_DIR`
overrides it), next to a `<file>.verified.json` written after one full
SHA-256 check. The start menu's "FydeOS image" row installs it from the
first of: `TRY_FYDEOS_FACTORY_IMAGE`, the bundle's own `Resources/factory`
(`--with-image` builds), the repository's `factory/`, or the app's
folder (`<file>` or `FydeOS/<file>`, the DMG layout); otherwise Install…
asks for the file. `tryfydeos import-image [PATH]` does the same from the
command line. New VMs are cloned from the store.

The app's VM workspace defaults to `~/Library/Application Support/Try FydeOS/VM/v1`;
point it elsewhere with `defaults write io.fydeos.tryfydeos workspace <dir>` or
`TRY_FYDEOS_WORKSPACE=<dir>`. Forward host ports on 127.0.0.1 to the guest with
`defaults write io.fydeos.tryfydeos forwards "2200:22"` or `TRY_FYDEOS_FORWARDS=2200:22`
(comma-separated `HOSTPORT:GUESTPORT`). App log: `~/Library/Logs/Try FydeOS/TryFydeOS.log`.
