import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("runtime", ROOT / "runtime/runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)

SHA_A = "a" * 64
SHA_B = "b" * 64


def sha(data):
    return hashlib.sha256(data).hexdigest()


class LockTest(unittest.TestCase):
    def test_script_archives_expand_variables(self):
        text = (f'native_dir=$(cd "$(dirname "$0")" && pwd -P)\n'
                f'patch="$native_dir/patches/x.patch"\n'
                f'qemu_commit=abc\nqemu_root="qemu-$qemu_commit"\n'
                f'qemu_archive_name="$qemu_root.tar.gz"\n'
                f'qemu_url="https://example.org/$qemu_commit/$qemu_archive_name"\n'
                f'qemu_sha256={SHA_A}\n')
        self.assertEqual(runtime.script_archives(text), [
            {"name": "qemu-abc.tar.gz", "url": "https://example.org/abc/qemu-abc.tar.gz",
             "sha256": SHA_A}])

    def test_unresolved_pin_is_refused(self):
        text = f'x_archive_name="$missing.tar.gz"\nx_url=https://e/x\nx_sha256={SHA_A}\n'
        with self.assertRaises(runtime.Error):
            runtime.script_archives(text)

    def test_bottle_manifest(self):
        text = ("readonly PINNED_XZ_ARCHIVE=xz--5.8.3.bottle.tar.gz\n"
                "pinned_core_bottle_manifest() {\n  cat <<EOF\n"
                f"xz\t5.8.3\t$PINNED_XZ_ARCHIVE\txz/5.8.3\t{SHA_B}\nEOF\n}}\n")
        self.assertEqual(runtime.bottle_archives(text), [{
            "name": "xz--5.8.3.bottle.tar.gz", "sha256": SHA_B, "ghcr_formula": "xz",
            "url": f"https://ghcr.io/v2/homebrew/core/xz/blobs/sha256:{SHA_B}"}])

    def test_committed_lock(self):
        lock = runtime.load_lock()
        self.assertEqual(lock["upstream"]["commit"], "6166ca0759aad5c56d4c71128a0aea13dbcb67ad")
        paths = {e["path"] for e in lock["recipe"]}
        self.assertTrue(set(runtime.RECIPE_FILES) <= paths)
        self.assertIn(runtime.IDENTITY_PATCH, paths)
        self.assertEqual(len(lock["archives"]), 26)

    def test_verify_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a").write_bytes(b"good")
            runtime.verify_tree(tmp, [{"path": "a", "sha256": sha(b"good")}])
            (Path(tmp) / "a").write_bytes(b"bad")
            with self.assertRaises(runtime.Error):
                runtime.verify_tree(tmp, [{"path": "a", "sha256": sha(b"good")}])
            with self.assertRaises(runtime.Error):
                runtime.verify_tree(tmp, [{"path": "missing", "sha256": SHA_A}])


class OverlayTest(unittest.TestCase):
    def test_anchor_once(self):
        self.assertEqual(runtime.substitute_once("a\nx=1\nb", "\nx=1\n", "\nx=2\n"), "a\nx=2\nb")

    def test_anchor_missing_or_repeated(self):
        for text in ("a\nx=3\nb", "\nx=1\n\nx=1\n"):
            with self.assertRaises(runtime.Error):
                runtime.substitute_once(text, "\nx=1\n", "\nx=2\n")

    def test_overlay_only_renames_product(self):
        lines = runtime.OVERLAY.read_text().splitlines()
        self.assertFalse(any("Omarchy" in line for line in lines if not line.startswith("From:")))
        self.assertIn('+    [[NSProcessInfo processInfo] setProcessName:@"Try FydeOS"];', lines)

    def test_overlay_patches_inserted_after_last_qemu_patch(self):
        anchor = runtime.LAST_QEMU_PATCH
        text = f"a\n{anchor}\nb\n"
        out = runtime.insert_overlay_patches(text, [("x.patch", SHA_A), ("y.patch", SHA_B)])
        self.assertEqual(out.splitlines(), [
            "a", anchor,
            'verify_file_sha "Try FydeOS overlay x.patch" \\',
            f'  "$native_dir/patches/try-fydeos/x.patch" "{SHA_A}"',
            'patch -d "$source_dir" -p1 -f -i "$native_dir/patches/try-fydeos/x.patch"',
            'verify_file_sha "Try FydeOS overlay y.patch" \\',
            f'  "$native_dir/patches/try-fydeos/y.patch" "{SHA_B}"',
            'patch -d "$source_dir" -p1 -f -i "$native_dir/patches/try-fydeos/y.patch"',
            "b"])
        self.assertEqual(runtime.insert_overlay_patches(text, []), text)

    def test_overlay_patch_anchor_missing_or_repeated(self):
        anchor = runtime.LAST_QEMU_PATCH
        for text in ("a\nb\n", f"{anchor}\n{anchor}\n"):
            with self.assertRaises(runtime.Error):
                runtime.insert_overlay_patches(text, [("x.patch", SHA_A)])

    def test_staged_script_lists_overlay_patches(self):
        lock = runtime.load_lock()
        upstream_sha = next(e["sha256"] for e in lock["recipe"]
                            if e["path"] == runtime.IDENTITY_PATCH)
        script = (f"identity_patch_sha256={upstream_sha}\n"
                  f"{runtime.LAST_QEMU_PATCH}\n")
        with tempfile.TemporaryDirectory() as tmp:
            recipe = Path(tmp)
            (recipe / runtime.BUILD_SCRIPT).parent.mkdir(parents=True)
            (recipe / runtime.IDENTITY_PATCH).parent.mkdir(parents=True)
            (recipe / runtime.BUILD_SCRIPT).write_text("\n" + script)
            result = runtime.apply_overlay(recipe, lock)
            staged = (recipe / runtime.BUILD_SCRIPT).read_text()
            extras = runtime.extra_overlay_patches()
            self.assertIn(runtime.OVERLAY_DIR / "qemu-cocoa-window-master.patch", extras)
            self.assertEqual(sorted(extras), extras)
            applied = [line.split()[-1].strip('"') for line in staged.splitlines()
                       if line.startswith("patch -d")]
            self.assertEqual(applied, ["$minimum_guest_size_patch"] + [
                f"$native_dir/patches/try-fydeos/{p.name}" for p in extras])
            for path in extras:
                digest = runtime.sha256_file(path)
                self.assertIn(f'try-fydeos/{path.name}" "{digest}"', staged)
                self.assertEqual(
                    runtime.sha256_file(recipe / runtime.OVERLAY_STAGE / path.name), digest)
                self.assertEqual(result["patches"][f"runtime/overlay/{path.name}"], digest)
            self.assertEqual(result["patches"]["runtime/overlay/qemu-cocoa-product-identity.patch"],
                             runtime.sha256_file(runtime.OVERLAY))


class SeedTest(unittest.TestCase):
    def test_seed_mismatch_refused_and_match_copied(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed, cache = Path(tmp) / "seed", Path(tmp) / "cache"
            seed.mkdir()
            (seed / "x.tar.gz").write_bytes(b"tampered")
            entry = {"name": "x.tar.gz", "url": "https://invalid/", "sha256": sha(b"real")}
            with self.assertRaises(runtime.Error):
                runtime.place_archive(entry, cache, seed, offline=True)
            self.assertFalse((cache / "x.tar.gz").exists())
            (seed / "x.tar.gz").write_bytes(b"real")
            self.assertEqual(runtime.place_archive(entry, cache, seed, offline=True), "seeded")
            self.assertEqual(runtime.place_archive(entry, cache, None, offline=True), "cached")

    def test_offline_missing_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(runtime.Error):
                runtime.place_archive({"name": "y", "url": "", "sha256": SHA_A}, Path(tmp), None, True)


class ProvenanceTest(unittest.TestCase):
    def test_write_json_and_file_hashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "runtime"
            (tree / "bin").mkdir(parents=True)
            (tree / "bin/qemu").write_bytes(b"q")
            hashes = runtime.file_hashes(tree)
            self.assertEqual(hashes, {"bin/qemu": sha(b"q")})
            out = Path(tmp) / "p/provenance.json"
            runtime.write_json(out, {"runtime_files": hashes, "b": 1})
            self.assertEqual(json.loads(out.read_text()), {"runtime_files": hashes, "b": 1})
            self.assertTrue(out.read_text().endswith("\n"))
            self.assertFalse(out.with_name("provenance.json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
