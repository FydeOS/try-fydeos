import Testing
@testable import TryFydeOSCore

let host = HostInfo(logicalCores: 10, memoryMiB: 24576)

func config() -> VMConfig {
    VMConfig(cpus: 4, memoryMiB: 8192,
             paths: VMPaths(qemu: "/rt/bin/qemu-system-aarch64", firmwareCode: "/fw/edk2-aarch64-code.fd",
                            efiVars: "/vm/Application Support/efi-vars.fd", disk: "/vm/Application Support/disk.img",
                            console: "/vm/runs/1/console.log", qmpSocket: "/vm/qmp.sock"),
             mac: "52:54:00:12:34:56", lockFD: 3)
}

func values(_ argv: [String], _ option: String) -> [String] {
    argv.indices.filter { argv[$0] == option }.map { argv[$0 + 1] }
}

@Test func argvMatchesContract() throws {
    let argv = try config().argv(host: host)
    #expect(argv == [
        "/rt/bin/qemu-system-aarch64",
        "-name", "Try FydeOS",
        "-machine", "virt,gic-version=3,acpi=on", "-accel", "hvf", "-cpu", "host,pmu=off",
        "-smp", "4,sockets=1,cores=4,threads=1", "-m", "8192M", "-nodefaults",
        "-action", "reboot=reset,shutdown=poweroff",
        "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=/fw/edk2-aarch64-code.fd",
        "-drive", "if=pflash,format=raw,unit=1,file=/vm/Application Support/efi-vars.fd",
        "-drive", "if=none,id=root,file=/vm/Application Support/disk.img,format=raw,cache=writeback,discard=unmap",
        "-device", "virtio-blk-pci,drive=root,serial=TRYFYDEOS,bootindex=0,romfile=",
        "-netdev", "user,id=net",
        "-device", "virtio-net-pci,id=nic,netdev=net,mac=52:54:00:12:34:56,romfile=",
        "-device", "virtio-gpu-gl-pci,id=gpu,max_outputs=1,xres=1920,yres=1080,romfile=",
        "-display", "cocoa,gl=on,show-cursor=off,zoom-to-fit=on,full-grab=on,immersive=off,swap-opt-cmd=off,full-screen=off",
        "-device", "virtio-keyboard-pci,id=keyboard,romfile=",
        "-device", "virtio-tablet-pci,id=tablet,romfile=",
        "-audiodev", "sdl,id=audio", "-device", "intel-hda,id=hda,romfile=",
        "-device", "hda-output,bus=hda.0,audiodev=audio",
        "-object", "rng-random,id=rng,filename=/dev/urandom", "-device", "virtio-rng-pci,rng=rng,romfile=",
        "-serial", "file:/vm/runs/1/console.log", "-monitor", "none",
        "-qmp", "unix:/vm/qmp.sock,server=on,wait=off",
        "-add-fd", "fd=3,set=1,opaque=storage-lock",
    ])
}

@Test func deviceListHasTabletAndNoUSB() throws {
    let argv = try config().argv(host: host)
    let devices = values(argv, "-device").map { String($0.split(separator: ",")[0]) }
    #expect(devices == ["virtio-blk-pci", "virtio-net-pci", "virtio-gpu-gl-pci", "virtio-keyboard-pci",
                        "virtio-tablet-pci", "intel-hda", "hda-output", "virtio-rng-pci"])
    #expect(!argv.contains { $0.lowercased().contains("usb") })
    #expect(!argv.contains { $0.contains("virtio-mouse") || $0.contains("vdagent") })
}

@Test func optionsChangeOnlyTheirArguments() throws {
    var c = config()
    c.cpus = 8
    c.memoryMiB = 16384
    c.fullScreen = true
    c.microphone = true
    c.glBackend = .angle
    c.hostForwards = [HostForward(hostPort: 2222, guestPort: 22), HostForward(hostPort: 8080, guestPort: 80)]
    let argv = try c.argv(host: host)
    #expect(values(argv, "-smp") == ["8,sockets=1,cores=8,threads=1"])
    #expect(values(argv, "-m") == ["16384M"])
    #expect(values(argv, "-display") == ["cocoa,gl=es,show-cursor=off,zoom-to-fit=on,full-grab=on,immersive=off,swap-opt-cmd=off,full-screen=on"])
    #expect(values(argv, "-netdev") == ["user,id=net,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80"])
    #expect(values(argv, "-device").contains("hda-micro,bus=hda.0,audiodev=audio"))
    #expect(!values(argv, "-device").contains { $0.hasPrefix("hda-output") })
}

@Test func nativeGLIsDefault() {
    #expect(config().glBackend == .native)
}

@Test(arguments: [
    { (c: inout VMConfig) in c.cpus = 3 },
    { (c: inout VMConfig) in c.cpus = 11 },
    { (c: inout VMConfig) in c.memoryMiB = 4095 },
    { (c: inout VMConfig) in c.memoryMiB = 24576 - 4095 },
    { (c: inout VMConfig) in c.hostForwards = [HostForward(hostPort: 0, guestPort: 22)] },
    { (c: inout VMConfig) in c.hostForwards = [HostForward(hostPort: 2222, guestPort: 70000)] },
    { (c: inout VMConfig) in c.hostForwards = [HostForward(hostPort: 2222, guestPort: 22), HostForward(hostPort: 2222, guestPort: 23)] },
    { (c: inout VMConfig) in c.mac = "52:54:00:12:34" },
    { (c: inout VMConfig) in c.mac = "53:54:00:12:34:56" },
    { (c: inout VMConfig) in c.paths.disk = "/vm/a,b/disk.img" },
    { (c: inout VMConfig) in c.paths.disk = "relative/disk.img" },
    { (c: inout VMConfig) in c.paths.qmpSocket = "/" + String(repeating: "q", count: 120) },
    { (c: inout VMConfig) in c.lockFD = 2 },
] as [@Sendable (inout VMConfig) -> Void])
func validationRejects(_ mutate: @Sendable (inout VMConfig) -> Void) {
    var c = config()
    mutate(&c)
    #expect(throws: ConfigError.self) { try c.argv(host: host) }
}

@Test func boundariesAccepted() throws {
    var c = config()
    c.cpus = 10
    c.memoryMiB = 24576 - 4096
    _ = try c.argv(host: host)
    c.cpus = 4
    c.memoryMiB = 4096
    _ = try c.argv(host: host)
}

@Test(arguments: ["127.0.0.1:2222:22", "0.0.0.0:2222:22", "2222", "2222:22 ", "22 22:1", "a:b", "2222,hostfwd=tcp::1-:2:22", "2222:22,x", ":22"])
func forwardParsingRejects(_ text: String) {
    #expect(throws: ConfigError.self) { try HostForward(parsing: text) }
}

@Test func forwardParsingIsLoopbackOnly() throws {
    let f = try HostForward(parsing: "2222:22")
    #expect(f == HostForward(hostPort: 2222, guestPort: 22))
    #expect(f.qemuValue == "hostfwd=tcp:127.0.0.1:2222-:22")
}

@Test func randomMACIsLocallyAdministered() throws {
    var c = config()
    c.mac = VMConfig.randomMAC()
    _ = try c.argv(host: host)
    #expect(c.mac.hasPrefix("52:54:00:"))
}
