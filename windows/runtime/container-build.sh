#!/bin/bash
# Runs inside the build container without network (see build.sh): /repo is the
# try-fydeos tree (read-only), /cache the verified downloads (read-only), /work
# the scratch tree. Builds SDL2, libepoxy, libslirp, virglrenderer and QEMU with the
# mingw64 cross toolchain, installs the spice-protocol headers and assembles
# /work/runtime.
set -euo pipefail
trap 'echo "container-build.sh: failed at line $LINENO" >&2' ERR

lock=/repo/windows/runtime/lock.json
src=/work/src
deps=/work/deps
stage=/work/stage
runtime=/work/runtime
logs=/work/logs
jobs=${JOBS:-$(nproc)}
j() { jq -r "$1" "$lock"; }

export SOURCE_DATE_EPOCH=$(j .sourceDateEpoch) TZ=UTC LC_ALL=C.UTF-8
# Fedora's mingw pkg-config prefixes the sysroot to every path outside it;
# its own .pc files carry absolute sysroot paths already.
export PKG_CONFIG_PATH=$deps/lib/pkgconfig:$deps/share/pkgconfig PKG_CONFIG_SYSROOT_DIR=

rm -rf "$src" /work/build "$deps" "$stage" "$runtime" "$logs"
mkdir -p "$src" "$deps" "$stage" "$runtime" "$logs"

unpack() {
	mkdir -p "$src/$2"
	tar -xf "/cache/$(j "$1 | .file // (.url | split(\"/\") | last)")" -C "$src/$2" --strip-components=1
}
unpack .recipe recipe
unpack .libslirp libslirp
unpack .spiceProtocol spice-protocol
unpack .sdl2 sdl2
unpack .libepoxy libepoxy
for name in qemu virglrenderer; do
	mkdir -p "$src/$name"
	tar -C "/cache/$name" --exclude=./.git -cf - . | tar -C "$src/$name" -xf -
done

apply_patches() {
	local name=$1 list=$2 base=$3 file sha
	while read -r file sha; do
		echo "$sha  $base/$file" | sha256sum -c --quiet
		git -C "$src/$name" apply "$base/$file"
		echo "applied $file to $name"
	done < <(jq -r ".$name.$list[] | \"\(.file) \(.sha256)\"" "$lock")
}
apply_patches qemu patches "$src/recipe"
apply_patches virglrenderer patches "$src/recipe"
cp /repo/windows/cmd/TryFydeOSApp/TryFydeOS.ico "$src/qemu/pc-bios/tryfydeos.ico"
apply_patches qemu overlay /repo/windows/runtime
apply_patches virglrenderer overlay /repo/windows/runtime
while read -r file sha; do
	echo "$sha  /cache/$file" | sha256sum -c --quiet
	git -C "$src/libepoxy" apply "/cache/$file"
	echo "applied $file to libepoxy"
done < <(jq -r '.libepoxy.patches[] | "\(.file) \(.sha256)"' "$lock")

echo "== SDL2"
cmake -S "$src/sdl2" -B /work/build/sdl2 -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$deps" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF \
	>"$logs/sdl2-configure.log"
ninja -C /work/build/sdl2 -j"$jobs" install >"$logs/sdl2-build.log"

echo "== libepoxy"
meson setup /work/build/libepoxy "$src/libepoxy" --cross-file "$MESON_CROSS" \
	--prefix="$deps" --libdir=lib --buildtype=release \
	-Degl=yes -Dglx=no -Dx11=false -Dtests=false \
	>"$logs/libepoxy-configure.log"
ninja -C /work/build/libepoxy -j"$jobs" install >"$logs/libepoxy-build.log"

echo "== libslirp"
meson setup /work/build/libslirp "$src/libslirp" --cross-file "$MESON_CROSS" \
	--prefix="$deps" --libdir=lib --buildtype=release -Ddefault_library=shared \
	>"$logs/libslirp-configure.log"
ninja -C /work/build/libslirp -j"$jobs" install >"$logs/libslirp-build.log"

echo "== virglrenderer"
meson setup /work/build/virglrenderer "$src/virglrenderer" --cross-file "$MESON_CROSS" \
	--prefix="$deps" --libdir=lib --buildtype=release \
	-Dvenus=false -Dvideo=false -Dtests=false \
	>"$logs/virglrenderer-configure.log"
ninja -C /work/build/virglrenderer -j"$jobs" install >"$logs/virglrenderer-build.log"

echo "== spice-protocol"
meson setup /work/build/spice-protocol "$src/spice-protocol" --prefix="$deps" \
	>"$logs/spice-protocol-configure.log"
meson install -C /work/build/spice-protocol >"$logs/spice-protocol-install.log"

echo "== QEMU"
# bindir and datadir make QEMU's relocation look for firmware in <exe dir>\share.
mkdir -p /work/build/qemu
(
	cd /work/build/qemu
	"$src/qemu/configure" --cross-prefix=x86_64-w64-mingw32- --disable-download \
		--prefix=/try-fydeos --bindir=bin --datadir=bin/share --with-suffix= \
		--target-list=x86_64-softmmu --enable-whpx --enable-sdl --enable-opengl \
		--enable-virglrenderer --enable-slirp --enable-spice-protocol --disable-gtk \
		--disable-libusb --disable-sdl-image --disable-docs --disable-plugins --disable-rust
) >"$logs/qemu-configure.log"
ninja -C /work/build/qemu -j"$jobs" >"$logs/qemu-build.log"
DESTDIR="$stage" ninja -C /work/build/qemu install >"$logs/qemu-install.log"

echo "== runtime"
mkdir -p "$runtime/bin/share" "$runtime/LICENSES" "$runtime/provenance"
cp "$stage/try-fydeos/bin/qemu-system-x86_64w.exe" "$runtime/bin/"

# The DLLs the exe imports, recursively, from the built dependencies or the
# Fedora sysroot; anything else is a Windows system DLL.
declare -A seen
: >"$runtime/provenance/dll-sources.txt"
walk() {
	local dll path
	for dll in $(x86_64-w64-mingw32-objdump -p "$1" | sed -n 's/^\tDLL Name: //p'); do
		[[ -z ${seen[$dll]:-} ]] || continue
		seen[$dll]=1
		for path in "$deps/bin/$dll" "$SYSROOT/bin/$dll"; do
			if [[ -f $path ]]; then
				cp "$path" "$runtime/bin/"
				echo "$dll $path" >>"$runtime/provenance/dll-sources.txt"
				walk "$path"
				break
			fi
		done
	done
}
walk "$runtime/bin/qemu-system-x86_64w.exe"
sort -o "$runtime/provenance/dll-sources.txt" "$runtime/provenance/dll-sources.txt"

# x86 firmware and the keymaps only.
(
	cd "$stage/try-fydeos/bin/share"
	cp -r keymaps bios.bin bios-256k.bin bios-microvm.bin kvmvapic.bin linuxboot*.bin \
		multiboot*.bin pvh.bin qboot.rom vgabios*.bin efi-*.rom pxe-*.rom \
		edk2-i386-*.fd edk2-x86_64-*.fd edk2-licenses.txt "$runtime/bin/share/"
	mkdir -p "$runtime/bin/share/firmware"
	cp firmware/*-i386-* firmware/*-x86_64* "$runtime/bin/share/firmware/"
)

licenses=$runtime/LICENSES
mkdir -p "$licenses/qemu" "$licenses/virglrenderer" "$licenses/libslirp" "$licenses/spice-protocol" "$licenses/SDL2" "$licenses/libepoxy" "$licenses/fedora"
cp "$src/qemu/COPYING" "$src/qemu/COPYING.LIB" "$src/qemu/LICENSE" "$licenses/qemu/"
cp "$src/virglrenderer/COPYING" "$licenses/virglrenderer/"
cp "$src/libslirp/COPYRIGHT" "$licenses/libslirp/"
cp "$src/spice-protocol/COPYING" "$licenses/spice-protocol/"
cp "$src/sdl2/LICENSE.txt" "$licenses/SDL2/"
cp "$src/libepoxy/COPYING" "$licenses/libepoxy/"
: >"$runtime/provenance/fedora-packages.txt"
while read -r dll path; do
	[[ $path == "$SYSROOT"/* ]] || continue
	rpm -qf "$path" >>"$runtime/provenance/fedora-packages.txt"
done <"$runtime/provenance/dll-sources.txt"
sort -u -o "$runtime/provenance/fedora-packages.txt" "$runtime/provenance/fedora-packages.txt"
if ! diff -u <(jq -r '.image.packages[]' "$lock" | sort) "$runtime/provenance/fedora-packages.txt"; then
	echo "the shipped Fedora packages differ from lock.json image.packages" >&2
	exit 1
fi
while read -r pkg; do
	name=$(rpm -q --qf '%{NAME}' "$pkg")
	mkdir -p "$licenses/fedora/$name"
	rpm -q --qf '%{NVR}\nLicense: %{LICENSE}\nURL: %{URL}\n' "$pkg" >"$licenses/fedora/$name/PACKAGE.txt"
	files=$(rpm -qL "$pkg")
	# win-iconv states its license in the README; zlib ships no text at all,
	# PACKAGE.txt names it.
	[[ -n $files ]] || files=$(rpm -qd "$pkg" | grep -i -E '/(readme|copying|license)[^/]*$' || true)
	[[ -n $files ]] || echo "note: $pkg ships no license text, PACKAGE.txt names its license"
	for f in $files; do cp "$f" "$licenses/fedora/$name/"; done
done <"$runtime/provenance/fedora-packages.txt"

cp "$lock" "$runtime/provenance/lock.json"
mkdir -p "$runtime/provenance/patches/qemu" "$runtime/provenance/patches/virglrenderer"
mkdir -p "$runtime/provenance/patches/libepoxy"
jq -r '.libepoxy.patches[].file' "$lock" | while read -r f; do cp "/cache/$f" "$runtime/provenance/patches/libepoxy/"; done
for name in qemu virglrenderer; do
	jq -r ".$name.patches[].file" "$lock" | while read -r f; do cp "$src/recipe/$f" "$runtime/provenance/patches/$name/"; done
	jq -r ".$name.overlay[].file" "$lock" | while read -r f; do cp "/repo/windows/runtime/$f" "$runtime/provenance/patches/$name/"; done
done
rpm -qa | sort >/work/build-packages.txt
cp /work/sources.txt "$runtime/provenance/sources.txt"
sed -n '/^  Targets and accelerators/,$p' "$logs/qemu-configure.log" >"$runtime/provenance/qemu-configure-summary.txt"
cat >"$runtime/README.txt" <<EOF
Try FydeOS runtime for Windows, lock.json sha256 $(sha256sum "$lock" | cut -c1-12)

QEMU $(cat "$src/qemu/VERSION") (cmspam/winq-emu-qemu with Try Omarchy's WINQ-EMU
patches and Try FydeOS's overlay), virglrenderer, libslirp and SDL2,
cross-built with Fedora's mingw64 toolchain by windows/runtime/build.sh of
Try FydeOS. Exact sources, patches, packages and licenses are under
provenance\ and LICENSES\.
EOF
echo "runtime assembled: $(find "$runtime" -type f | wc -l) files"
