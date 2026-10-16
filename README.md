# Try FydeOS

Run FydeOS on a Mac without installing it. Try FydeOS wraps a patched QEMU
with Apple's Hypervisor framework and VirGL graphics around a stock FydeOS
`arm64-vmware-io` image, the same image FydeOS ships for VMware.

Modeled on [Try Omarchy](https://tryomarchy.com) (MIT). The QEMU runtime
recipe is Try Omarchy's, consumed by pinned commit and hash; the launcher,
storage, lifecycle and guest contract are this project's own.

Status: milestone 3, the app. `make app` assembles an ad-hoc signed
`dist/Try FydeOS.app`; no DMG or Developer ID yet.

## Layout

```
Makefile          doctor · fetch · runtime · firmware · prepare · run · icon · app · app-run · test
runtime/          QEMU runtime build: lock.json, runtime.py, overlay patches, entitlements
firmware/         edk2 UEFI pair pinned by SHA-256
factory/          spec.json describing the pinned FydeOS factory image
macos/            Swift package: TryFydeOSCore, tryfydeos CLI, TryFydeOSAppModel + the AppKit app;
                  Resources/ (Info.plist, entitlements, icon SVG), scripts/ (build-app.sh, make-icon.sh)
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
make app            # build, assemble and sign dist/Try FydeOS.app (APP_ARGS=--no-image)
make app-run        # open the bundle
```

The app's VM workspace defaults to `~/Library/Application Support/Try FydeOS/VM/v1`;
point it elsewhere with `defaults write io.fydeos.tryfydeos workspace <dir>` or
`TRY_FYDEOS_WORKSPACE=<dir>`. App log: `~/Library/Logs/Try FydeOS/TryFydeOS.log`.
