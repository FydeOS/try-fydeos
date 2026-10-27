#!/bin/sh
# Fetches the pinned Windows QEMU runtime, verifies its hash and unpacks it into out/win-runtime/.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
lock="$root/windows/runtime.lock.json"
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(" ".join(v) if isinstance(v, list) else v)' "$lock" "$1"; }
name=$(field name)
url=$(field url)
sha=$(field sha256)
keep=$(field keep)

zip="$root/out/winq/$name"
if [ ! -f "$zip" ] || ! echo "$sha  $zip" | sha256sum -c --status; then
	mkdir -p "$root/out/winq"
	echo "fetching $url"
	curl -fL --retry 3 -o "$zip.part" "$url"
	mv "$zip.part" "$zip"
fi
echo "$sha  $zip" | sha256sum -c --quiet || { echo "fetch-runtime: $zip does not match the pinned sha256" >&2; exit 1; }

out="$root/out/win-runtime"
staging="$root/out/.win-runtime.unpacking"
rm -rf "$staging"
mkdir -p "$staging"
unzip -q "$zip" -d "$staging"
for k in $keep; do
	[ -e "$staging/$k" ] || { echo "fetch-runtime: $k missing from $name" >&2; exit 1; }
done
for entry in "$staging"/* "$staging"/.[!.]*; do
	[ -e "$entry" ] || continue
	case " $keep " in *" $(basename "$entry") "*) ;; *) rm -rf "$entry" ;; esac
done
rm -rf "$out"
mv "$staging" "$out"
echo "runtime unpacked into $out"
