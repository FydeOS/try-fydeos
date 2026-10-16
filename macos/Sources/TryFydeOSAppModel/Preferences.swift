import Foundation
import TryFydeOSCore

public struct Preferences: Equatable, Sendable {
    public enum Key {
        public static let cpus = "cpus"
        public static let memoryMiB = "memoryMiB"
        public static let fullScreen = "fullScreen"
        public static let microphone = "microphone"
        public static let firstRunNoteDismissed = "firstRunNoteDismissed"
        public static let workspace = "workspace"
    }
    public static let workspaceEnvironment = "TRY_FYDEOS_WORKSPACE"
    public static let memoryStepMiB = 1024

    public var cpus: Int
    public var memoryMiB: Int
    public var fullScreen = false
    public var microphone = false
    public var firstRunNoteDismissed = false

    public init(cpus: Int, memoryMiB: Int, fullScreen: Bool = false, microphone: Bool = false, firstRunNoteDismissed: Bool = false) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.fullScreen = fullScreen
        self.microphone = microphone
        self.firstRunNoteDismissed = firstRunNoteDismissed
    }

    public static func cpuChoices(_ host: HostInfo) -> [Int] {
        Array(VMConfig.minCPUs...max(VMConfig.minCPUs, host.logicalCores))
    }

    public static func memoryChoices(_ host: HostInfo) -> [Int] {
        let top = max(VMConfig.minMemoryMiB, host.memoryMiB - VMConfig.hostReserveMiB)
        return Array(stride(from: VMConfig.minMemoryMiB, through: top, by: memoryStepMiB))
    }

    public static func defaults(for host: HostInfo) -> Preferences {
        Preferences(cpus: min(8, host.logicalCores), memoryMiB: host.memoryMiB >= 16384 ? 8192 : 4096).clamped(to: host)
    }

    /// Snaps CPUs and memory to the nearest offered choice at or below the value.
    public func clamped(to host: HostInfo) -> Preferences {
        var p = self
        let cpus = Self.cpuChoices(host)
        p.cpus = min(max(self.cpus, cpus.first!), cpus.last!)
        let memory = Self.memoryChoices(host)
        p.memoryMiB = memory.last(where: { $0 <= self.memoryMiB }) ?? memory.first!
        return p
    }

    public static func load(from store: UserDefaults, host: HostInfo) -> Preferences {
        var p = defaults(for: host)
        if store.object(forKey: Key.cpus) != nil { p.cpus = store.integer(forKey: Key.cpus) }
        if store.object(forKey: Key.memoryMiB) != nil { p.memoryMiB = store.integer(forKey: Key.memoryMiB) }
        p.fullScreen = store.bool(forKey: Key.fullScreen)
        p.microphone = store.bool(forKey: Key.microphone)
        p.firstRunNoteDismissed = store.bool(forKey: Key.firstRunNoteDismissed)
        return p.clamped(to: host)
    }

    public func save(to store: UserDefaults) {
        store.set(cpus, forKey: Key.cpus)
        store.set(memoryMiB, forKey: Key.memoryMiB)
        store.set(fullScreen, forKey: Key.fullScreen)
        store.set(microphone, forKey: Key.microphone)
        store.set(firstRunNoteDismissed, forKey: Key.firstRunNoteDismissed)
    }

    public var launchOptions: LaunchOptions {
        LaunchOptions(cpus: cpus, memoryMiB: memoryMiB, fullScreen: fullScreen, microphone: microphone)
    }

    /// Hidden override for testing: environment first, then the `workspace` default, then `VM/v1`.
    public static func workspaceURL(store: UserDefaults, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[workspaceEnvironment], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let path = store.string(forKey: Key.workspace), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return Workspace.defaultURL
    }
}
