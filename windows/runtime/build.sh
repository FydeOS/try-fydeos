#!/bin/bash
# Builds Try FydeOS's Windows QEMU runtime from windows/runtime/lock.json.
#   build.sh fetch   download and verify sources, build the Docker image (network)
#   build.sh         fetch, then build in the container without network and write
#                    out/win-runtime/ and out/win-runtime-<lock sha256 prefix>.zip (+ .sha256)
# Everything lives under out/: win-runtime-cache/ (downloads), win-runtime-build/.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
lock=$root/windows/runtime/lock.json
cache=$root/out/win-runtime-cache
work=$root/out/win-runtime-build
j() { jq -r "$1" "$lock"; }
image=try-fydeos-win-runtime:$(cat "$root/windows/runtime/Dockerfile" <(j .image.base) | sha256sum | cut -c1-12)

# $1: a jq path to an object with url, sha256 and optionally file.
fetch_tarball() {
	local url sha file
	url=$(j "$1.url") sha=$(j "$1.sha256")
	file=$cache/$(j "$1 | .file // (.url | split(\"/\") | last)")
	if ! echo "$sha  $file" | sha256sum -c --status 2>/dev/null; then
		echo "fetching $url"
		curl -fL --retry 3 -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	echo "$sha  $file" | sha256sum -c --quiet || { echo "$file does not match lock.json" >&2; exit 1; }
}

# The forks carry symlinks whose targets are file contents (committed from
# Windows); none is used by a Windows build, so check them out as plain files.
fetch_git() {
	local dir=$cache/$1 repo commit base
	repo=$(j ".$1.repository") commit=$(j ".$1.commit") base=$(j ".$1.baseCommit")
	if [[ $(git -C "$dir" rev-parse HEAD 2>/dev/null) != "$commit" ]]; then
		rm -rf "$dir"
		git init -q "$dir"
		git -C "$dir" config core.symlinks false
		git -C "$dir" remote add origin "$repo"
		git -C "$dir" fetch -q --depth=256 origin "$commit" "$base"
		git -C "$dir" checkout -q --detach "$commit"
	fi
	[[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]]
	git -C "$dir" merge-base --is-ancestor "$base" "$commit" ||
		{ echo "$1 $commit does not contain its base $base" >&2; exit 1; }
	[[ -z $(git -C "$dir" status --porcelain --untracked-files=no) ]] ||
		{ echo "$dir has local changes" >&2; exit 1; }
}

fetch() {
	mkdir -p "$cache"
	fetch_tarball .recipe
	fetch_tarball .libslirp
	fetch_tarball .spiceProtocol
	fetch_tarball .sdl2
	fetch_tarball .libepoxy
	for i in $(j '.libepoxy.patches | keys[]'); do fetch_tarball ".libepoxy.patches[$i]"; done
	fetch_git qemu
	fetch_git virglrenderer
	if ! docker image inspect "$image" >/dev/null 2>&1; then
		docker build --build-arg BASE="$(j .image.base)" -t "$image" "$root/windows/runtime"
	fi
	# QEMU's wrap files pin these by commit; meson fetches them into subprojects/.
	local missing=()
	for sp in $(j '.qemu.subprojects[]'); do
		[[ -d $cache/qemu/subprojects/$sp ]] || missing+=("$sp")
	done
	if ((${#missing[@]})); then
		docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$cache/qemu:/qemu" -w /qemu "$image" \
			meson subprojects download "${missing[@]}"
	fi
}

describe() {
	local dir=$cache/$1 commit base n
	commit=$(j ".$1.commit") base=$(j ".$1.baseCommit")
	n=$(git -C "$dir" rev-list --count "$base..$commit")
	echo "$1 $(j ".$1.repository") $commit $(j ".$1.baseTag")-$n-g${commit:0:12}"
}

fetch
[[ ${1:-} == fetch ]] && exit 0

start=$(date +%s)
mkdir -p "$work"
{
	describe qemu
	describe virglrenderer
	echo "libslirp $(j .libslirp.url) $(j .libslirp.sha256)"
	echo "spice-protocol $(j .spiceProtocol.url) $(j .spiceProtocol.sha256)"
	echo "sdl2 $(j .sdl2.url) $(j .sdl2.sha256)"
	echo "libepoxy $(j .libepoxy.url) $(j .libepoxy.sha256) + $(j .libepoxy.patchesFrom)"
	echo "recipe $(j .recipe.url) $(j .recipe.sha256)"
	echo "image $(j .image.base) ($(j .image.repos))"
} >"$work/sources.txt"
docker run --rm --network=none --user "$(id -u):$(id -g)" -e HOME=/tmp -e JOBS="${JOBS:-}" \
	-v "$root:/repo:ro" -v "$cache:/cache:ro" -v "$work:/work" "$image" \
	bash /repo/windows/runtime/container-build.sh

# The build is reproducible, so the zip is named after the lock it came from.
zip=$root/out/win-runtime-$(sha256sum "$lock" | cut -c1-12).zip
rm -f "$zip"
find "$work/runtime" -exec touch -h -d "@$(j .sourceDateEpoch)" {} +
(cd "$work/runtime" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | zip -q -X -9 "$zip" -@)
(cd "$root/out" && sha256sum "$(basename "$zip")" >"$zip.sha256")
rm -rf "$root/out/win-runtime"
cp -a "$work/runtime" "$root/out/win-runtime"
echo "built in $(($(date +%s) - start)) s: $(du -sh "$root/out/win-runtime" | cut -f1) unpacked, $(du -h "$zip" | cut -f1) zip"
cat "$zip.sha256"
