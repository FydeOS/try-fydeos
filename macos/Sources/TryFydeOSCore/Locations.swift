import Foundation

public struct Locations: Sendable {
    public var root: URL?
    public var bundleResources: URL?
    public var runtime: URL
    public var firmware: URL
    public var factorySpec: URL
    public var factoryImageOverride: URL?

    public var qemu: URL { runtime.appendingPathComponent("bin/qemu-system-aarch64") }
    public var firmwareCode: URL { firmware.appendingPathComponent("edk2-aarch64-code.fd") }
    public var varsTemplate: URL { firmware.appendingPathComponent("edk2-arm-vars.fd") }
    public var firmwareSums: URL { firmware.appendingPathComponent("SHA256SUMS") }

    public func factoryImage(_ spec: FactorySpec) -> URL {
        factoryImageOverride ?? factorySpec.deletingLastPathComponent().appendingPathComponent(spec.image.file)
    }

    /// App bundle `Contents/Resources` first, then the repository layout; the
    /// TRY_FYDEOS_* environment variables override either.
    public static func discover(environment env: [String: String] = ProcessInfo.processInfo.environment,
                                executable: URL? = nil) throws -> Locations {
        let exe = (executable ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let resources = findBundleResources(executable: exe)
        let root = resources == nil
            ? [exe, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)].lazy.compactMap(findRoot).first : nil
        func base(_ inBundle: String, _ inRepo: String) throws -> URL {
            if let resources { return resources.appendingPathComponent(inBundle) }
            guard let root else { throw ConfigError.invalid("repository root not found (looked above the executable and the current directory)") }
            return root.appendingPathComponent(inRepo)
        }
        func pick(_ key: String, _ inBundle: String, _ inRepo: String) throws -> URL {
            if let value = env[key], !value.isEmpty { return URL(fileURLWithPath: value).standardizedFileURL }
            return try base(inBundle, inRepo)
        }
        let image = env["TRY_FYDEOS_FACTORY_IMAGE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL }
        return Locations(root: root,
                         bundleResources: resources,
                         runtime: try pick("TRY_FYDEOS_RUNTIME", "runtime", "out/runtime/current/runtime"),
                         firmware: try pick("TRY_FYDEOS_FIRMWARE", "firmware", "firmware"),
                         factorySpec: try base("factory/spec.json", "factory/spec.json"),
                         factoryImageOverride: image)
    }

    /// `<name>.app/Contents/MacOS/<exe>` with `Contents/Resources/factory/spec.json` present.
    static func findBundleResources(executable: URL) -> URL? {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app" else { return nil }
        let resources = contents.appendingPathComponent("Resources")
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("factory/spec.json").path) else { return nil }
        return resources
    }

    static func findRoot(from start: URL) -> URL? {
        var dir = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
        while dir.path != "/" {
            let fm = FileManager.default
            if fm.fileExists(atPath: dir.appendingPathComponent("runtime/lock.json").path),
               fm.fileExists(atPath: dir.appendingPathComponent("factory/spec.json").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}
