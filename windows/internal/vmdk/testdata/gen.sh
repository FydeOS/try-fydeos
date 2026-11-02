#!/bin/bash
# Regenerates the fixtures in this directory; needs qemu-img, sfdisk, tar,
# zip, gzip.
#
# raw (16 MiB = 256 grains of 64 KiB): an image of 8 MiB - 32 KiB with a GPT,
# zero-extended to 16 MiB like the published disks, so the image ends inside
# grain 127; zeros except the GPT and:
#   0x000000 64 KiB  grain 0   "try-fydeos grain first"
#   0x203000  4 KiB  grain 32  "try-fydeos partial" (rest of the grain zero)
#   0x400000 64 KiB  grain 64  "try-fydeos grain middle"
#   0x7f0000 32 KiB  grain 127 "try-fydeos grain last"
#
# sparse.vmdk is monolithicSparse; its uncompressed grains exceed the fixture
# budget, so it is stored gzipped. qemu-img pads stream.vmdk with zero sectors
# after its grains; the first one is the end-of-stream marker and the rest are
# cut. The raw itself is not kept, only its sha256. beyond.ova holds the same
# disk plus data at 12 MiB, past the GPT's end.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/beyond"

fill() {
	{ yes "$1" || true; } | head -c "$3" | dd of="$work/disk.raw" bs=4096 seek=$(($2 / 4096)) conv=notrunc status=none
}
truncate -s 8M "$work/disk.raw"
fill "try-fydeos grain first" 0x000000 65536
fill "try-fydeos partial" 0x203000 4096
fill "try-fydeos grain middle" 0x400000 65536
fill "try-fydeos grain last" 0x7f0000 32768
truncate -s $((8 * 1024 * 1024 - 32768)) "$work/disk.raw"
printf '%s\n' 'label: gpt' 'label-id: 7E1C2A4B-0000-4000-8000-000000000001' \
	'start=2048, size=8192, uuid=7E1C2A4B-0000-4000-8000-000000000002' | sfdisk -q "$work/disk.raw"
truncate -s 16M "$work/disk.raw"
sha256sum "$work/disk.raw" | cut -d' ' -f1 >raw.sha256

qemu-img convert -f raw -O vmdk "$work/disk.raw" "$work/sparse.vmdk"
qemu-img convert -f raw -O vmdk -o subformat=streamOptimized "$work/disk.raw" "$work/stream.vmdk"
python3 -I -c '
import sys
d = open(sys.argv[1], "rb").read().rstrip(b"\0")
open(sys.argv[2], "wb").write(d + bytes(-len(d) % 512 + 512))
' "$work/stream.vmdk" stream.vmdk
qemu-img compare -q -f raw -F vmdk "$work/disk.raw" stream.vmdk
qemu-img compare -q -f raw -F vmdk "$work/disk.raw" "$work/sparse.vmdk"
gzip -9n <"$work/sparse.vmdk" >sparse.vmdk.gz

fill "try-fydeos beyond the GPT" 0xc00000 4096
qemu-img convert -f raw -O vmdk -o subformat=streamOptimized "$work/disk.raw" "$work/beyond/stream.vmdk"
tar -C "$work/beyond" -cf beyond.ova --format=ustar --owner=0 --group=0 --mtime=@0 stream.vmdk

mkdir "$work/ova" "$work/zip" "$work/zip/dir.vmwarevm"
printf '<?xml version="1.0"?>\n<Envelope/>\n' >"$work/ova/test.ovf"
printf 'SHA256(stream.vmdk)= %s\n' "$(sha256sum stream.vmdk | cut -d' ' -f1)" >"$work/ova/test.mf"
cp stream.vmdk "$work/ova/"
tar -C "$work/ova" -cf test.ova --format=ustar --owner=0 --group=0 --mtime=@0 test.ovf test.mf stream.vmdk

printf '.encoding = "UTF-8"\n' >"$work/zip/dir.vmwarevm/x.vmx"
cp "$work/sparse.vmdk" "$work/zip/dir.vmwarevm/sparse.vmdk"
rm -f test.zip
(cd "$work/zip" && zip -qX -9 -r "$OLDPWD/test.zip" dir.vmwarevm)

ls -l raw.sha256 sparse.vmdk.gz stream.vmdk test.ova test.zip beyond.ova
