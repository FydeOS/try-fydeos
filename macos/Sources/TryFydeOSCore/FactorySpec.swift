import CryptoKit
import Foundation

public struct FactorySpec: Decodable, Sendable {
    public struct Image: Decodable, Sendable {
        public var file: String
        public var bytes: Int64
        public var sha256: String
        public var version: String
    }

    public var schema: Int
    public var image: Image
    public var board: String

    public static func load(_ url: URL) throws -> FactorySpec {
        let spec = try JSONDecoder().decode(FactorySpec.self, from: Data(contentsOf: url))
        guard spec.schema == 1 else { throw ConfigError.invalid("unsupported factory spec schema \(spec.schema)") }
        guard spec.image.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !spec.image.file.contains("/"), spec.image.bytes > 0 else {
            throw ConfigError.invalid("malformed factory spec: \(url.path)")
        }
        return spec
    }

    /// Size check every time; the full SHA-256 only when `known` does not already
    /// vouch for this exact file (same digest, size and mtime).
    public func verify(imageAt url: URL, known: FactoryRecord? = nil, beforeHashing: () -> Void = {}) throws -> FactoryRecord {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        guard size == image.bytes else {
            throw ConfigError.invalid("factory image \(url.path) is \(size) bytes, spec says \(image.bytes)")
        }
        if let known, known.sha256 == image.sha256, known.bytes == size, known.mtime == mtime {
            return known
        }
        beforeHashing()
        let digest = try Self.sha256(of: url)
        guard digest == image.sha256 else {
            throw ConfigError.invalid("factory image \(url.path) has sha256 \(digest), spec says \(image.sha256)")
        }
        return FactoryRecord(file: url.lastPathComponent, sha256: digest, bytes: size, mtime: mtime)
    }

    public static func sha256(of url: URL, progress: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var hashed: Int64 = 0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            hashed += Int64(chunk.count)
            progress(hashed)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct FactoryRecord: Codable, Equatable, Sendable {
    public var file: String
    public var sha256: String
    public var bytes: Int64
    public var mtime: Double

    public init(file: String, sha256: String, bytes: Int64, mtime: Double) {
        self.file = file
        self.sha256 = sha256
        self.bytes = bytes
        self.mtime = mtime
    }
}
