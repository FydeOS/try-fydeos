import CryptoKit
import Foundation

public struct FactorySpec: Decodable, Sendable {
    /// The pinned download a new VM is converted from when the release API offers nothing else.
    public struct Image: Decodable, Sendable {
        public var url: String
        public var bytes: Int64
        public var sha256: String
        public var version: String
    }

    /// Where the latest published image of the board is listed.
    public struct ReleaseSource: Decodable, Sendable {
        public var api: String
        public var board: String
    }

    public var schema: Int
    public var image: Image
    public var release: ReleaseSource
    public var diskBytes: Int64
    public var board: String

    public static func load(_ url: URL) throws -> FactorySpec {
        let spec = try JSONDecoder().decode(FactorySpec.self, from: Data(contentsOf: url))
        guard spec.schema == 2 else { throw ConfigError.invalid("unsupported factory spec schema \(spec.schema)") }
        guard (try? urlFileName(spec.image.url)) != nil, isHTTPS(spec.image.url), spec.image.bytes > 0,
              isSHA256(spec.image.sha256), isHTTPS(spec.release.api), !spec.release.board.isEmpty, spec.diskBytes > 0 else {
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

func isSHA256(_ s: String) -> Bool {
    s.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
}

func isHTTPS(_ s: String) -> Bool {
    guard let u = URLComponents(string: s) else { return false }
    return u.scheme == "https" && !(u.host ?? "").isEmpty
}

/// The last path element of an image URL, the name it is stored under.
func urlFileName(_ s: String) throws -> String {
    guard let u = URLComponents(string: s) else { throw ConfigError.invalid("\(s) is not a URL") }
    let name = (u.path as NSString).lastPathComponent
    guard !name.isEmpty, name != ".", name != "/", !name.contains("\\"), !name.contains(":") else {
        throw ConfigError.invalid("\(s) names no file")
    }
    return name
}

/// The image a workspace was converted from; `rawBytes` is the length of the FydeOS image inside its disk.
/// Fields missing from older metadata decode as empty.
public struct FactoryRecord: Codable, Equatable, Sendable {
    public var url: String
    public var fileName: String
    public var sha256: String
    public var version: String
    public var rawBytes: Int64

    public init(url: String = "", fileName: String, sha256: String = "", version: String = "", rawBytes: Int64 = 0) {
        self.url = url
        self.fileName = fileName
        self.sha256 = sha256
        self.version = version
        self.rawBytes = rawBytes
    }

    enum CodingKeys: String, CodingKey { case url, fileName, sha256, version, rawBytes, file }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? c.decodeIfPresent(String.self, forKey: .file) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        rawBytes = try c.decodeIfPresent(Int64.self, forKey: .rawBytes) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(version, forKey: .version)
        try c.encode(rawBytes, forKey: .rawBytes)
    }
}
