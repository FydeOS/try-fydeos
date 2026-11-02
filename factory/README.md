# Factory images

One spec per board pins the FydeOS image every new VM of that platform is
made from: `spec.json` for `arm64-vmware-io` (macOS) and
`amd64-vmware-io.json` for `amd64-vmware-io` (Windows, and a Linux port
later). `diskBytes` is the size of the VM disk (64 GiB, sparse); the guest
grows its stateful partition into it on first boot.

## amd64 (Windows): schema 2

`amd64-vmware-io.json` pins the published VMware image, which the
launcher downloads and converts itself; no image is built, compressed or
kept here.

- `image`: the pinned download. `url` (https), `bytes` and `sha256` of the
  `.ova` as served, `version` as text. Moving to a newer build means
  replacing this line.
- `release`: the release API (`api`, https) and the API's `board`
  (`amd64-vmware`). When the API's entry has another checksum than the
  pinned image, the launcher installs the API's image instead; when the
  API is unreachable it uses the pinned one.
- `diskBytes`, `board`, `kernelCommandLine` as below.

The OVA's disk is a 50 GiB VMDK holding `chromiumos_image.bin` followed by
zeros. The launcher keeps (GPT alternate header LBA + 1) * 512 bytes of it
(7,314,946,560 for v23.1 Preview1), refuses a disk with data beyond that,
and records the length as `rawBytes` in the VM's `metadata.json`.
`TRY_FYDEOS_FACTORY_IMAGE` points at a local `.ova` (or VMware `.zip`)
used instead of a download; the spec is then looked for next to it.

## arm64 (macOS): schema 1

The arm64 spec moves to schema 2 with the Mac change; until then it pins a
zstd image. The whole image descriptor is the single `"image"` line.

The arm64 image is a dev build made on the FydeOS workstation:

```sh
cros build-image --board=arm64-vmware-io --no-enable-rootfs-verification dev
```

The output is compressed with `zstd -T32 -19` into the `.zst` named in the
spec and placed here on the Mac. `bytes` and `sha256` describe the `.zst`
(checked when the image is bundled); `rawBytes` is checked after every
unpack; `rawSha256` is provenance only.

The images are never committed; `make sync` leaves `factory/*.zst` and
`factory/*.bin` on the Mac alone.

## Kernel command line

`kernelCommandLine` lists the facts of the image's stock ESP `grub.cfg`
that the QEMU contract depends on: which GRUB entry boots (no dm-verity),
that the command line has no `acpi=off`, and that it names VMware's
`ttyS0`. On the arm64 virt machine the kernel takes its serial console
from the ACPI SPCR table (QEMU's PL011) instead; on q35 `ttyS0` is QEMU's
serial port itself. No command-line edit is needed on either.
