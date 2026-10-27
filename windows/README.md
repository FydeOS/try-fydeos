# Try FydeOS for Windows

Go launcher for the Windows port; architecture and the QEMU contract are in
`../docs/windows.md`. Built on the workstation, run on a Windows 10/11 x64
host with the Windows Hypervisor Platform enabled.

```
internal/core/      factory spec, locations, workspace, lock, argv, QMP, session, host probe
cmd/tryfydeos/      console CLI: doctor, prepare, run, inspect, shutdown, reset
runtime.lock.json   pinned Try Omarchy WINQ-EMU runtime (url + sha256)
scripts/            fetch-runtime.sh
```

## Build and test (workstation)

```sh
make win-runtime   # fetch + verify the pinned runtime, unpack into out/win-runtime/
make win-test      # go vet + go test ./... (OS-independent parts, fake QEMU)
make win-build     # out/win-build/tryfydeos.exe (GOOS=windows, no cgo)
make win-image     # zstd -T32 -19 the amd64 raw image into factory/
make win-sync      # exe, factory/amd64-vmware-io.json and windows/ -> NUC D:\try-fydeos\dev\
```

The `.zst` itself is copied to the NUC once, by hand, into `D:\try-fydeos\factory\`.

## Run on the NUC

```powershell
$env:TRY_FYDEOS_WORKSPACE = "D:\try-fydeos\dev\vm"
$env:TRY_FYDEOS_RUNTIME = "D:\try-fydeos\runtime"
$env:TRY_FYDEOS_FACTORY_IMAGE = "D:\try-fydeos\factory\fydeos-amd64-vmware-io-R150-16700.56.0-d20261027.bin.zst"
$spec = "D:\try-fydeos\dev\amd64-vmware-io.json"
D:\try-fydeos\dev\tryfydeos.exe doctor --spec $spec
D:\try-fydeos\dev\tryfydeos.exe prepare --spec $spec
D:\try-fydeos\dev\tryfydeos.exe run --spec $spec --cpus 2 --memory-mib 3072 --forward 2201:22
D:\try-fydeos\dev\tryfydeos.exe shutdown          # from a second shell
```

`run` needs the interactive desktop session: QEMU's `sdl,gl=on` display
aborts in session 0 (an SSH login) because no OpenGL provider exists there.

Windows-tagged tests run on the NUC from a copy of this directory:
`D:\Go\bin\go.exe test ./...` in `D:\try-fydeos\dev\src`.

Defaults without the overrides: workspace `%LOCALAPPDATA%\Try FydeOS\VM\v1`,
runtime `runtime\` and spec `factory\amd64-vmware-io.json` next to the exe;
`%LOCALAPPDATA%\Try FydeOS\preferences.json` may set `workspace` and
`forwards` (`["2201:22"]`); `TRY_FYDEOS_FORWARDS` takes `2201:22,8080:80`.
