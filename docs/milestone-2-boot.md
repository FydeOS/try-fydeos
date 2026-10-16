# Milestone 2: boot

Date: 2026-10-16. Host: Apple M4, 10 cores, 24 GiB, macOS 27.0.1, Swift 6.4
(Command Line Tools). Runtime QEMU 11.1.1 from milestone 1. Factory image
`fydeos-arm64-vmware-io-v23-dev.bin` (R150-16700.56.0 dev 2026-09-18,
sha256 `34cc093f…3d88b`), APFS-cloned into `factory/`.

Everything below was run over ssh in `~/Workspace/try-fydeos` with the
release build of `macos/` (`make app-build`).

## Build and unit tests

`swift build` and `swift test` pass: 22 tests (two parameterized, with 13
and 9 cases) covering the argv contract, validation, workspace
marker and refusal, lock exclusivity, prepare/reset, and QMP framing with a
local Unix-socket server.

Command Line Tools 6.4 ship the swift-testing macro plugin in
`usr/lib/swift/host/plugins/testing` but do not search it; `Package.swift`
adds that `-plugin-path` to the test target when the active developer
directory is the Command Line Tools. Language mode is Swift 5.

## Workspace

The default workspace `~/Library/Application Support/Try FydeOS/VM/v1`
already holds an earlier attempt's VM (marker `.try-fydeos-storage`,
`current/disk.img`). It is refused as designed and was left untouched:

```
FAIL     workspace /Users/fydeos/Library/Application Support/Try FydeOS/VM/v1: non-empty directory without a .try-fydeos marker
```

All runs below use `--workspace "$HOME/Library/Application Support/Try FydeOS/VM/m2"`.

`tryfydeos prepare` hashed the factory image once (4.6 s) and cloned it; a
second `prepare` returned in 8 ms without hashing. `du` reports a clone's
logical size (7.0G) on APFS, so the clone cost was measured as the
volume's free space around `reset --yes` + `prepare`:

```
free before 886464496 KiB after 886464476 KiB delta 20 KiB
```

## Boot

```sh
nohup macos/.build/release/tryfydeos run --workspace "$W" --cpus 4 --memory 8192 > "$HOME/Library/Logs/Try FydeOS/tryfydeos-run-m2-20261016T072309Z.out" 2>&1 < /dev/null &!
```

The Cocoa window opened from the ssh session. `qemu.log`:

```
qemu-system-aarch64: warning: Could not create event tap, system key combos will not be captured.
GL strings: version='OpenGL 4.1 (Metal)' renderer='Apple M4' glsl='4.10'
[VREND CAPS] FINAL VALUES: glsl_level=410, max_samples=4
```

QEMU held the lock as fd 7 (`lsof`: `qemu-syst 57716 fydeos 7u REG … VM/m2/.lock`)
and ran as its own process group (`PID 57716 PPID 57714 PGID 57716`).
QMP was ready 2 s after spawn.

`console.log` (run `20261016T072309Z`):

```
[    0.000000] ACPI: SPCR: console: pl011,mmio32,0x9000000,9600
[    0.000000] Kernel command line: BOOT_IMAGE=/syslinux/vmlinuz.A init=/sbin/init rootwait ro noresume loglevel=7 noinitrd earlyprintk=ttyS0,115200 console=ttyS0,115200 chromiumos.allow_overlayfs i915.modeset=1 cros_efi cros_debug root=PARTUUID=B824E010-D5F8-0042-8823-D0FA95DB9966
[    0.009166] printk: legacy console [ttyAMA0] enabled
[    0.114322] input: QEMU Virtio Keyboard as /devices/pci0000:00/0000:00:04.0/virtio3/input/input1
[    0.115118] input: QEMU Virtio Tablet as /devices/pci0000:00/0000:00:05.0/virtio4/input/input2
[    0.117691] [drm] features: +virgl +edid -resource_blob -host_visible
[    0.123003] virtio_blk virtio0: [vda] 14614685 512-byte logical blocks (7.48 GB/6.97 GiB)
[    0.304799] frecon[244]: Frecon using drm driver virtio_gpu, version 0.1, date(0), desc(virtio GPU)
```

`init: ui main process … terminated` occurs 0 times. The last line is at
guest time 4.46 s; the file stayed at 52646 bytes from about 10 s after
spawn until shutdown (quiet for 140 s at 154 s elapsed).

`tryfydeos status` at about 3 minutes:

```
  query-status: {"running":true,"status":"running"}
  query-mice: [{"absolute":true,"current":true,"index":2,"name":"QEMU Virtio Tablet"}]
```

The guest screen was not looked at and the guest was not touched; reaching
OOBE is not verified by this record.

## Second run refused

With the VM running:

```
$ tryfydeos run --workspace "$W" --cpus 4 --memory 8192
tryfydeos: storage is in use by another Try FydeOS process or its QEMU (lock held on /Users/fydeos/Library/Application Support/Try FydeOS/VM/m2/.lock)
exit 1
```

No run directory was created and the running QEMU was unaffected.

## Shutdown

`tryfydeos shutdown` signalled the supervisor, which ran the ladder.
`supervisor.log`:

```
2026-10-16T07:26:08Z received signal 15, shutting down
2026-10-16T07:26:08Z system_powerdown, waiting 20 s
2026-10-16T07:26:08Z QMP event POWERDOWN
2026-10-16T07:26:28Z quit, waiting 5 s
2026-10-16T07:26:28Z QMP event SHUTDOWN
2026-10-16T07:26:28Z QEMU exit code 0
```

The guest did not power off within 20 s of the ACPI power button and
logged nothing on the serial console; the ladder's QMP `quit` stopped QEMU.
`run.json` (argv elided):

```
  "end" : "2026-10-16T07:26:28Z",
  "exitCode" : 0,
  "id" : "20261016T072309Z",
  "pid" : 57716,
  "qmpReady" : "2026-10-16T07:23:11Z",
  "start" : "2026-10-16T07:23:09Z",
  "supervisorPid" : 57714
```

The workspace was left prepared.

## Open

- The guest ignores `system_powerdown`, at least in this state (boot
  without user interaction, about 3 minutes up). Every shutdown currently
  ends at QMP `quit`, which skips the guest's own shutdown. Not
  investigated.
- `Could not create event tap`: `full-grab=on` cannot capture system key
  combinations without the macOS Input Monitoring/Accessibility grant for
  the process that launched QEMU.
- The default workspace path is taken by an earlier attempt's data.
