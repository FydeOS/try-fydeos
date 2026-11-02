#!/bin/bash
# Build dist/Try FydeOS-<version>.dmg: the app and an Applications link.
#   --sign-identity ID       codesign identity for the DMG (default "-", ad hoc)
#   --notarize-profile NAME  notarytool keychain profile; submit, wait and staple (skipped when absent)
#   --stage-only             stop after staging dist/stage/
set -euo pipefail

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
identity=-
profile=
stage_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --sign-identity) [ $# -ge 2 ] || usage; identity=$2; shift ;;
        --notarize-profile) [ $# -ge 2 ] || usage; profile=$2; shift ;;
        --stage-only) stage_only=1 ;;
        *) usage ;;
    esac
    shift
done

[ "$(uname -s)" = Darwin ] || { echo "package-dmg: run on the Mac" >&2; exit 1; }
repo=$(cd "$(dirname "$0")/../.." && pwd)
app="$repo/dist/Try FydeOS.app"
stage="$repo/dist/stage"

say() { echo "package-dmg: $*"; }
die() { echo "package-dmg: $*" >&2; exit 1; }

start=$(date +%s)
[ -d "$app" ] || die "no $app (make app)"
[ -f "$app/Contents/Resources/factory/spec.json" ] || die "$app does not carry factory/spec.json (make app)"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
codesign --verify --strict "$app" || die "$app does not verify"

rm -rf "$stage"
mkdir -p "$stage"
ditto "$app" "$stage/Try FydeOS.app"
ln -s /Applications "$stage/Applications"
say "staged $stage"
[ "$stage_only" = 0 ] || exit 0

# ULFO (LZFSE) over UDZO (zlib): 20% faster to read back on Apple Silicon and slightly smaller.
dmg="$repo/dist/Try FydeOS-$version.dmg"
rm -f "$dmg"
say "hdiutil create $(basename "$dmg")"
hdiutil create -quiet -volname "Try FydeOS" -srcfolder "$stage" -format ULFO -o "$dmg"
if [ "$identity" = - ]; then
    codesign --force --sign - "$dmg"
else
    codesign --force --sign "$identity" --timestamp "$dmg"
fi
codesign --verify "$dmg"
if [ -n "$profile" ]; then
    say "notarizing with keychain profile $profile"
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
    xcrun stapler staple "$dmg"
else
    say "not notarized (no --notarize-profile)"
fi
say "ok: $dmg $(stat -f %z "$dmg") bytes ($(du -h "$dmg" | cut -f1)) in $(( $(date +%s) - start )) s"
