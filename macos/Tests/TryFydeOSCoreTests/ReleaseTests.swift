import Foundation
import Testing
@testable import TryFydeOSCore

func releaseFixture() throws -> String {
    try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../windows/internal/core/testdata/downloads.json").standardizedFileURL, encoding: .utf8)
}

func serve(_ body: String, status: Int = 200) throws -> HTTPTestServer {
    try HTTPTestServer { _ in HTTPResponse(status: status, body: Data(body.utf8)) }
}

@Test func fetchReleaseParsesTheBoardsEntry() async throws {
    let server = try serve(try releaseFixture())
    defer { server.stop() }
    let r = try await fetchRelease(api: server.baseURL + "/api/downloads?l=en", board: "arm64-vmware", appVersion: "1.2.3")
    #expect(r == Release(version: "23.1", releaseDate: "2026-10-30", fileName: "FydeOS-VMWare-v23.1-Preview1-arm64-io.zip",
                         sha256: "97ab06aeaeecd3b4f4271059668e8c0329192d27b794ccb28e5e028b81704887",
                         url: "https://download.fydeos.io/v23.1/FydeOS-VMWare-v23.1-Preview1-arm64-io.zip"))
    #expect(server.requests.first?.headers["user-agent"] == "Try FydeOS/1.2.3")
    #expect(server.requests.first?.path == "/api/downloads?l=en")
}

@Test func fetchReleaseErrors() async throws {
    let fixture = try releaseFixture()
    let cases: [(String, String, String, String)] = [
        ("board missing", fixture, "nope", "lists no nope image"),
        ("end of life", fixture, "surface-pro3", "end of life"),
        ("malformed JSON", #"{"list": ["#, "amd64-vmware", "malformed JSON"),
        ("malformed checksum", fixture.replacingOccurrences(of: "57062f6e", with: "57062f6g"), "amd64-vmware", "malformed checksum"),
        ("no official url", fixture.replacingOccurrences(of: #""type": "official""#, with: #""type": "mirror""#), "amd64-vmware",
         "no official download"),
        ("file name mismatch", fixture.replacingOccurrences(of: #""fileName": "FydeOS-VMWare-v23.1-Preview1-x86_64-io.ova""#,
                                                            with: #""fileName": "other.ova""#), "amd64-vmware", "malformed download"),
    ]
    for (name, body, board, want) in cases {
        let server = try serve(body)
        defer { server.stop() }
        do {
            _ = try await fetchRelease(api: server.baseURL, board: board, appVersion: "1")
            Issue.record("\(name): no error")
        } catch {
            #expect("\(error)".contains(want), "\(name): \(error)")
        }
    }

    let missing = try serve("no", status: 404)
    defer { missing.stop() }
    do {
        _ = try await fetchRelease(api: missing.baseURL, board: "amd64-vmware", appVersion: "1")
        Issue.record("not found: no error")
    } catch {
        #expect("\(error)".contains("404"))
    }

    let closed = try serve("")
    let closedURL = closed.baseURL
    closed.stop()
    await #expect(throws: ConfigError.self) { try await fetchRelease(api: closedURL, board: "amd64-vmware", appVersion: "1") }

    let hanging = try HTTPTestServer { _ in HTTPResponse(status: 200, body: Data("{}".utf8), delay: 3) }
    defer { hanging.stop() }
    let start = Date()
    await #expect(throws: ConfigError.self) {
        try await fetchRelease(api: hanging.baseURL, board: "amd64-vmware", appVersion: "1", timeout: 0.3)
    }
    #expect(Date().timeIntervalSince(start) < 2)
}
