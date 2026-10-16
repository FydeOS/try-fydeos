# Third-party notices

Try FydeOS's own code is Apache-2.0 (see `LICENSE` and `NOTICE`). The QEMU runtime and firmware
it builds and bundles are third-party software under their own licenses.

- **Try Omarchy** — MIT, <https://github.com/omacom/try-omarchy>, tag
  `v0.6.0`, commit `6166ca0759aad5c56d4c71128a0aea13dbcb67ad`. Its QEMU
  runtime recipe (build, preparation, relocation and verification scripts,
  patches and VirGL regression tests) is consumed by hash, unmodified except
  for `runtime/overlay/qemu-cocoa-product-identity.patch`, which is derived
  from upstream's patch of the same name. The staged recipe in every build
  output keeps upstream's `LICENSE` and `THIRD_PARTY_NOTICES.md`.
- **QEMU** — GPL-2.0 (and compatible component licenses), commit
  `c3d48b7d1e89604920e5b81b91140c2ad39a1943` (11.1.1) with Try Omarchy's
  patches and our identity patch. Corresponding source is the pinned tarball
  plus the patches named in `runtime/lock.json`.
- **edk2** (UEFI firmware shipped in QEMU's `pc-bios/`) — BSD-2-Clause-Patent.
- **virglrenderer** — MIT, 1.3.0 built from source with the
  startergo/homebrew-virglrenderer v1.0.42 patch set and upstream Try
  Omarchy's native-OpenGL patch.
- **libslirp** — BSD-3-Clause, 4.9.4 built from source with two Darwin fixes.
- **ANGLE** (BSD-3-Clause) and **libepoxy** (MIT) — startergo Homebrew
  bottles 1.0.16 and 1.0.5.
- **Homebrew core bottles** — GLib (LGPL-2.1+), Pixman (MIT), SDL3 and
  sdl2-compat (Zlib), libusb (LGPL-2.1+), gettext/libintl (LGPL-2.1+), PCRE2
  (BSD-3-Clause), zstd (BSD-3-Clause), lz4 (BSD-2-Clause), xz/liblzma
  (0BSD/public domain). Exact archives and hashes are in `runtime/lock.json`.
- **libfdt** (from dtc, GPL-2.0-or-later or BSD-2-Clause) and tables
  generated from **keycodemapdb** are compiled into QEMU.
- **Build-only tools** (not bundled) — Meson, Ninja, PyYAML, pip,
  setuptools, wheel and packaging, pinned in the lock.
