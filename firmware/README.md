# Firmware

The UEFI pair QEMU boots FydeOS with: `edk2-aarch64-code.fd` (read-only
code) and `edk2-arm-vars.fd` (pristine variable store, copied per VM).

`make firmware` extracts both from `pc-bios/*.fd.bz2` in the pinned QEMU
source tarball (`qemu-c3d48b7d…`, QEMU 11.1.1, see `runtime/lock.json`),
decompresses them and checks them against `SHA256SUMS`. The `.fd` files
are build outputs and are not committed. edk2 is BSD-2-Clause-Patent.
