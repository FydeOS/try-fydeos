#!/bin/sh
# Renders the app icon and compiles versioninfo.rc into the .syso that go build
# links into "Try FydeOS.exe". Needs ImageMagick, llvm-rc, llvm-cvtres and an SVG
# renderer with gradient support: rsvg-convert, else headless Google Chrome
# (ImageMagick's built-in renderer draws the gradients black).
set -eu
cd "$(dirname "$0")/.."
app=cmd/TryFydeOSApp
svg=$(realpath ../macos/Resources/TryFydeOSIcon.svg)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if command -v rsvg-convert >/dev/null 2>&1; then
	rsvg-convert -w 1024 -h 1024 "$svg" -o "$work/master.png"
else
	google-chrome --headless --disable-gpu --no-sandbox --hide-scrollbars \
		--default-background-color=00000000 --window-size=1024,1024 \
		--screenshot="$work/master.png" "file://$svg" 2>/dev/null
fi
convert "$work/master.png" -background none -define icon:auto-resize=256,128,64,48,32,16 "$app/TryFydeOS.ico"
llvm-rc /FO "$work/rsrc.res" versioninfo.rc
llvm-cvtres /MACHINE:X64 /OUT:"$app/rsrc_windows_amd64.syso" "$work/rsrc.res"
echo "wrote $app/TryFydeOS.ico and $app/rsrc_windows_amd64.syso"
