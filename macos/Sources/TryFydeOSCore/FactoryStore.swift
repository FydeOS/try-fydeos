import CryptoKit
import Darwin
import Foundation

public struct ImportProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case copying
        case verifying
    }

    public var phase: Phase
    public var bytes: Int64
    public var total: Int64

    public init(phase: Phase, bytes: Int64, total: Int64) {
        self.phase = phase
        self.bytes = bytes
        self.total = total
    }

    public var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
}

public enum FactoryStoreState: Equatable, Sendable {
    case empty
    case unverified(String)
    case verified(FactoryRecord)
}

public enum FactoryStoreError: Error, CustomStringConvertible {
    case notInstalled(String, String)

    public var description: String {
        switch self {
        case .notInstalled(let dir, let why):
            return "the FydeOS image is not installed in \(dir) (\(why)); run 'tryfydeos import-image [PATH]' or Install… in the app"
        }
    }
}

/// The verified factory image every workspace is cloned from:
/// `<directory>/<spec.image.file>` plus `<file>.verified.json` written after a full SHA-256 check.
public struct FactoryStore: Sendable {
    public static let environmentKey = "TRY_FYDEOS_FACTORY_DIR"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Try FydeOS/factory")
    }

    public let directory: URL
    public let spec: FactorySpec

    public init(directory: URL, spec: FactorySpec) {
        self.directory = directory.standardizedFileURL
        self.spec = spec
    }

    public var image: URL { directory.appendingPathComponent(spec.image.file) }
    public var recordFile: URL { directory.appendingPathComponent(spec.image.file + ".verified.json") }
    var temporaryImage: URL { directory.appendingPathComponent(".\(spec.image.file).importing") }

    /// Size and mtime against the record only; never hashes.
    public var state: FactoryStoreState {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: image.path) else { return .empty }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        guard size == spec.image.bytes else { return .unverified("\(image.lastPathComponent) is \(size) bytes, spec says \(spec.image.bytes)") }
        guard let data = try? Data(contentsOf: recordFile),
              let record = try? JSONDecoder().decode(FactoryRecord.self, from: data) else { return .unverified("not verified") }
        guard record.sha256 == spec.image.sha256, record.bytes == size, record.mtime == mtime,
              record.file == spec.image.file else { return .unverified("changed since it was verified") }
        return .verified(record)
    }

    public func verifiedImage() throws -> (url: URL, record: FactoryRecord) {
        switch state {
        case .verified(let record): return (image, record)
        case .empty: throw FactoryStoreError.notInstalled(directory.path, "no \(spec.image.file)")
        case .unverified(let why): throw FactoryStoreError.notInstalled(directory.path, why)
        }
    }

    /// First candidate that exists as a regular file.
    public static func findSource(_ candidates: [URL]) -> URL? {
        candidates.first { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// Clones (same APFS volume) or copies `source` under a temporary name, checks its SHA-256
    /// against the spec, then renames it into place and writes the record. Re-run to retry.
    @discardableResult
    public func importImage(from source: URL, allowClone: Bool = true,
                            progress: (ImportProgress) -> Void = { _ in }) throws -> FactoryRecord {
        let fm = FileManager.default
        let total = spec.image.bytes
        let attrs = try fm.attributesOfItem(atPath: source.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard size == total else {
            throw ConfigError.invalid("\(source.path) is \(size) bytes, spec says \(total) for \(spec.image.file)")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = temporaryImage
        try? fm.removeItem(at: temp)
        var done = false
        defer { if !done { try? fm.removeItem(at: temp) } }

        let digest: String
        if allowClone, clonefile(source.path, temp.path, 0) == 0 {
            progress(ImportProgress(phase: .copying, bytes: total, total: total))
            digest = try FactorySpec.sha256(of: temp) { progress(ImportProgress(phase: .verifying, bytes: $0, total: total)) }
        } else {
            if allowClone, errno != EXDEV, errno != ENOTSUP {
                throw WorkspaceError.system("clonefile \(source.path) -> \(temp.path)", errno)
            }
            digest = try Self.copyAndHash(source, to: temp) { progress(ImportProgress(phase: .copying, bytes: $0, total: total)) }
        }
        guard digest == spec.image.sha256 else {
            throw ConfigError.invalid("\(source.path) has sha256 \(digest), spec says \(spec.image.sha256)")
        }
        guard chmod(temp.path, 0o644) == 0 else { throw WorkspaceError.system("chmod \(temp.path)", errno) }
        // Drop the old record first: a crash between rename and record leaves "unverified", never a stale "verified".
        try? fm.removeItem(at: recordFile)
        guard rename(temp.path, image.path) == 0 else { throw WorkspaceError.system("rename \(temp.path) -> \(image.path)", errno) }
        done = true
        let final = try fm.attributesOfItem(atPath: image.path)
        let record = FactoryRecord(file: spec.image.file, sha256: digest, bytes: total,
                                   mtime: (final[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        try writeJSON(record, to: recordFile)
        return record
    }

    static func copyAndHash(_ source: URL, to destination: URL, progress: (Int64) -> Void) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceError.system("create \(destination.path)", errno)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            progress(copied)
        }
        try output.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
