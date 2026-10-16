#!/bin/bash
# Render Resources/TryFydeOSIcon.svg to an .icns with stock macOS tools
# (qlmanage, sips, iconutil); rsvg-convert is used when installed.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
svg="$here/Resources/TryFydeOSIcon.svg"
out="${1:-$here/.build/TryFydeOS.icns}"
mkdir -p "$here/.build"
work=$(mktemp -d "$here/.build/icon.XXXXXX")
trap 'rm -rf "$work"' EXIT

master="$work/master.png"
if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 1024 -h 1024 "$svg" -o "$master"
else
    qlmanage -t -s 1024 -o "$work" "$svg" >/dev/null 2>&1
    mv "$work/$(basename "$svg").png" "$master"
fi
[ "$(sips -g pixelWidth "$master" | awk '/pixelWidth/ {print $2}')" = 1024 ] || { echo "make-icon: render is not 1024 px wide" >&2; exit 1; }

set_dir="$work/TryFydeOS.iconset"
mkdir "$set_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$master" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p "$(dirname "$out")"
iconutil -c icns "$set_dir" -o "$out"
echo "$out"
