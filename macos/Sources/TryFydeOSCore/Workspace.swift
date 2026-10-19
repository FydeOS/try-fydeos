import Darwin
import Foundation

public enum WorkspaceError: Error, CustomStringConvertible {
    case foreign(String, String)
    case notAPFS(String, String)
    case notPrepared(String)
    case noSpace(needed: Int64, available: Int64)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .foreign(let path, let why): return "refusing to use \(path): \(why)"
        case .notAPFS(let path, let fs): return "\(path) is on \(fs), not APFS; copy-on-write clones need APFS"
        case .notPrepared(let path): return "workspace \(path) is not prepared; run 'tryfydeos prepare'"
        case .noSpace(let needed, let available):
            return String(format: "not enough free space: %.1f GB needed, %.1f GB available", Double(needed) / 1e9, Double(available) / 1e9)
        case .system(let what, let code): return "\(what): \(String(cString: strerror(code)))"
        }
    }
}

public struct Metadata: Codable, Equatable, Sendable {
    public var schema = 1
    public var factory: FactoryRecord
    public var diskBytes: Int64?
    public var mac: String
    public var created: String
}

public struct RunRecord: Codable, Sendable {
    public var id: String
    public var argv: [String]
    public var supervisorPid: Int32
    public var pid: Int32?
    public var start: String
    public var qmpReady: String?
    public var end: String?
    public var exitCode: Int32?
    public var signal: Int32?

    public init(id: String, argv: [String], supervisorPid: Int32, start: String) {
        self.id = id
        self.argv = argv
        self.supervisorPid = supervisorPid
        self.start = start
    }
}

public enum WorkspaceState: Equatable, Sendable {
    case absent
    case empty
    case marked
    case foreign(String)
}

public func utcTimestamp(_ date: Date = Date()) -> String {
    ISO8601DateFormatter().string(from: date)
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(value) + Data("\n".utf8)).write(to: url, options: .atomic)
}

public final class Workspace {
    public static let markerName = ".try-fydeos"
    public static let markerContent = "try-fydeos-vm 1\n"

    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Try FydeOS/VM/v1")
    }

    public var marker: URL { url.appendingPathComponent(Self.markerName) }
    public var lockFile: URL { url.appendingPathComponent(".lock") }
    public var disk: URL { url.appendingPathComponent("disk.img") }
    var stagingDisk: URL { url.appendingPathComponent(".disk.img.preparing") }
    public var efiVars: URL { url.appendingPathComponent("efi-vars.fd") }
    public var metadataFile: URL { url.appendingPathComponent("metadata.json") }
    public var qmpSocket: URL { url.appendingPathComponent("qmp.sock") }
    public var runsDir: URL { url.appendingPathComponent("runs") }
    public var lastRun: URL { url.appendingPathComponent("last-run") }

    public var state: WorkspaceState {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return .absent }
        guard isDir.boolValue else { return .foreign("not a directory") }
        if let text = try? String(contentsOf: marker, encoding: .utf8) {
            return text == Self.markerContent ? .marked : .foreign("marker \(Self.markerName) has unknown content \(text.debugDescription)")
        }
        let entries = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? ["?"]).filter { $0 != ".lock" }
        return entries.isEmpty ? .empty : .foreign("non-empty directory without a \(Self.markerName) marker")
    }

    public var isPrepared: Bool {
        let fm = FileManager.default
        return [metadataFile, disk, efiVars].allSatisfy { fm.fileExists(atPath: $0.path) }
    }

    public var isLocked: Bool { StorageLock.isHeld(path: lockFile.path) }

    public func filesystemType() throws -> String {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { throw WorkspaceError.system("statfs \(url.path)", errno) }
        return withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// Takes the storage lock, creating and marking the directory if it is new.
    public func open(requireAPFS: Bool = true) throws -> StorageLock {
        if case .foreign(let why) = state { throw WorkspaceError.foreign(url.path, why) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if requireAPFS {
            let fs = try filesystemType()
            guard fs == "apfs" else { throw WorkspaceError.notAPFS(url.path, fs) }
        }
        let lock = try StorageLock(path: lockFile.path)
        switch state {
        case .foreign(let why):
            lock.release()
            throw WorkspaceError.foreign(url.path, why)
        case .marked:
            break
        case .absent, .empty:
            try Data(Self.markerContent.utf8).write(to: marker, options: .atomic)
        }
        return lock
    }

    public func loadMetadata() -> Metadata? {
        guard let data = try? Data(contentsOf: metadataFile) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    /// Unpacks the zstd factory image into a sparse disk of `spec.diskBytes` and clones the vars
    /// template. Idempotent: a prepared workspace is left alone.
    public func prepare(lock: StorageLock, spec: FactorySpec, image: URL, zstd: URL, varsTemplate: URL,
                        progress: (_ bytesWritten: Int64, _ totalBytes: Int64) -> Void = { _, _ in }) throws -> Metadata {
        precondition(lock.path == lockFile.path && lock.fd >= 0)
        if isPrepared {
            guard let existing = loadMetadata() else {
                throw WorkspaceError.foreign(url.path, "metadata.json is unreadable; inspect it or run 'tryfydeos reset --yes'")
            }
            return existing
        }
        let fm = FileManager.default
        for leftover in [metadataFile, disk, efiVars, stagingDisk] { try? fm.removeItem(at: leftover) }
        let raw = spec.image.rawBytes
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { throw WorkspaceError.system("statfs \(url.path)", errno) }
        let available = Int64(fs.f_bavail) * Int64(fs.f_bsize)
        guard available >= raw + (1 << 30) else { throw WorkspaceError.noSpace(needed: raw + (1 << 30), available: available) }
        try Self.clone(varsTemplate, to: efiVars)
        try unpack(image, zstd: zstd, to: stagingDisk, rawBytes: raw, progress: progress)
        guard rename(stagingDisk.path, disk.path) == 0 else { throw WorkspaceError.system("rename \(stagingDisk.path) -> \(disk.path)", errno) }
        guard truncate(disk.path, off_t(spec.diskBytes)) == 0 else { throw WorkspaceError.system("truncate \(disk.path)", errno) }
        let metadata = Metadata(factory: FactoryRecord(file: spec.image.file, sha256: spec.image.sha256, rawBytes: raw),
                                diskBytes: spec.diskBytes, mac: VMConfig.randomMAC(), created: utcTimestamp())
        try writeJSON(metadata, to: metadataFile)
        return metadata
    }

    /// zstd checks its frame checksums while decompressing; the size check catches a truncated or foreign image.
    private func unpack(_ image: URL, zstd: URL, to output: URL, rawBytes: Int64,
                        progress: (Int64, Int64) -> Void) throws {
        var done = false
        defer { if !done { try? FileManager.default.removeItem(at: output) } }
        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-d", "-q", "-f", "-o", output.path, image.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        progress(0, rawBytes)
        try process.run()
        func written() -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        while process.isRunning {
            usleep(250_000)
            progress(min(written(), rawBytes), rawBytes)
        }
        process.waitUntilExit()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ConfigError.invalid("unpacking \(image.path) failed (zstd exit \(process.terminationStatus)): \(message)")
        }
        let size = written()
        guard size == rawBytes else {
            throw ConfigError.invalid("\(image.path) unpacked to \(size) bytes, spec says \(rawBytes)")
        }
        guard chmod(output.path, 0o600) == 0 else { throw WorkspaceError.system("chmod \(output.path)", errno) }
        progress(size, rawBytes)
        done = true
    }

    /// Deletes the VM's disk, variables and metadata. Never touches runs/, the marker, the lock or the directory.
    public func reset(lock: StorageLock) throws {
        precondition(lock.path == lockFile.path && lock.fd >= 0)
        for file in [disk, efiVars, metadataFile] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func newRunDirectory(now: Date = Date()) throws -> (id: String, url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let id = formatter.string(from: now)
        let dir = runsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: lastRun)
        try FileManager.default.createSymbolicLink(atPath: lastRun.path, withDestinationPath: "runs/\(id)")
        return (id, dir)
    }

    public func lastRunRecord() -> (dir: URL, record: RunRecord)? {
        let dir = lastRun.resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("run.json")),
              let record = try? JSONDecoder().decode(RunRecord.self, from: data) else { return nil }
        return (dir, record)
    }

    public static func writeRunRecord(_ record: RunRecord, in dir: URL) throws {
        try writeJSON(record, to: dir.appendingPathComponent("run.json"))
    }

    static func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw WorkspaceError.system("clonefile \(source.path) -> \(destination.path)", errno)
        }
        guard chmod(destination.path, 0o600) == 0 else {
            throw WorkspaceError.system("chmod \(destination.path)", errno)
        }
    }
}
