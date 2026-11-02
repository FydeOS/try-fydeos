import CryptoKit
import Foundation
import Testing
@testable import TryFydeOSCore

func testContent() -> (Data, String) {
    let data = Data(String(repeating: "FydeOS image ", count: 400_000).utf8)
    return (data, hex(SHA256.hash(data: data)))
}

/// Serves `data` with Range support; `abortFirst` cuts the first answer after half the bytes,
/// `ignoreRange` answers every request in full.
func imageServer(_ data: Data, abortFirst: Bool = false, ignoreRange: Bool = false) throws -> HTTPTestServer {
    let first = FirstFlag()
    return try HTTPTestServer { request in
        if abortFirst, first.take() {
            return HTTPResponse(status: 200, body: data, cutAfter: data.count / 2)
        }
        return .ranged(data, request, ignoreRange: ignoreRange)
    }
}

final class FirstFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { taken = true }
        return !taken
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int64, Int64)] = []
    func add(_ done: Int64, _ total: Int64) { lock.lock(); entries.append((done, total)); lock.unlock() }
    var all: [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return entries }
}

func checkDownloaded(_ dest: URL, _ data: Data) throws {
    #expect(try Data(contentsOf: dest) == data)
    #expect(!FileManager.default.fileExists(atPath: dest.path + ".part"))
}

func fileSize(_ url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
}

@Test func downloadFull() async throws {
    let (data, sum) = testContent()
    let server = try imageServer(data)
    defer { server.stop() }
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dest = root.appendingPathComponent("images/image.zip")
    let log = ProgressLog()
    try await download(url: server.baseURL + "/image.zip", size: Int64(data.count), sha256: sum, to: dest, progress: log.add)
    try checkDownloaded(dest, data)
    let n = Int64(data.count)
    #expect((2...102).contains(log.all.count))
    #expect(log.all.last.map { [$0.0, $0.1] } == [n, n])
    #expect(try await remoteSize(url: server.baseURL + "/image.zip") == n)
    #expect(server.requests.last?.headers["range"] == "bytes=0-0")
}

@Test func downloadResumesAfterACut() async throws {
    let (data, sum) = testContent()
    let server = try imageServer(data, abortFirst: true)
    defer { server.stop() }
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dest = root.appendingPathComponent("image.zip")
    await #expect(throws: ConfigError.self) {
        try await download(url: server.baseURL + "/image.zip", size: Int64(data.count), sha256: sum, to: dest)
    }
    let part = fileSize(URL(fileURLWithPath: dest.path + ".part")) ?? 0
    #expect(part > 0 && part < Int64(data.count))
    try await download(url: server.baseURL + "/image.zip", size: Int64(data.count), sha256: sum, to: dest)
    try checkDownloaded(dest, data)
    #expect(server.requests.count == 2 && server.requests[1].headers["range"] == "bytes=\(part)-")
}

@Test func downloadWithACompletePart() async throws {
    let (data, sum) = testContent()
    let server = try imageServer(data)
    defer { server.stop() }
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dest = root.appendingPathComponent("image.zip")
    try data.write(to: URL(fileURLWithPath: dest.path + ".part"))
    try await download(url: server.baseURL + "/image.zip", size: Int64(data.count), sha256: sum, to: dest)
    try checkDownloaded(dest, data)
    #expect(server.requests.first?.headers["range"] == "bytes=\(data.count)-")
}

@Test func downloadFromAServerIgnoringRange() async throws {
    let (data, sum) = testContent()
    let server = try imageServer(data, ignoreRange: true)
    defer { server.stop() }
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dest = root.appendingPathComponent("image.zip")
    try Data(repeating: UInt8(ascii: "x"), count: 1000).write(to: URL(fileURLWithPath: dest.path + ".part"))
    try await download(url: server.baseURL + "/image.zip", size: Int64(data.count), sha256: sum, to: dest)
    try checkDownloaded(dest, data)
    #expect(server.requests.first?.headers["range"] == "bytes=1000-")
}

@Test func downloadHashMismatch() async throws {
    let (data, _) = testContent()
    let server = try imageServer(data)
    defer { server.stop() }
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dest = root.appendingPathComponent("image.zip")
    let url = server.baseURL + "/image.zip"
    let zero = String(repeating: "0", count: 64)
    do {
        try await download(url: url, size: Int64(data.count), sha256: zero, to: dest)
        Issue.record("hash mismatch accepted")
    } catch {
        #expect("\(error)".contains(url) && "\(error)".contains("sha256"))
    }
    #expect(!FileManager.default.fileExists(atPath: dest.path))
    #expect(!FileManager.default.fileExists(atPath: dest.path + ".part"))
    await #expect(throws: ConfigError.self) { try await download(url: url, size: Int64(data.count) + 1, sha256: zero, to: dest) }
}
