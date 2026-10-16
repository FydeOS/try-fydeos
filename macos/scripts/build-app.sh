#!/bin/bash
# Assemble and sign dist/Try FydeOS.app.
#   --no-image             leave the factory image out of the bundle
#   --sign-identity ID     codesign identity (default "-", ad hoc)
set -euo pipefail

usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
image=1
identity=-
while [ $# -gt 0 ]; do
    case "$1" in
        --no-image) image=0 ;;
        --sign-identity) [ $# -ge 2 ] || usage; identity=$2; shift ;;
        *) usage ;;
    esac
    shift
done

[ "$(uname -s)" = Darwin ] || { echo "build-app: run on the Mac" >&2; exit 1; }
repo=$(cd "$(dirname "$0")/../.." && pwd)
runtime_src="$repo/out/runtime/current/runtime"
qemu_ent="$repo/runtime/entitlements/qemu.entitlements"
app_ent="$repo/macos/Resources/TryFydeOS.entitlements"
app="$repo/dist/Try FydeOS.app"
stage="$repo/dist/.Try FydeOS.app.stage"
icon="$repo/macos/.build/TryFydeOS.icns"

say() { echo "build-app: $*"; }
die() { echo "build-app: $*" >&2; exit 1; }

[ -x "$runtime_src/bin/qemu-system-aarch64" ] || die "no runtime at $runtime_src (make runtime)"
count=$(find "$runtime_src" -type f | wc -l | tr -d ' ')
[ "$count" = 17 ] || die "runtime has $count files, expected 17"
ls "$repo"/firmware/*.fd >/dev/null 2>&1 || die "no firmware in $repo/firmware (make firmware)"

say "swift build -c release"
(cd "$repo/macos" && swift build -c release --product TryFydeOSApp)
bin="$(cd "$repo/macos" && swift build -c release --show-bin-path)/TryFydeOSApp"

if [ ! -f "$icon" ] || [ "$repo/macos/Resources/TryFydeOSIcon.svg" -nt "$icon" ]; then
    "$repo/macos/scripts/make-icon.sh" "$icon" >/dev/null
fi

rm -rf "$stage"
contents="$stage/Contents"
res="$contents/Resources"
mkdir -p "$contents/MacOS" "$res/firmware" "$res/factory"
cp "$bin" "$contents/MacOS/TryFydeOS"
cp "$repo/macos/Resources/Info.plist" "$contents/Info.plist"
cp "$icon" "$res/TryFydeOS.icns"
ditto "$runtime_src" "$res/runtime"
cp "$repo"/firmware/*.fd "$res/firmware/"
cp "$repo/factory/spec.json" "$res/factory/spec.json"

if [ "$image" = 1 ]; then
    file=$(plutil -extract image.file raw -o - "$repo/factory/spec.json")
    bytes=$(plutil -extract image.bytes raw -o - "$repo/factory/spec.json")
    src="$repo/factory/$file"
    [ -f "$src" ] || die "factory image $src missing (or pass --no-image)"
    size=$(stat -f %z "$src")
    [ "$size" = "$bytes" ] || die "factory image $src is $size bytes, spec says $bytes"
    say "cloning $file"
    cp -c "$src" "$res/factory/$file"
fi

sign() { codesign --force --sign "$identity" --timestamp=none "$@"; }
say "signing with identity '$identity'"
for f in "$res"/runtime/lib/*.dylib "$res/runtime/bin/zstd"; do sign "$f"; done
sign --entitlements "$qemu_ent" "$res/runtime/bin/qemu-system-aarch64"
sign --entitlements "$app_ent" "$contents/MacOS/TryFydeOS"
sign --entitlements "$app_ent" "$stage"

rm -rf "$app"
mv "$stage" "$app"
res="$app/Contents/Resources"
qemu="$res/runtime/bin/qemu-system-aarch64"

codesign --verify --strict --verbose=2 "$app"
codesign --verify --strict "$qemu"
codesign -d --entitlements - --xml "$qemu" 2>/dev/null | grep -q 'com.apple.security.hypervisor' \
    || die "bundled QEMU lacks the hypervisor entitlement"
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'com.apple.security.device.audio-input' \
    || die "app lacks the audio-input entitlement"
[ "$(cd "$(dirname "$qemu")/../.." && pwd)/TryFydeOS.icns" = "$res/TryFydeOS.icns" ] && [ -f "$res/TryFydeOS.icns" ] \
    || die "TryFydeOS.icns is not three levels above QEMU"
say "ok: $app ($(du -sh "$app" | cut -f1) logical)"
