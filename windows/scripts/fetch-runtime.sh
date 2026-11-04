#!/bin/sh
# Unpacks the pinned Windows QEMU runtime into out/win-runtime/ after checking its hash.
#   fetch-runtime.sh [omarchy]  Try Omarchy's published zip, downloaded into out/winq/
#   fetch-runtime.sh own        our build, out/<own.name>: downloaded from own.url, else make win-runtime-build
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
lock="$root/windows/runtime.lock.json"
which=${1:-omarchy}
case $which in
omarchy) sel='.' ;;
own) sel='.own' ;;
*) echo "fetch-runtime: unknown runtime '$which' (omarchy or own)" >&2; exit 2 ;;
esac
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); v=v["own"] if sys.argv[2]==".own" else v; v=v.get(sys.argv[3], "") if sys.argv[3]=="url" else v[sys.argv[3]]; print(" ".join(v) if isinstance(v, list) else v)' "$lock" "$sel" "$1"; }
name=$(field name)
sha=$(field sha256)
keep=$(field keep)

url=$(field url)
if [ "$which" = own ]; then
	zip="$root/out/$name"
else
	zip="$root/out/winq/$name"
fi
if [ ! -f "$zip" ] || ! echo "$sha  $zip" | sha256sum -c --status; then
	[ -n "$url" ] || { echo "fetch-runtime: $zip missing or stale; build it with 'make win-runtime-build'" >&2; exit 1; }
	mkdir -p "$(dirname "$zip")"
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
echo "runtime ($which) unpacked into $out"
