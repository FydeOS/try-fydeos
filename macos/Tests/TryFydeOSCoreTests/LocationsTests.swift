import Foundation
import Testing
@testable import TryFydeOSCore

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}

@Test func bundleResourcesWinOverRepoLayout() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // A repo checkout around the bundle must not be picked when running from the bundle.
    try touch(root.appendingPathComponent("runtime/lock.json"))
    try touch(root.appendingPathComponent("factory/arm64-vmware-io.json"))
    let contents = root.appendingPathComponent("dist/Try FydeOS.app/Contents")
    let exe = contents.appendingPathComponent("MacOS/TryFydeOS")
    try touch(exe)
    try touch(contents.appendingPathComponent("Resources/factory/spec.json"))
    let loc = try Locations.discover(environment: [:], executable: exe)
    let resources = contents.appendingPathComponent("Resources").resolvingSymlinksInPath().path
    #expect(loc.bundleResources?.path == resources)
    #expect(loc.root == nil)
    #expect(loc.qemu.path == resources + "/runtime/bin/qemu-system-aarch64")
    #expect(loc.firmwareCode.path == resources + "/firmware/edk2-aarch64-code.fd")
    #expect(loc.factorySpec.path == resources + "/factory/spec.json")
    #expect(loc.images == imagesDir)
}

@Test func repoLayoutWithoutBundleAndEnvironmentOverrides() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try touch(root.appendingPathComponent("runtime/lock.json"))
    try touch(root.appendingPathComponent("factory/arm64-vmware-io.json"))
    let exe = root.appendingPathComponent("macos/.build/release/tryfydeos")
    try touch(exe)
    let loc = try Locations.discover(environment: [:], executable: exe)
    #expect(loc.bundleResources == nil)
    #expect(loc.runtime.path.hasSuffix("/out/runtime/current/runtime"))
    let overridden = try Locations.discover(environment: ["TRY_FYDEOS_RUNTIME": "/opt/rt", "TRY_FYDEOS_FIRMWARE": "/opt/fw"], executable: exe)
    #expect(overridden.runtime.path == "/opt/rt")
    #expect(overridden.firmware.path == "/opt/fw")
}

final class Listing: @unchecked Sendable {
    private let lock = NSLock()
    private var body: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return body }
        set { lock.lock(); body = newValue; lock.unlock() }
    }
}

@Test func factoryContainerChoosesImage() async throws {
    let (pinned, pinnedSum) = testContent()
    let listing = Listing()
    let server = try HTTPTestServer { request in
        if request.path == "/api" {
            guard let body = listing.value else { return HTTPResponse(status: 503) }
            return HTTPResponse(status: 200, body: Data(body.utf8))
        }
        return request.path == "/v1/pinned.zip" ? .ranged(pinned, request) : HTTPResponse(status: 404)
    }
    defer { server.stop() }
    func list(_ sum: String, _ file: String) -> String {
        #"{"list":[{"board":"b","version":"9.9","releaseDate":"2026-12-01","fileName":"\#(file)","checksum":"\#(sum)","#
            + #""isEOL":false,"downloadUrls":[{"type":"official","url":"https://127.0.0.1:1/v2/\#(file)"}]}]}"#
    }
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let spec = testSpec(url: server.baseURL + "/v1/pinned.zip", bytes: Int64(pinned.count), sha256: pinnedSum, api: server.baseURL + "/api")
    var loc = Locations(root: nil, bundleResources: nil, runtime: root, firmware: root, factorySpec: root, factoryImageOverride: nil,
                        images: root.appendingPathComponent("images"), appVersion: "1")
    let pinnedFile = loc.images.appendingPathComponent("pinned.zip")
    let want = FactoryRecord(url: spec.image.url, fileName: "pinned.zip", sha256: pinnedSum, version: "v")
    func downloads() -> Int { server.requests.filter { $0.path == "/v1/pinned.zip" }.count }

    var lines: [String] = []
    var (path, record) = try await loc.factoryContainer(spec: spec, say: { lines.append($0) })
    #expect(path == pinnedFile && record == want && downloads() == 1)
    #expect(lines.first?.hasPrefix("release API: ") == true && lines.first?.hasSuffix("using the pinned image") == true)
    #expect(try Data(contentsOf: pinnedFile) == pinned)

    listing.value = list(pinnedSum, "pinned.zip")
    lines = []
    (path, record) = try await loc.factoryContainer(spec: spec, say: { lines.append($0) })
    #expect(path == pinnedFile && record == want && downloads() == 1)
    #expect(lines == ["release API lists the pinned image pinned.zip", "using the downloaded image \(pinnedFile.path)"])

    listing.value = list(String(repeating: "b", count: 64), "newer.zip")
    lines = []
    (path, record) = try await loc.factoryContainer(spec: spec, say: { lines.append($0) })
    #expect(path == pinnedFile && record == want && downloads() == 1)
    #expect(lines.first?.contains("newer.zip 9.9 (2026-12-01), but its size is unknown") == true)

    loc.factoryImageOverride = vmdkFixture("test.ova")
    (path, record) = try await loc.factoryContainer(spec: spec, say: { _ in })
    #expect(path == vmdkFixture("test.ova") && record == FactoryRecord(fileName: "test.ova"))
    loc.factoryImageOverride = root.appendingPathComponent("missing.ova")
    await #expect(throws: ConfigError.self) { try await loc.factoryContainer(spec: spec, say: { _ in }) }
}

@Test func factoryContainerKeepsOnlyTheChosenImage() async throws {
    let (pinned, pinnedSum) = testContent()
    let server = try HTTPTestServer { request in
        request.path == "/v1/pinned.zip" ? .ranged(pinned, request) : HTTPResponse(status: 503)
    }
    defer { server.stop() }
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let spec = testSpec(url: server.baseURL + "/v1/pinned.zip", bytes: Int64(pinned.count), sha256: pinnedSum, api: server.baseURL + "/api")
    var loc = Locations(root: nil, bundleResources: nil, runtime: root, firmware: root, factorySpec: root, factoryImageOverride: nil,
                        images: root.appendingPathComponent("images"), appVersion: "1")
    let fm = FileManager.default
    let images = loc.images
    func entries() throws -> [String] { try fm.contentsOfDirectory(atPath: images.path).sorted() }
    func downloads() -> Int { server.requests.filter { $0.path == "/v1/pinned.zip" }.count }
    let pinnedFile = images.appendingPathComponent("pinned.zip")
    try fm.createDirectory(at: images.appendingPathComponent("keep.d"), withIntermediateDirectories: true)
    try touch(images.appendingPathComponent("old.ova"))
    try touch(images.appendingPathComponent("other.zip.part"))
    try pinned.write(to: pinnedFile)

    var lines: [String] = []
    var (path, _) = try await loc.factoryContainer(spec: spec, say: { lines.append($0) })
    #expect(path == pinnedFile && downloads() == 0)
    #expect(try entries() == ["keep.d", "pinned.zip"])
    #expect(lines.contains("removed superseded image old.ova") && lines.contains("removed superseded image other.zip.part"))

    try fm.removeItem(at: pinnedFile)
    try touch(images.appendingPathComponent("old.ova"))
    lines = []
    (path, _) = try await loc.factoryContainer(spec: spec, say: { lines.append($0) })
    #expect(path == pinnedFile && downloads() == 1)
    #expect(try entries() == ["keep.d", "pinned.zip"])
    #expect(try Data(contentsOf: pinnedFile) == pinned)
    #expect(lines.last == "removed superseded image old.ova")

    try touch(images.appendingPathComponent("stray.ova"))
    loc.factoryImageOverride = vmdkFixture("test.ova")
    (path, _) = try await loc.factoryContainer(spec: spec, say: { _ in })
    #expect(path == vmdkFixture("test.ova"))
    #expect(try entries() == ["keep.d", "pinned.zip", "stray.ova"])
}

@Test func qemuAcceptsEitherBinaryName() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var loc = Locations(root: nil, bundleResources: nil, runtime: root, firmware: root, factorySpec: root, factoryImageOverride: nil)
    #expect(loc.qemu.lastPathComponent == "qemu-system-aarch64")
    for name in ["qemu-system-aarch64", "Try FydeOS"] {
        let url = root.appendingPathComponent("bin/\(name)")
        try touch(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        #expect(loc.qemu == url)
    }
    loc.runtime = root.appendingPathComponent("none")
    #expect(loc.qemu.lastPathComponent == "qemu-system-aarch64")
}
