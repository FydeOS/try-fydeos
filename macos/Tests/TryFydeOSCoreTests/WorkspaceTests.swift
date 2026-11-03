import CryptoKit
import Foundation
import Testing
@testable import TryFydeOSCore

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tfo-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func newWorkspaceGetsMarkerAndLock() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let ws = Workspace(url: root.appendingPathComponent("VM/v1"))
    #expect(ws.state == .absent)
    let lock = try ws.open()
    defer { lock.release() }
    #expect(ws.state == .marked)
    #expect(try String(contentsOf: ws.marker, encoding: .utf8) == Workspace.markerContent)
    #expect(ws.isLocked)
    #expect(!ws.isPrepared)
}

@Test func unmarkedNonEmptyDirectoryIsRefused() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appendingPathComponent("disk.img"))
    let ws = Workspace(url: root)
    #expect(throws: WorkspaceError.self) { try ws.open() }
    #expect(!FileManager.default.fileExists(atPath: ws.lockFile.path))
    #expect(!FileManager.default.fileExists(atPath: ws.marker.path))
}

@Test func foreignMarkerIsRefused() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("try-fydeos-vm 2\n".utf8).write(to: root.appendingPathComponent(".try-fydeos"))
    #expect(throws: WorkspaceError.self) { try Workspace(url: root).open() }
}

@Test func lockIsExclusiveAcrossOpens() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent(".lock").path
    let first = try StorageLock(path: path)
    #expect(throws: LockError.self) { try StorageLock(path: path) }
    #expect(StorageLock.isHeld(path: path))
    #expect(fcntl(first.fd, F_GETFD) & FD_CLOEXEC == 0)
    first.release()
    #expect(!StorageLock.isHeld(path: path))
    let second = try StorageLock(path: path)
    second.release()
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func lockRefusesSymlink() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    try Data().write(to: target)
    let link = root.appendingPathComponent(".lock")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: LockError.self) { try StorageLock(path: link.path) }
}

func testSpec(diskBytes: Int64 = 64 << 20, url: String = "https://example.invalid/v1/pinned.zip", bytes: Int64 = 1,
              sha256: String = String(repeating: "0", count: 64), api: String = "https://example.invalid/api") -> FactorySpec {
    FactorySpec(schema: 2, image: .init(url: url, bytes: bytes, sha256: sha256, version: "v"),
                release: .init(api: api, board: "b"), diskBytes: diskBytes, board: "b")
}

private func varsTemplate(in root: URL) throws -> URL {
    let vars = root.appendingPathComponent("vars.fd")
    try Data(repeating: 0, count: 4096).write(to: vars)
    return vars
}

/// The fixture image: 8 MiB - 32 KiB up to the GPT's alternate header.
let fixtureImageBytes: Int64 = 8 * 1024 * 1024 - 32768

func sha256(of url: URL, prefix: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return hex(SHA256.hash(data: try handle.read(upToCount: prefix) ?? Data()))
}

@Test func prepareConvertsBothContainersAndResetKeepsRuns() throws {
    for name in ["test.ova", "test.zip"] {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vars = try varsTemplate(in: root)
        let spec = testSpec()
        let ws = Workspace(url: root.appendingPathComponent("vm"))
        let lock = try ws.open(requireAPFS: false)
        defer { lock.release() }
        let record = FactoryRecord(url: "u", fileName: name, sha256: "s", version: "v")
        var reports: [(Int64, Int64)] = []
        let metadata = try ws.prepare(lock: lock, spec: spec, container: vmdkFixture(name), record: record, varsTemplate: vars) {
            reports.append(($0, $1))
        }
        #expect(reports.count >= 2 && reports.last.map { $0.0 == $0.1 && $0.1 > 0 } == true)
        #expect(ws.isPrepared)
        #expect(!FileManager.default.fileExists(atPath: ws.stagingDisk.path))
        var want = record
        want.rawBytes = fixtureImageBytes
        #expect(metadata.factory == want)
        #expect(metadata.diskBytes == 64 << 20)
        #expect(ws.loadMetadata() == metadata)
        let attrs = try FileManager.default.attributesOfItem(atPath: ws.disk.path)
        #expect((attrs[.size] as? NSNumber)?.int64Value == 64 << 20)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try sha256(of: ws.disk, prefix: fixtureBytes) == (try goldenRawSha256()), "\(name)")
        var again = false
        #expect(try ws.prepare(lock: lock, spec: spec, container: vmdkFixture(name), record: record, varsTemplate: vars) { _, _ in again = true } == metadata)
        #expect(!again)

        let run = try ws.newRunDirectory()
        #expect(ws.lastRun.resolvingSymlinksInPath().path == run.url.resolvingSymlinksInPath().path)
        try ws.reset(lock: lock)
        #expect(!ws.isPrepared)
        #expect(FileManager.default.fileExists(atPath: run.url.path))
        #expect(ws.state == .marked)
        #expect(FileManager.default.fileExists(atPath: ws.lockFile.path))
        _ = try ws.prepare(lock: lock, spec: spec, container: vmdkFixture(name), record: record, varsTemplate: vars)
        #expect(ws.isPrepared)
    }
}

@Test func prepareRejectsForeignAndBrokenImages() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let vars = try varsTemplate(in: root)
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    let record = FactoryRecord(fileName: "x")
    do {
        _ = try ws.prepare(lock: lock, spec: testSpec(), container: vmdkFixture("beyond.ova"), record: record, varsTemplate: vars)
        Issue.record("beyond.ova accepted")
    } catch {
        #expect("\(error)".contains("foreign image: data beyond the GPT"))
    }
    do {
        _ = try ws.prepare(lock: lock, spec: testSpec(diskBytes: 4 << 20), container: vmdkFixture("test.ova"), record: record, varsTemplate: vars)
        Issue.record("image larger than the VM disk accepted")
    } catch {
        #expect("\(error)".contains("more than the"))
    }
    let truncated = root.appendingPathComponent("cut.ova")
    let ova = try Data(contentsOf: vmdkFixture("test.ova"))
    try ova.prefix(ova.count / 2).write(to: truncated)
    #expect(throws: (any Error).self) {
        try ws.prepare(lock: lock, spec: testSpec(), container: truncated, record: record, varsTemplate: vars)
    }
    #expect(!ws.isPrepared)
    #expect(!FileManager.default.fileExists(atPath: ws.disk.path))
    #expect(!FileManager.default.fileExists(atPath: ws.stagingDisk.path))
}

@Test func prepareRefusesWithoutFreeSpace() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let vars = try varsTemplate(in: root)
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    ws.workReserve = 1 << 60
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    do {
        _ = try ws.prepare(lock: lock, spec: testSpec(), container: vmdkFixture("test.ova"), record: FactoryRecord(fileName: "x"),
                           varsTemplate: vars)
        Issue.record("prepare succeeded without free space")
    } catch let error as WorkspaceError {
        #expect("\(error)".hasPrefix("not enough free space: "))
    }
    #expect(!FileManager.default.fileExists(atPath: ws.efiVars.path))
}

@Test func prepareTakesTheOverrideThroughLocations() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let fw = root.appendingPathComponent("fw")
    try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 4096).write(to: fw.appendingPathComponent("edk2-arm-vars.fd"))
    let zero = String(repeating: "0", count: 64)
    let specFile = root.appendingPathComponent("spec.json")
    try JSONSerialization.data(withJSONObject: [
        "schema": 2, "board": "b", "diskBytes": 64 << 20,
        "image": ["url": "https://example.invalid/pinned.zip", "bytes": 1, "sha256": zero, "version": "v"],
        "release": ["api": "https://example.invalid/api", "board": "b"],
    ]).write(to: specFile)
    var loc = Locations(root: root, bundleResources: nil, runtime: root, firmware: fw, factorySpec: specFile,
                        factoryImageOverride: root.appendingPathComponent("missing.zip"), images: root.appendingPathComponent("images"))
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    #expect(throws: ConfigError.self) { try ws.prepare(lock: lock, locations: loc) }
    #expect(!ws.isPrepared)
    loc.factoryImageOverride = vmdkFixture("test.zip")
    var lines: [String] = []
    var stages: [PrepareStage] = []
    let metadata = try ws.prepare(lock: lock, locations: loc, say: { lines.append($0) }) { stage, _, _ in stages.append(stage) }
    #expect(metadata.factory == FactoryRecord(fileName: "test.zip", rawBytes: fixtureImageBytes))
    #expect(ws.isPrepared)
    #expect(Set(stages) == [.converting])
    #expect(lines.first == "using the local image \(vmdkFixture("test.zip").path)")
    #expect(lines.last?.hasPrefix("converted in ") == true)
    #expect(!FileManager.default.fileExists(atPath: loc.images.path))
}

@Test func legacyMetadataStillLoads() throws {
    let legacy = #"{"schema": 1, "factory": {"file": "img.bin.zst", "sha256": "abc", "rawBytes": null}, "mac": "52:54:00:12:34:56", "created": "x"}"#
    let m = try JSONDecoder().decode(Metadata.self, from: Data(legacy.utf8))
    #expect(m.factory == FactoryRecord(fileName: "img.bin.zst", sha256: "abc"))
}

@Test func factorySpecSchemaChecks() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zero = String(repeating: "0", count: 64)
    func load(_ image: [String: Any], schema: Int = 2, api: String = "https://example.invalid/api") throws -> FactorySpec {
        let url = root.appendingPathComponent("spec.json")
        try JSONSerialization.data(withJSONObject: ["schema": schema, "board": "b", "diskBytes": 1, "image": image,
                                                    "release": ["api": api, "board": "b"]]).write(to: url)
        return try FactorySpec.load(url)
    }
    let good: [String: Any] = ["url": "https://example.invalid/d/x.zip", "bytes": 1, "sha256": zero, "version": "v"]
    #expect(try load(good).image.url == "https://example.invalid/d/x.zip")
    #expect(throws: ConfigError.self) { try load(good, schema: 1) }
    #expect(throws: ConfigError.self) { try load(good, api: "http://example.invalid/api") }
    for (key, value) in [("url", "http://example.invalid/x.zip"), ("url", "https://example.invalid/"), ("sha256", "abc")] as [(String, Any)] {
        var bad = good
        bad[key] = value
        #expect(throws: ConfigError.self, "\(key)=\(value)") { try load(bad) }
    }
}

@Test func repoFactorySpecLoads() throws {
    let spec = try FactorySpec.load(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../factory/arm64-vmware-io.json").standardizedFileURL)
    #expect(spec.board == "arm64-vmware-io")
    #expect(spec.image.bytes == 1574658456)
    #expect(spec.release.board == "arm64-vmware")
    #expect(try urlFileName(spec.image.url) == "FydeOS-VMWare-v23.1-Preview1-arm64-io.zip")
    #expect(spec.diskBytes == 64 << 30)
}
