import Foundation

public enum GLBackend: String, Sendable, CaseIterable {
    case native
    case angle

    var displayValue: String { self == .native ? "on" : "es" }
}

public struct HostForward: Sendable, Equatable {
    public var hostPort: Int
    public var guestPort: Int

    public init(hostPort: Int, guestPort: Int) {
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    public init(parsing text: String) throws {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let g = Int(parts[1]),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            throw ConfigError.invalid("forward must be HOSTPORT:GUESTPORT on 127.0.0.1, got '\(text)'")
        }
        self.init(hostPort: h, guestPort: g)
    }

    var qemuValue: String { "hostfwd=tcp:127.0.0.1:\(hostPort)-:\(guestPort)" }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

public struct VMPaths: Sendable, Equatable {
    public var qemu: String
    public var firmwareCode: String
    public var efiVars: String
    public var disk: String
    public var console: String
    public var qmpSocket: String

    public init(qemu: String, firmwareCode: String, efiVars: String, disk: String, console: String, qmpSocket: String) {
        self.qemu = qemu
        self.firmwareCode = firmwareCode
        self.efiVars = efiVars
        self.disk = disk
        self.console = console
        self.qmpSocket = qmpSocket
    }
}

public struct VMConfig: Sendable, Equatable {
    public static let minCPUs = 4
    public static let minMemoryMiB = 4096
    public static let hostReserveMiB = 4096
    public static let maxSocketPath = 103

    public var cpus: Int
    public var memoryMiB: Int
    public var fullScreen = false
    public var microphone = false
    public var hostForwards: [HostForward] = []
    public var glBackend: GLBackend = .native
    public var paths: VMPaths
    public var mac: String
    public var lockFD: Int32

    public init(cpus: Int = 4, memoryMiB: Int = 8192, paths: VMPaths, mac: String, lockFD: Int32) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.paths = paths
        self.mac = mac
        self.lockFD = lockFD
    }

    public func validate(host: HostInfo) throws {
        guard cpus >= Self.minCPUs, cpus <= host.logicalCores else {
            throw ConfigError.invalid("cpus must be \(Self.minCPUs)...\(host.logicalCores), got \(cpus)")
        }
        let maxMemory = host.memoryMiB - Self.hostReserveMiB
        guard memoryMiB >= Self.minMemoryMiB, memoryMiB <= maxMemory else {
            throw ConfigError.invalid("memory must be \(Self.minMemoryMiB)...\(maxMemory) MiB, got \(memoryMiB)")
        }
        var seen = Set<Int>()
        for f in hostForwards {
            guard (1...65535).contains(f.hostPort), (1...65535).contains(f.guestPort) else {
                throw ConfigError.invalid("forward ports must be 1...65535, got \(f.hostPort):\(f.guestPort)")
            }
            guard seen.insert(f.hostPort).inserted else {
                throw ConfigError.invalid("host port \(f.hostPort) forwarded twice")
            }
        }
        guard mac.range(of: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", options: .regularExpression) != nil,
              let first = UInt8(mac.prefix(2), radix: 16), first & 0x03 == 0x02 else {
            throw ConfigError.invalid("MAC must be a lowercase locally administered unicast address, got '\(mac)'")
        }
        guard lockFD > 2 else { throw ConfigError.invalid("lock fd must be > 2, got \(lockFD)") }
        let p = paths
        for (name, value) in [("qemu", p.qemu), ("firmware", p.firmwareCode), ("efi vars", p.efiVars),
                              ("disk", p.disk), ("console", p.console), ("qmp socket", p.qmpSocket)] {
            guard value.hasPrefix("/") else { throw ConfigError.invalid("\(name) path must be absolute: \(value)") }
            guard !value.contains(",") else { throw ConfigError.invalid("\(name) path must not contain a comma: \(value)") }
        }
        guard p.qmpSocket.utf8.count <= Self.maxSocketPath else {
            throw ConfigError.invalid("qmp socket path longer than \(Self.maxSocketPath) bytes: \(p.qmpSocket)")
        }
    }

    public func argv(host: HostInfo) throws -> [String] {
        try validate(host: host)
        let p = paths
        let netdev = (["user", "id=net"] + hostForwards.map(\.qemuValue)).joined(separator: ",")
        let display = "cocoa,gl=\(glBackend.displayValue),show-cursor=off,zoom-to-fit=on,full-grab=on,immersive=off,swap-opt-cmd=off,full-screen=\(fullScreen ? "on" : "off")"
        return [
            p.qemu,
            "-name", "Try FydeOS",
            "-machine", "virt,gic-version=3,acpi=on", "-accel", "hvf", "-cpu", "host,pmu=off",
            "-smp", "\(cpus),sockets=1,cores=\(cpus),threads=1", "-m", "\(memoryMiB)M", "-nodefaults",
            "-action", "reboot=reset,shutdown=poweroff",
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(p.firmwareCode)",
            "-drive", "if=pflash,format=raw,unit=1,file=\(p.efiVars)",
            "-drive", "if=none,id=root,file=\(p.disk),format=raw,cache=writeback,discard=unmap",
            "-device", "virtio-blk-pci,drive=root,serial=TRYFYDEOS,bootindex=0,romfile=",
            "-netdev", netdev,
            "-device", "virtio-net-pci,id=nic,netdev=net,mac=\(mac),romfile=",
            "-device", "virtio-gpu-gl-pci,id=gpu,max_outputs=1,xres=1920,yres=1080,romfile=",
            "-display", display,
            "-device", "virtio-keyboard-pci,id=keyboard,romfile=",
            "-device", "virtio-tablet-pci,id=tablet,romfile=",
            "-audiodev", "sdl,id=audio", "-device", "intel-hda,id=hda,romfile=",
            "-device", "\(microphone ? "hda-micro" : "hda-output"),bus=hda.0,audiodev=audio",
            "-object", "rng-random,id=rng,filename=/dev/urandom", "-device", "virtio-rng-pci,rng=rng,romfile=",
            "-serial", "file:\(p.console)", "-monitor", "none",
            "-qmp", "unix:\(p.qmpSocket),server=on,wait=off",
            "-add-fd", "fd=\(lockFD),set=1,opaque=storage-lock",
        ]
    }

    public static func randomMAC() -> String {
        var bytes = [UInt8](repeating: 0, count: 3)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return (["52", "54", "00"] + bytes.map { String(format: "%02x", $0) }).joined(separator: ":")
    }
}
