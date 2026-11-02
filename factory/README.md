# Factory images

One spec per board pins the FydeOS image every new VM of that platform is
made from: `spec.json` for `arm64-vmware-io` (macOS) and
`amd64-vmware-io.json` for `amd64-vmware-io` (Windows, and a Linux port
later). `diskBytes` is the size of the VM disk (64 GiB, sparse); the guest
grows its stateful partition into it on first boot.

## Schema 2

Both specs pin the published VMware image, which the launcher downloads
and converts itself; no image is built, compressed or kept here.

- `image`: the pinned download. `url` (https), `bytes` and `sha256` of the
  file as served, `version` as text. Moving to a newer build means
  replacing this line.
- `release`: the release API (`api`, https) and the API's `board`
  (`amd64-vmware` or `arm64-vmware`). When the API's entry has another
  checksum than the pinned image, the launcher installs the API's image
  instead; when the API is unreachable it uses the pinned one.
- `diskBytes`, `board`, `kernelCommandLine` as below.

The amd64 download is an `.ova` with a streamOptimized VMDK; the arm64
download is a zip of a VMware Fusion `.vmwarevm` folder with a
monolithicSparse VMDK. Either disk is 50 GiB holding
`chromiumos_image.bin` followed by zeros. The launcher keeps (GPT
alternate header LBA + 1) * 512 bytes of it (7,314,946,560 and
7,482,718,720 for v23.1 Preview1), refuses a disk with data beyond that,
and records the length as `rawBytes` in the VM's `metadata.json`.
`TRY_FYDEOS_FACTORY_IMAGE` points at a local `.ova` or `.zip` used instead
of a download; on Windows the spec is then looked for next to it.

## Kernel command line

`kernelCommandLine` lists the facts of the image's stock ESP `grub.cfg`
that the QEMU contract depends on: which GRUB entry boots (no dm-verity),
that the command line has no `acpi=off`, and that it names VMware's
`ttyS0`. On the arm64 virt machine the kernel takes its serial console
from the ACPI SPCR table (QEMU's PL011) instead; on q35 `ttyS0` is QEMU's
serial port itself. No command-line edit is needed on either.
