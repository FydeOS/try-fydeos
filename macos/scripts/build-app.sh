#!/bin/bash
# Assemble and sign dist/Try FydeOS.app; it downloads the FydeOS image at first launch.
#   --edition io|com       edition to build (default io)
#   --sign-identity ID     codesign identity (default "-", ad hoc)
set -euo pipefail

usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
identity=-
edition=io
while [ $# -gt 0 ]; do
    case "$1" in
        --edition) [ $# -ge 2 ] || usage; edition=$2; shift ;;
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
case "$edition" in io|com) ;; *) usage ;; esac
app="$repo/dist/Try FydeOS.app"
stage="$repo/dist/.Try FydeOS.app.stage"
spec="$repo/factory/arm64-vmware-$edition.json"
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
if [ "$edition" = com ]; then
    plutil -replace TryFydeOSEdition -string com "$contents/Info.plist"
fi
cp "$icon" "$res/TryFydeOS.icns"
ditto "$runtime_src" "$res/runtime"
cp "$repo"/firmware/*.fd "$res/firmware/"
cp "$spec" "$res/factory/spec.json"

# Launch Services labels the Dock tile and menu bar with the executable's file name.
mv "$res/runtime/bin/qemu-system-aarch64" "$res/runtime/bin/Try FydeOS"

# Notarization needs the hardened runtime and a secure timestamp; ad-hoc builds keep neither.
if [ "$identity" = - ]; then
    sign() { codesign --force --sign - --timestamp=none "$@"; }
else
    sign() { codesign --force --sign "$identity" --options runtime --timestamp "$@"; }
fi
say "signing with identity '$identity'"
for f in "$res"/runtime/lib/*.dylib "$res/runtime/bin/zstd"; do sign "$f"; done
sign --entitlements "$qemu_ent" "$res/runtime/bin/Try FydeOS"
sign --entitlements "$app_ent" "$contents/MacOS/TryFydeOS"
sign --entitlements "$app_ent" "$stage"

rm -rf "$app"
mv "$stage" "$app"
res="$app/Contents/Resources"
qemu="$res/runtime/bin/Try FydeOS"

codesign --verify --strict --verbose=2 "$app"
codesign --verify --strict "$qemu"
codesign -d --entitlements - --xml "$qemu" 2>/dev/null | grep -q 'com.apple.security.hypervisor' \
    || die "bundled QEMU lacks the hypervisor entitlement"
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'com.apple.security.device.audio-input' \
    || die "app lacks the audio-input entitlement"
[ "$(cd "$(dirname "$qemu")/../.." && pwd)/TryFydeOS.icns" = "$res/TryFydeOS.icns" ] && [ -f "$res/TryFydeOS.icns" ] \
    || die "TryFydeOS.icns is not three levels above QEMU"
version=$("$qemu" --version | head -1) || die "bundled QEMU does not run"
say "bundled QEMU: $version"
say "ok: $app ($(du -sh "$app" | cut -f1))"
