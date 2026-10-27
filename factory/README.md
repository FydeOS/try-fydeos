# Factory images

One spec per board pins the FydeOS image every new VM of that platform is
unpacked from: `spec.json` for `arm64-vmware-io` (macOS) and
`amd64-vmware-io.json` for `amd64-vmware-io` (Windows, and a Linux port
later). The whole image descriptor is the single `"image"` line, so moving
to a newer build means replacing that line. `diskBytes` is the size of the
VM disk (64 GiB, sparse); the guest grows its stateful partition into it
on first boot.

The arm64 image is a dev build made on the FydeOS workstation:

```sh
cros build-image --board=arm64-vmware-io --no-enable-rootfs-verification dev
```

The amd64 image is the release build of `amd64-vmware-io` from the FydeOS
release tree (`chromiumos_image.bin`, the same image the VMware OVA is
made from).

Either output is compressed with `zstd -T32 -19` into the `.zst` named in
the spec and placed here on the build host (the Mac for arm64; the
workstation for amd64, `make win-image`). Do not add `--long`: the Windows
launcher's Go decoder uses the default window. `bytes` and `sha256`
describe the `.zst` (checked when the image is bundled); `rawBytes` is
checked after every unpack; `rawSha256` is provenance only.
`TRY_FYDEOS_FACTORY_IMAGE` points at another `.zst`.

The images are never committed; `make sync` leaves `factory/*.zst` and
`factory/*.bin` on the Mac alone.

`kernelCommandLine` lists the facts of the image's stock ESP `grub.cfg`
that the QEMU contract depends on: which GRUB entry boots (no dm-verity),
that the command line has no `acpi=off`, and that it names VMware's
`ttyS0`. On the arm64 virt machine the kernel takes its serial console
from the ACPI SPCR table (QEMU's PL011) instead; on q35 `ttyS0` is QEMU's
serial port itself. No command-line edit is needed on either.
