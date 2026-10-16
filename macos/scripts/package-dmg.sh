#!/bin/bash
# Build dist/Try FydeOS-<version>.dmg: the app, FydeOS/<image>, an Applications link and README.txt.
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
spec="$repo/factory/spec.json"
store="${TRY_FYDEOS_FACTORY_DIR:-$HOME/Library/Application Support/Try FydeOS/factory}"

say() { echo "package-dmg: $*"; }
die() { echo "package-dmg: $*" >&2; exit 1; }

start=$(date +%s)
[ -d "$app" ] || die "no $app (make app)"
file=$(plutil -extract image.file raw -o - "$spec")
bytes=$(plutil -extract image.bytes raw -o - "$spec")
sha=$(plutil -extract image.sha256 raw -o - "$spec")
[ ! -e "$app/Contents/Resources/factory/$file" ] || die "$app was built with --with-image; rebuild with make app"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
codesign --verify --strict "$app" || die "$app does not verify"

src=
for candidate in "$repo/factory/$file" "$store/$file"; do
    [ -f "$candidate" ] && { src=$candidate; break; }
done
[ -n "$src" ] || die "$file not found in $repo/factory or $store"
[ "$(stat -f %z "$src")" = "$bytes" ] || die "$src is $(stat -f %z "$src") bytes, spec says $bytes"
say "checking sha256 of $src"
[ "$(openssl dgst -sha256 -r "$src" | cut -d' ' -f1)" = "$sha" ] || die "$src does not match the spec's sha256"

rm -rf "$stage"
mkdir -p "$stage/FydeOS"
ditto "$app" "$stage/Try FydeOS.app"
cp -c "$src" "$stage/FydeOS/$file" 2>/dev/null || cp "$src" "$stage/FydeOS/$file"
ln -s /Applications "$stage/Applications"
cat > "$stage/README.txt" <<'EOF'
Drag Try FydeOS to Applications.
Keep the FydeOS folder next to the app, or move it there; otherwise the app asks for the image and imports it.
The first launch copies the ~7 GB FydeOS image into ~/Library/Application Support/Try FydeOS.
EOF
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
