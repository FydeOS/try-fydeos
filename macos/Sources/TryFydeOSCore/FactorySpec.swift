import CryptoKit
import Foundation

public struct FactorySpec: Decodable, Sendable {
    public struct Image: Decodable, Sendable {
        public var file: String
        public var bytes: Int64
        public var sha256: String
        public var rawBytes: Int64
        public var rawSha256: String
        public var version: String
    }

    public var schema: Int
    public var image: Image
    public var diskBytes: Int64
    public var board: String

    public static func load(_ url: URL) throws -> FactorySpec {
        let spec = try JSONDecoder().decode(FactorySpec.self, from: Data(contentsOf: url))
        guard spec.schema == 1 else { throw ConfigError.invalid("unsupported factory spec schema \(spec.schema)") }
        let hex = "^[0-9a-f]{64}$"
        guard spec.image.sha256.range(of: hex, options: .regularExpression) != nil,
              spec.image.rawSha256.range(of: hex, options: .regularExpression) != nil,
              !spec.image.file.contains("/"), spec.image.bytes > 0, spec.image.rawBytes > 0,
              spec.diskBytes >= spec.image.rawBytes else {
            throw ConfigError.invalid("malformed factory spec: \(url.path)")
        }
        return spec
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The factory image a workspace was unpacked from; `rawBytes` is nil in workspaces cloned from a raw image.
public struct FactoryRecord: Codable, Equatable, Sendable {
    public var file: String
    public var sha256: String
    public var rawBytes: Int64?

    public init(file: String, sha256: String, rawBytes: Int64?) {
        self.file = file
        self.sha256 = sha256
        self.rawBytes = rawBytes
    }
}
