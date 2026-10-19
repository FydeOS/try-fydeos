# Factory image

`spec.json` pins the FydeOS image every new VM is unpacked from. The whole
image descriptor is the single `"image"` line, so moving to a newer build
means replacing that line. `diskBytes` is the size of the VM disk (64 GiB,
sparse); the guest grows its stateful partition into it on first boot.

The image is a dev build made on the FydeOS workstation:

```sh
cros build-image --board=arm64-vmware-io --no-enable-rootfs-verification dev
```

Its output, `chromiumos_image.bin`, is compressed with
`zstd -T32 -19` into the `.zst` named in `spec.json` and placed here on the
Mac. `bytes` and `sha256` describe the `.zst` (checked by `make app`, which
bundles it); `rawBytes` is checked after every unpack; `rawSha256` is
provenance only. `TRY_FYDEOS_FACTORY_IMAGE` points at another `.zst`.

The image is never committed; `make sync` leaves `factory/*.zst` and
`factory/*.bin` on the Mac alone.

`kernelCommandLine` lists the facts of the image's stock ESP `grub.cfg`
that the QEMU contract depends on: GRUB boots `local image A` (no
dm-verity), the command line has no `acpi=off`, and it names VMware's
`ttyS0`; under QEMU the kernel takes its serial console from the ACPI SPCR
table (QEMU's PL011) instead, so no command-line edit is needed.
