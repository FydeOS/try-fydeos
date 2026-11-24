import Foundation

public struct Locations: Sendable {
    public var root: URL?
    public var bundleResources: URL?
    public var runtime: URL
    public var firmware: URL
    public var factorySpec: URL
    public var factoryImageOverride: URL?
    /// The zstd-compressed raw image shipped with the app, if any.
    public var bundledImage: URL? = nil
    public var images: URL = imagesDir
    /// Names the app to the release API.
    public var appVersion = "dev"

    /// Launch Services names the Dock tile after the executable file, so the bundle ships QEMU as `Try FydeOS`.
    public static let qemuNames = ["Try FydeOS", "qemu-system-aarch64"]

    public var qemu: URL {
        let bin = runtime.appendingPathComponent("bin")
        let found = Self.qemuNames.first { FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent($0).path) }
        return bin.appendingPathComponent(found ?? Self.qemuNames.last!)
    }
    public var firmwareCode: URL { firmware.appendingPathComponent("edk2-aarch64-code.fd") }
    public var varsTemplate: URL { firmware.appendingPathComponent("edk2-arm-vars.fd") }
    public var firmwareSums: URL { firmware.appendingPathComponent("SHA256SUMS") }
    public var zstd: URL { runtime.appendingPathComponent("bin/zstd") }

    /// The .ova, .zip or .zst a new VM is converted from, and its record: TRY_FYDEOS_FACTORY_IMAGE as is;
    /// then the bundled image; otherwise the release API's image when it differs from the pinned one, else
    /// the pinned one, downloaded into `images` unless a file of the right size is there.
    public func factoryContainer(spec: FactorySpec, say: (String) -> Void,
                                 progress: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws -> (URL, FactoryRecord) {
        let fm = FileManager.default
        if let factoryImageOverride {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: factoryImageOverride.path, isDirectory: &isDir), !isDir.boolValue else {
                throw ConfigError.invalid("FydeOS image \(factoryImageOverride.path) not found (TRY_FYDEOS_FACTORY_IMAGE)")
            }
            say("using the local image \(factoryImageOverride.path)")
            return (factoryImageOverride, FactoryRecord(fileName: factoryImageOverride.lastPathComponent))
        }
        if let bundledImage {
            say("using the bundled image \(bundledImage.path)")
            return (bundledImage, FactoryRecord(url: spec.image.url, fileName: bundledImage.lastPathComponent, sha256: spec.image.sha256,
                                                version: spec.image.version))
        }
        var record = FactoryRecord(url: spec.image.url, fileName: try urlFileName(spec.image.url), sha256: spec.image.sha256,
                                   version: spec.image.version)
        var size = spec.image.bytes
        if let release = spec.release {
            do {
                let rel = try await fetchRelease(api: release.api, board: release.board, appVersion: appVersion)
                if rel.sha256 == record.sha256 {
                    say("release API lists the pinned image \(rel.fileName)")
                } else {
                    do {
                        let n = try await remoteSize(url: rel.url)
                        say("release API lists \(rel.fileName) \(rel.version) (\(rel.releaseDate)), newer than the pinned image")
                        record = FactoryRecord(url: rel.url, fileName: rel.fileName, sha256: rel.sha256, version: "\(rel.version), \(rel.releaseDate)")
                        size = n
                    } catch {
                        say("release API lists \(rel.fileName) \(rel.version) (\(rel.releaseDate)), but its size is unknown: \(error); using the pinned image")
                    }
                }
            } catch {
                say("release API: \(error); using the pinned image")
            }
        } else {
            say("no release API in the factory spec; using the pinned image")
        }
        let dest = images.appendingPathComponent(record.fileName)
        func fileSize(_ url: URL) -> Int64? { (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value }
        if fileSize(dest) == size {
            say("using the downloaded image \(dest.path)")
            pruneImages(keeping: record.fileName, say: say)
            return (dest, record)
        }
        try fm.createDirectory(at: images, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let have = fileSize(URL(fileURLWithPath: dest.path + ".part")) ?? 0
        let need = size - have + (10 << 30)
        let free = try freeBytes(images)
        guard free >= need else { throw WorkspaceError.noSpace(needed: need, available: free) }
        say("downloading \(record.url) into \(dest.path) (\(size) bytes)")
        let start = Date()
        try await download(url: record.url, size: size, sha256: record.sha256, to: dest, progress: progress)
        say(String(format: "downloaded in %.1f s", Date().timeIntervalSince(start)))
        pruneImages(keeping: record.fileName, say: say)
        return (dest, record)
    }

    private func pruneImages(keeping name: String, say: (String) -> Void) {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: images.path)) ?? [] where entry != name {
            let url = images.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            do {
                try fm.removeItem(at: url)
                say("removed superseded image \(entry)")
            } catch {
                say("could not remove \(url.path): \(error)")
            }
        }
    }

    /// App bundle `Contents/Resources` first, then the repository layout; the
    /// TRY_FYDEOS_* environment variables override either. Only a bundle carries an image.
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
        func path(_ key: String) -> URL? {
            env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL }
        }
        var bundledImage = resources?.appendingPathComponent("factory/image.zst")
        if let image = path("TRY_FYDEOS_BUNDLED_IMAGE") {
            guard FileManager.default.fileExists(atPath: image.path) else {
                throw ConfigError.invalid("bundled image \(image.path) not found (TRY_FYDEOS_BUNDLED_IMAGE)")
            }
            bundledImage = image
        } else if let image = bundledImage, !FileManager.default.fileExists(atPath: image.path) {
            bundledImage = nil
        }
        return Locations(root: root,
                         bundleResources: resources,
                         runtime: try pick("TRY_FYDEOS_RUNTIME", "runtime", "out/runtime/current/runtime"),
                         firmware: try pick("TRY_FYDEOS_FIRMWARE", "firmware", "firmware"),
                         factorySpec: try base("factory/spec.json", "factory/arm64-vmware-io.json"),
                         factoryImageOverride: path("TRY_FYDEOS_FACTORY_IMAGE"),
                         bundledImage: bundledImage,
                         appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
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
               fm.fileExists(atPath: dir.appendingPathComponent("factory/arm64-vmware-io.json").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}
