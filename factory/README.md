# Factory image

`spec.json` pins the FydeOS image every new VM is cloned from. The whole
image descriptor is the single `"image"` line, so moving to a newer build
means replacing that line.

The image is a dev build made on the FydeOS workstation:

```sh
cros build-image --board=arm64-vmware-io --no-enable-rootfs-verification dev
```

Its output, `chromiumos_image.bin`, is copied to the Mac as the file named
in `spec.json` and placed here (an APFS clone, `cp -c`, keeps it free).
`TRY_FYDEOS_FACTORY_IMAGE` points elsewhere instead. Either is only an
import source: `tryfydeos import-image` (or Install… in the app) clones or
copies it into the image store, `~/Library/Application Support/Try FydeOS/factory/`,
checks the full SHA-256 once and records it; later uses check size and
mtime only. `make dmg` ships this file beside the app as `FydeOS/<file>`.

The `.bin` is never committed.

`kernelCommandLine` lists the facts of the image's stock ESP `grub.cfg`
that the QEMU contract depends on: GRUB boots `local image A` (no
dm-verity), the command line has no `acpi=off`, and it names VMware's
`ttyS0`; under QEMU the kernel takes its serial console from the ACPI SPCR
table (QEMU's PL011) instead, so no command-line edit is needed.
