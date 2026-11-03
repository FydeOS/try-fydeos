#!/usr/bin/env python3
"""Build the Try FydeOS QEMU runtime from Try Omarchy's pinned recipe."""

import argparse
import bz2
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "runtime/lock.json"
CACHE = ROOT / ".cache/runtime"
ARCHIVES = CACHE / "archives"
OUT = ROOT / "out/runtime"
OVERLAY_DIR = ROOT / "runtime/overlay"
OVERLAY = OVERLAY_DIR / "qemu-cocoa-product-identity.patch"
ENTITLEMENTS = ROOT / "runtime/entitlements/qemu.entitlements"
FIRMWARE = ROOT / "firmware"
QEMU_ARCHIVE_PREFIX = "qemu-"

BUILD_SCRIPT = "macos/build-qemu-gpu-runtime.sh"
PREPARE_SCRIPT = "macos/prepare-qemu-gpu-runtime.sh"
BOTTLES_SCRIPT = "macos/pinned-runtime-bottles.sh"
IDENTITY_PATCH = "macos/patches/qemu-cocoa-product-identity.patch"
OVERLAY_STAGE = "macos/patches/try-fydeos"
LAST_QEMU_PATCH = 'patch -d "$source_dir" -p1 -f -i "$minimum_guest_size_patch"'
SPICE_PROTOCOL = {
    "name": "spice-protocol-0.14.5.tar.xz",
    "url": "https://www.spice-space.org/download/releases/spice-protocol-0.14.5.tar.xz",
    "sha256": "baf58449f6e89d19f475899ad5fb9196fdc46c03cc53233f4e39cf2978f9cff7",
}
RECIPE_FILES = [
    BUILD_SCRIPT, PREPARE_SCRIPT, BOTTLES_SCRIPT,
    "macos/bundle-macho-dependencies.sh", "macos/verify-macos-compatibility.sh",
    "macos/runtime-files.txt", "macos/qemu-hvf.entitlements",
    "LICENSE", "THIRD_PARTY_NOTICES.md",
]
RECIPE_DIRS = ["macos/patches", "macos/Tests/virgl"]
JOBS_ENV = "OMARCHY_RUNTIME_BUILD_JOBS"
REQUIRED_DEVICES = [
    "virtio-gpu-gl-pci", "virtio-keyboard-pci", "virtio-tablet-pci", "virtio-net-pci",
    "virtio-blk-pci", "intel-hda", "hda-output", "hda-micro", "virtio-rng-pci",
    "virtio-serial-pci", "virtserialport",
]
TOOLS = ["awk", "bash", "chmod", "codesign", "curl", "ditto", "file", "find", "grep",
         "install", "install_name_tool", "mkdir", "mktemp", "otool", "patch", "pkg-config",
         "rm", "sed", "shasum", "sw_vers", "tar", "uname", "xattr", "xcrun"]
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
PATCH_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.patch$")


class Error(Exception):
    pass


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def load_lock(path=LOCK):
    if not path.is_file():
        raise Error(f"lock file missing: {path}")
    lock = json.loads(path.read_text())
    if lock.get("schema") != 1:
        raise Error("unsupported lock schema")
    for entry in lock["recipe"] + lock["archives"]:
        if not SHA_RE.match(entry["sha256"]):
            raise Error(f"bad sha256 in lock: {entry}")
    return lock


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def expand(value, variables):
    return re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?",
                  lambda m: variables.get(m.group(1), m.group(0)), value)


def shell_assignments(text):
    variables = {}
    for line in text.splitlines():
        match = re.match(r"^(?:readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not match or "$(" in match.group(2) or "`" in match.group(2):
            continue
        value = match.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        variables[match.group(1)] = expand(value, variables)
    return variables


def checked_archive(name, url, sha, **extra):
    if "$" in name + url or not SHA_RE.match(sha) or "/" in name:
        raise Error(f"could not resolve archive pin: {name} {url} {sha}")
    return {"name": name, "url": url, "sha256": sha, **extra}


def script_archives(text):
    variables = shell_assignments(text)
    archives = []
    for key in variables:
        if key.endswith("_archive_name"):
            prefix = key[:-len("_archive_name")]
            archives.append(checked_archive(variables[key], variables[prefix + "_url"],
                                            variables[prefix + "_sha256"]))
    return archives


def bottle_archives(text):
    variables = shell_assignments(text)
    body = re.search(r"pinned_core_bottle_manifest\(\) \{\n\s*cat <<EOF\n(.*?)\nEOF\n",
                     text, re.S)
    if not body:
        raise Error("bottle manifest not found")
    archives = []
    for line in body.group(1).splitlines():
        formula, _version, name, _root, sha = (expand(f, variables) for f in line.split("\t"))
        url = f"https://ghcr.io/v2/homebrew/core/{formula}/blobs/sha256:{sha}"
        archives.append(checked_archive(name, url, sha, ghcr_formula=formula))
    if not archives:
        raise Error("bottle manifest is empty")
    return archives


def git(upstream, *args, text=True):
    return subprocess.run(["git", "-C", str(upstream), *args], check=True,
                          capture_output=True, text=text).stdout


def make_lock(upstream, ref):
    commit = git(upstream, "rev-parse", f"{ref}^{{commit}}").strip()
    url = git(upstream, "config", "remote.origin.url").strip().removesuffix(".git")
    entries = {}
    for line in git(upstream, "ls-tree", "-r", commit, "--", *RECIPE_FILES, *RECIPE_DIRS).splitlines():
        meta, path = line.split("\t", 1)
        mode, kind, blob = meta.split()
        if kind != "blob" or mode not in ("100644", "100755"):
            raise Error(f"unexpected recipe entry: {line}")
        entries[path] = {"path": path, "mode": mode,
                         "sha256": sha256_bytes(git(upstream, "cat-file", "blob", blob, text=False))}
    missing = [p for p in RECIPE_FILES if p not in entries]
    if missing:
        raise Error(f"recipe files missing at {commit}: {missing}")

    def show(path):
        return git(upstream, "show", f"{commit}:{path}")

    build, prepare = show(BUILD_SCRIPT), show(PREPARE_SCRIPT)
    for script in (build, prepare):
        for ref_path in re.findall(r"\$native_dir/([A-Za-z0-9_./-]+)", script):
            if ref_path != ".build" and f"macos/{ref_path}" not in entries:
                raise Error(f"recipe script reads unlocked file: macos/{ref_path}")
    archives = script_archives(build) + bottle_archives(show(BOTTLES_SCRIPT)) + [SPICE_PROTOCOL]
    by_name = {a["name"]: a for a in archives}
    if len(by_name) != len(archives):
        raise Error("duplicate archive names")
    for entry in script_archives(prepare):
        if by_name.get(entry["name"]) != entry:
            raise Error(f"prepare script pin disagrees with build script: {entry['name']}")
    if not url.startswith("https://github.com/"):
        raise Error(f"unsupported upstream remote: {url}")
    return {
        "schema": 1,
        "upstream": {"repository": url, "tag": ref, "commit": commit,
                     "tarball_url": url.replace("https://github.com/", "https://codeload.github.com/")
                     + f"/tar.gz/{commit}"},
        "recipe": sorted(entries.values(), key=lambda e: e["path"]),
        "archives": archives,
    }


def cmd_lock(args):
    lock = make_lock(Path(args.upstream), args.ref)
    write_json(Path(args.output), lock)
    print(f"wrote {args.output}: {len(lock['recipe'])} recipe files, "
          f"{len(lock['archives'])} archives, {lock['upstream']['commit']}")


def http_get(url, dest, headers=None):
    request = urllib.request.Request(url)
    for key, value in (headers or {}).items():
        request.add_unredirected_header(key, value)
    with urllib.request.urlopen(request, timeout=60) as response, open(dest, "wb") as out:
        shutil.copyfileobj(response, out)


def download_archive(entry, dest):
    headers = {}
    if "ghcr_formula" in entry:
        query = urllib.parse.urlencode({"service": "ghcr.io",
                                        "scope": f"repository:homebrew/core/{entry['ghcr_formula']}:pull"})
        with urllib.request.urlopen(f"https://ghcr.io/token?{query}", timeout=60) as response:
            headers["Authorization"] = "Bearer " + json.load(response)["token"]
    http_get(entry["url"], dest, headers)


def place_archive(entry, archive_dir, seed=None, offline=False):
    dest = archive_dir / entry["name"]
    if dest.exists():
        actual = sha256_file(dest)
        if actual != entry["sha256"]:
            raise Error(f"cached {entry['name']} is corrupt: {actual} != {entry['sha256']}; remove it")
        return "cached"
    archive_dir.mkdir(parents=True, exist_ok=True)
    tmp = archive_dir / f".{entry['name']}.part"
    source = Path(seed) / entry["name"] if seed else None
    if source and source.is_file() and not source.is_symlink():
        actual = sha256_file(source)
        if actual != entry["sha256"]:
            raise Error(f"seed {source} has sha256 {actual}, lock wants {entry['sha256']}")
        shutil.copyfile(source, tmp)
        how = "seeded"
    elif offline:
        raise Error(f"offline and {entry['name']} is not cached")
    else:
        download_archive(entry, tmp)
        how = "downloaded"
    actual = sha256_file(tmp)
    if actual != entry["sha256"]:
        tmp.unlink()
        raise Error(f"{entry['name']}: sha256 {actual} != {entry['sha256']}")
    os.replace(tmp, dest)
    return how


def recipe_dir(lock):
    return CACHE / "recipe" / lock["upstream"]["commit"]


def verify_tree(directory, entries):
    for entry in entries:
        path = Path(directory) / entry["path"]
        if not path.is_file() or path.is_symlink():
            raise Error(f"recipe file missing: {entry['path']}")
        actual = sha256_file(path)
        if actual != entry["sha256"]:
            raise Error(f"recipe file {entry['path']}: sha256 {actual} != {entry['sha256']}")


def extract_recipe(tarball, lock, dest):
    wanted = {e["path"]: e for e in lock["recipe"]}
    with tarfile.open(tarball, "r:gz") as archive:
        members = {}
        for member in archive.getmembers():
            parts = member.name.split("/", 1)
            if len(parts) == 2 and parts[1] in wanted:
                members[parts[1]] = member
        for path, entry in wanted.items():
            member = members.get(path)
            if member is None or not member.isfile():
                raise Error(f"upstream tarball lacks regular file {path}")
            data = archive.extractfile(member).read()
            if sha256_bytes(data) != entry["sha256"]:
                raise Error(f"upstream {path} does not match the lock; refusing")
            target = dest / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o755 if entry["mode"] == "100755" else 0o644)


def fetch_recipe(lock, offline=False):
    dest = recipe_dir(lock)
    if dest.is_dir():
        verify_tree(dest, lock["recipe"])
        return "cached"
    if offline:
        raise Error("offline and the upstream recipe is not cached")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
        tarball = Path(tmp) / "upstream.tar.gz"
        http_get(lock["upstream"]["tarball_url"], tarball)
        staged = Path(tmp) / "recipe"
        extract_recipe(tarball, lock, staged)
        verify_tree(staged, lock["recipe"])
        os.replace(staged, dest)
    return "downloaded"


def fetch(seed=None, offline=False):
    lock = load_lock()
    for entry in lock["archives"]:
        print(f"{place_archive(entry, ARCHIVES, seed, offline):10} {entry['name']}", flush=True)
    print(f"{fetch_recipe(lock, offline):10} recipe {lock['upstream']['commit']}")
    return lock


def cmd_fetch(args):
    fetch(args.seed, args.offline)


def substitute_once(text, anchor, replacement):
    count = text.count(anchor)
    if count != 1:
        raise Error(f"overlay anchor found {count} times, expected exactly once: {anchor.strip()}")
    return text.replace(anchor, replacement)


def extra_overlay_patches(directory=OVERLAY_DIR):
    patches = sorted(p for p in Path(directory).glob("*.patch") if p.name != OVERLAY.name)
    for path in patches:
        if not PATCH_NAME_RE.match(path.name) or path.is_symlink() or not path.is_file():
            raise Error(f"unsupported overlay patch: {path}")
    return patches


def insert_overlay_patches(text, patches):
    """Apply (name, sha256) overlay patches after upstream's last QEMU patch."""
    lines = [LAST_QEMU_PATCH]
    for name, sha in patches:
        staged = f'"$native_dir/{OVERLAY_STAGE.removeprefix("macos/")}/{name}"'
        lines += [f'verify_file_sha "Try FydeOS overlay {name}" \\', f'  {staged} "{sha}"',
                  f'patch -d "$source_dir" -p1 -f -i {staged}']
    return substitute_once(text, LAST_QEMU_PATCH, "\n".join(lines))


def insert_spice_protocol(text):
    """Build QEMU's qemu-vdagent chardev against private spice-protocol headers."""
    name = SPICE_PROTOCOL["name"]
    root = name.removesuffix(".tar.xz")
    version = root.removeprefix("spice-protocol-")
    extract = 'tar -xzf "$qemu_archive" -C "$source_parent"\n'
    text = substitute_once(text, extract, extract + "\n".join([
        f'obtain_and_verify "spice-protocol {version}" "{SPICE_PROTOCOL["url"]}" \\',
        f'  "{SPICE_PROTOCOL["sha256"]}" "$archive_dir/{name}"',
        f'tar -xf "$archive_dir/{name}" -C "$source_parent"',
        f'spice_protocol_source="$source_parent/{root}"',
        'spice_protocol_root="$dependency_root/spice-protocol"', ""]))
    text = substitute_once(text, ':$libusb_root/lib/pkgconfig"\n',
                           ':$libusb_root/lib/pkgconfig:$spice_protocol_root/share/pkgconfig"\n')
    require = "\nrequire_private_pkg_version libusb-1.0 1.0.30\n"
    text = substitute_once(text, require, require + "\n".join([
        'meson="$tool_root/$meson_root/meson.py"',
        f'log "Installing spice-protocol {version} headers"',
        'env PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pkg_config_libdir" \\',
        '  PATH="$(dirname "$ninja"):$PATH" \\',
        '  python3 "$meson" setup "$spice_protocol_source/build" "$spice_protocol_source" \\',
        '    --prefix="$spice_protocol_root" --libdir=lib --wrap-mode=nodownload',
        '"$ninja" -C "$spice_protocol_source/build"',
        'python3 "$meson" install -C "$spice_protocol_source/build" --no-rebuild',
        f"require_private_pkg_version spice-protocol {version}", ""]))
    usb = "      --enable-libusb \\\n"
    return substitute_once(text, usb, usb + "      --enable-spice-protocol \\\n")


def apply_overlay(recipe, lock):
    upstream_sha = next(e["sha256"] for e in lock["recipe"] if e["path"] == IDENTITY_PATCH)
    overlay_sha = sha256_file(OVERLAY)
    script = recipe / BUILD_SCRIPT
    before = script.read_text()
    after = substitute_once(before, f"\nidentity_patch_sha256={upstream_sha}\n",
                            f"\nidentity_patch_sha256={overlay_sha}\n")
    shutil.copyfile(OVERLAY, recipe / IDENTITY_PATCH)
    staged = []
    (recipe / OVERLAY_STAGE).mkdir()
    for path in extra_overlay_patches():
        data = path.read_bytes()
        (recipe / OVERLAY_STAGE / path.name).write_bytes(data)
        staged.append((path.name, sha256_bytes(data)))
    after = insert_spice_protocol(insert_overlay_patches(after, staged))
    script.write_text(after)
    patches = {str(OVERLAY.relative_to(ROOT)): overlay_sha}
    patches.update({str((OVERLAY_DIR / name).relative_to(ROOT)): sha for name, sha in staged})
    return {"identity_patch": {"path": str(OVERLAY.relative_to(ROOT)), "sha256": overlay_sha,
                               "replaces_sha256": upstream_sha},
            "patches": patches,
            "applied_after_upstream": [f"{OVERLAY_STAGE}/{name}" for name, _ in staged],
            "build_script": {"before_sha256": sha256_bytes(before.encode()),
                             "after_sha256": sha256_bytes(after.encode())}}


def clean_env(jobs):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("DYLD_", "PKG_CONFIG_", "OMARCHY_"))
           and k not in ("CFLAGS", "CXXFLAGS", "OBJCFLAGS", "CPPFLAGS", "LDFLAGS", "PYTHONPATH")}
    env["PATH"] = f"{Path(sys.executable).parent}:{env.get('PATH', '/usr/bin:/bin')}"
    env["PYTHONNOUSERSITE"] = "1"
    env[JOBS_ENV] = str(jobs)
    return env


def run(args, log, env=None):
    log.write(f"\n$ {' '.join(map(str, args))}\n")
    log.flush()
    subprocess.run([str(a) for a in args], stdout=log, stderr=subprocess.STDOUT, env=env, check=True)


def output(args, env=None):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, env=env,
                          timeout=60).stdout


def help_tokens(text):
    return {line.split()[0] for line in text.splitlines() if line.strip()}


def probe(qemu):
    devices = output([qemu, "-device", "help"])
    result = {
        "version": output([qemu, "--version"]).splitlines()[0],
        "devices": {d: f'name "{d}"' in devices for d in REQUIRED_DEVICES},
        "accel_hvf": "hvf" in help_tokens(output([qemu, "-accel", "help"])),
        "display_cocoa": "cocoa" in help_tokens(output([qemu, "-display", "help"])),
        "audiodev_sdl": "sdl" in help_tokens(
            output([qemu, "-machine", "none", "-accel", "qtest", "-audiodev", "help"])),
        "chardev_qemu_vdagent": "qemu-vdagent" in help_tokens(
            output([qemu, "-machine", "none", "-accel", "qtest", "-chardev", "help"])),
    }
    result["ok"] = (all(result["devices"].values()) and result["accel_hvf"]
                    and result["display_cocoa"] and result["audiodev_sdl"]
                    and result["chardev_qemu_vdagent"])
    return result


def hvf_smoke(qemu):
    commands = "".join(json.dumps({"execute": c, "id": i}) + "\n"
                       for i, c in enumerate(("qmp_capabilities", "query-status", "quit"), 1))
    proc = subprocess.run([str(qemu), "-accel", "hvf", "-machine", "virt,gic-version=3",
                           "-cpu", "host", "-m", "512M", "-display", "none", "-S", "-nodefaults",
                           "-qmp", "stdio"], input=commands, capture_output=True, text=True, timeout=30)
    replies = {r["id"]: r for r in map(json.loads, filter(None, proc.stdout.splitlines()))
               if "id" in r}
    status = replies.get(2, {}).get("return", {})
    ok = (proc.returncode == 0 and all("return" in replies.get(i, {}) for i in (1, 2, 3))
          and status.get("running") is False)
    return {"ok": ok, "returncode": proc.returncode, "status": status,
            "stderr": proc.stderr[-2000:]}


def host_info():
    return {
        "macos": output(["sw_vers", "-productVersion"]).strip(),
        "macos_build": output(["sw_vers", "-buildVersion"]).strip(),
        "clang": output(["xcrun", "clang", "--version"]).splitlines()[0],
        "sdk": output(["xcrun", "--show-sdk-version"]).strip(),
        "python": sys.version.split()[0],
        "pkg_config": output(["pkg-config", "--version"]).strip(),
    }


def file_hashes(directory):
    directory = Path(directory)
    return {str(p.relative_to(directory)): sha256_file(p)
            for p in sorted(directory.rglob("*")) if p.is_file()}


def require_mac():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise Error("this command requires an Apple Silicon Mac")


def cmd_build(args):
    require_mac()
    lock = load_lock() if args.offline else fetch(offline=False)
    for entry in lock["archives"]:
        place_archive(entry, ARCHIVES, offline=True)
    verify_tree(recipe_dir(lock), lock["recipe"])

    started = time.time()
    build_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    result = OUT / build_id
    result.mkdir(parents=True)
    recipe = result / "recipe"
    shutil.copytree(recipe_dir(lock), recipe)
    overlay = apply_overlay(recipe, lock)
    overlay["entitlements_sha256"] = sha256_file(ENTITLEMENTS)
    print(f"build {build_id}: log {result / 'build.log'}", flush=True)

    with open(result / "build.log", "w") as log:
        run(["/bin/bash", recipe / BUILD_SCRIPT, "--archive-dir", ARCHIVES.resolve()], log,
            clean_env(args.jobs))
        built = recipe / "macos/.build/qemu-gpu-runtime"
        expected = (recipe / "macos/runtime-files.txt").read_text().split()
        if sorted(file_hashes(built)) != sorted(expected):
            raise Error("upstream runtime does not match runtime-files.txt")
        runtime = result / "runtime"
        for rel in expected:
            (runtime / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(built / rel, runtime / rel)
        qemu = runtime / "bin/qemu-system-aarch64"
        run(["codesign", "--force", "--sign", "-", "--entitlements", ENTITLEMENTS, qemu], log)
        for rel in expected:
            run(["codesign", "--verify", "--strict", runtime / rel], log)
        run(["/bin/bash", recipe / "macos/bundle-macho-dependencies.sh", "--verify-only",
             runtime.resolve()], log)
        run(["/bin/bash", recipe / "macos/verify-macos-compatibility.sh", runtime.resolve()], log)
        entitlements = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(qemu)],
                                      capture_output=True, text=True).stdout
        if "com.apple.security.hypervisor" not in entitlements:
            raise Error("re-signed QEMU lacks the hypervisor entitlement")

    probes = probe(qemu)
    smoke = hvf_smoke(qemu)
    print(json.dumps({"probe": probes, "hvf_smoke": smoke}, indent=2), flush=True)
    if not probes["ok"] or not smoke["ok"]:
        raise Error(f"runtime checks failed; see {result}")
    write_json(result / "provenance.json", {
        "schema": 1,
        "build_id": build_id,
        "duration_seconds": round(time.time() - started),
        "jobs": args.jobs,
        "lock": {"sha256": sha256_file(LOCK), "upstream": lock["upstream"],
                 "recipe": {e["path"]: e["sha256"] for e in lock["recipe"]},
                 "archives": {e["name"]: e["sha256"] for e in lock["archives"]}},
        "overlay": overlay,
        "host": host_info(),
        "runtime_files": file_hashes(runtime),
        "qemu_sha256": sha256_file(qemu),
        "probe": probes,
        "hvf_smoke": smoke,
    })
    link = OUT / "current"
    tmp = OUT / ".current.tmp"
    if tmp.is_symlink():
        tmp.unlink()
    tmp.symlink_to(build_id)
    os.replace(tmp, link)
    print(f"runtime ready: {link} -> {build_id}")


def read_sums(path):
    sums = {}
    for line in path.read_text().splitlines():
        digest, name = line.split()
        sums[name] = digest
    return sums


def cmd_firmware(args):
    lock = load_lock()
    entry = next(a for a in lock["archives"] if a["name"].startswith(QEMU_ARCHIVE_PREFIX))
    place_archive(entry, ARCHIVES, offline=True)
    root = entry["name"].removesuffix(".tar.gz")
    sums = read_sums(FIRMWARE / "SHA256SUMS")
    with tarfile.open(ARCHIVES / entry["name"], "r:gz") as archive:
        for name, digest in sums.items():
            data = bz2.decompress(archive.extractfile(f"{root}/pc-bios/{name}.bz2").read())
            if sha256_bytes(data) != digest:
                raise Error(f"{name}: sha256 {sha256_bytes(data)} != {digest}")
            tmp = FIRMWARE / f".{name}.tmp"
            tmp.write_bytes(data)
            os.replace(tmp, FIRMWARE / name)
            print(f"ok {FIRMWARE / name} {digest}")


def cmd_doctor(args):
    failures = []

    def report(state, what):
        print(f"{state:8} {what}")
        if state == "FAIL":
            failures.append(what)

    mac = platform.system() == "Darwin" and platform.machine() == "arm64"
    version = platform.mac_ver()[0]
    major = int(version.split(".")[0]) if version else 0
    report("ok" if mac and major >= 15 else "FAIL", f"Apple Silicon macOS >= 15 (macOS {version or '-'})")
    report("ok" if sys.version_info >= (3, 12) else "FAIL", f"python {sys.version.split()[0]}")
    missing = [t for t in TOOLS if not shutil.which(t)]
    report("FAIL" if missing else "ok", f"tools {'missing: ' + ' '.join(missing) if missing else 'present'}")
    if mac and not missing:
        sdk = output(["xcrun", "--show-sdk-version"]).strip()
        report("ok" if sdk else "FAIL", f"SDK {sdk or 'not found'}")
    try:
        lock = load_lock()
    except Error as error:
        report("FAIL", str(error))
        return 1
    report("ok", f"lock {lock['upstream']['tag']} {lock['upstream']['commit']}")
    present = bad = 0
    for entry in lock["archives"]:
        path = ARCHIVES / entry["name"]
        if path.is_file():
            present += 1
            if sha256_file(path) != entry["sha256"]:
                bad += 1
                report("FAIL", f"archive corrupt: {entry['name']}")
    report("ok" if present == len(lock["archives"]) and not bad else "missing" if not bad else "FAIL",
           f"archives {present}/{len(lock['archives'])} cached")
    try:
        verify_tree(recipe_dir(lock), lock["recipe"])
        report("ok", "recipe cached and verified")
    except Error as error:
        report("FAIL" if recipe_dir(lock).is_dir() else "missing", f"recipe: {error}")
    for name, digest in read_sums(FIRMWARE / "SHA256SUMS").items():
        path = FIRMWARE / name
        if not path.is_file():
            report("missing", f"firmware {name}")
        else:
            report("ok" if sha256_file(path) == digest else "FAIL", f"firmware {name}")
    qemu = OUT / "current/runtime/bin/qemu-system-aarch64"
    if qemu.is_file() and mac:
        result = probe(qemu)
        report("ok" if result["ok"] else "FAIL", f"runtime {os.readlink(OUT / 'current')}: {result['version']}")
        print(json.dumps(result, indent=2))
    else:
        report("missing", "runtime (out/runtime/current)")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("lock", help="generate lock.json from an upstream git checkout")
    p.add_argument("--upstream", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--output", default=str(LOCK))
    p.set_defaults(func=cmd_lock)
    p = sub.add_parser("fetch", help="populate the verified archive and recipe cache")
    p.add_argument("--seed", help="directory of archives to copy after hash verification")
    p.add_argument("--offline", action="store_true")
    p.set_defaults(func=cmd_fetch)
    p = sub.add_parser("build", help="build, sign and probe the runtime")
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--offline", action="store_true")
    p.set_defaults(func=cmd_build)
    sub.add_parser("doctor", help="check host, pins, cache and runtime").set_defaults(func=cmd_doctor)
    sub.add_parser("firmware", help="extract the pinned edk2 pair").set_defaults(func=cmd_firmware)
    args = parser.parse_args()
    try:
        return args.func(args) or 0
    except (Error, subprocess.CalledProcessError) as error:
        print(f"runtime: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
