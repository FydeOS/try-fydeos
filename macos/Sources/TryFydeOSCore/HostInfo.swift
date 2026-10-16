import Foundation

public struct HostInfo: Sendable, Equatable {
    public var logicalCores: Int
    public var memoryMiB: Int
    public var macOSVersion: String
    public var isAppleSilicon: Bool
    public var isTranslated: Bool

    public init(logicalCores: Int, memoryMiB: Int, macOSVersion: String = "", isAppleSilicon: Bool = true, isTranslated: Bool = false) {
        self.logicalCores = logicalCores
        self.memoryMiB = memoryMiB
        self.macOSVersion = macOSVersion
        self.isAppleSilicon = isAppleSilicon
        self.isTranslated = isTranslated
    }

    public static func current() -> HostInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return HostInfo(
            logicalCores: Int(sysctlInt("hw.logicalcpu") ?? Int64(ProcessInfo.processInfo.activeProcessorCount)),
            memoryMiB: Int((sysctlInt("hw.memsize") ?? Int64(ProcessInfo.processInfo.physicalMemory)) >> 20),
            macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            isAppleSilicon: sysctlInt("hw.optional.arm64") == 1,
            isTranslated: sysctlInt("sysctl.proc_translated") == 1)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return Int64(Int32(truncatingIfNeeded: value))
        case 8: return value
        default: return nil
        }
    }
}
