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

let testZstd: URL? = [
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../out/runtime/current/runtime/bin/zstd").standardizedFileURL,
    URL(fileURLWithPath: "/opt/homebrew/bin/zstd"), URL(fileURLWithPath: "/usr/local/bin/zstd"),
].first { FileManager.default.isExecutableFile(atPath: $0.path) }

private let rawImage = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

private func compressedImage(in dir: URL, name: String = "img.bin.zst") throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let raw = dir.appendingPathComponent("raw.bin")
    try rawImage.write(to: raw)
    let image = dir.appendingPathComponent(name)
    let p = Process()
    p.executableURL = testZstd!
    p.arguments = ["-q", "-f", "-o", image.path, raw.path]
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    try FileManager.default.removeItem(at: raw)
    return image
}

private func testSpec(file: String = "img.bin.zst", rawBytes: Int64 = Int64(rawImage.count), diskBytes: Int64 = 64 << 20) throws -> FactorySpec {
    let zero = String(repeating: "0", count: 64)
    return try JSONDecoder().decode(FactorySpec.self, from: Data("""
        {"schema": 1, "board": "b", "diskBytes": \(diskBytes), "image": {"file": "\(file)", "bytes": 1, "sha256": "\(zero)",
         "rawBytes": \(rawBytes), "rawSha256": "\(zero)", "version": "v"}}
        """.utf8))
}

private func varsTemplate(in root: URL) throws -> URL {
    let vars = root.appendingPathComponent("vars.fd")
    try Data(repeating: 0, count: 4096).write(to: vars)
    return vars
}

@Test(.enabled(if: testZstd != nil))
func prepareUnpacksSparseDiskAndResetKeepsRuns() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = try compressedImage(in: root)
    let vars = try varsTemplate(in: root)
    let spec = try testSpec()
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    var reports: [(Int64, Int64)] = []
    let metadata = try ws.prepare(lock: lock, spec: spec, image: image, zstd: testZstd!, varsTemplate: vars) { reports.append(($0, $1)) }
    let n = Int64(rawImage.count)
    #expect(reports.first.map { [$0.0, $0.1] } == [0, n])
    #expect(reports.last.map { [$0.0, $0.1] } == [n, n])
    #expect(ws.isPrepared)
    #expect(!FileManager.default.fileExists(atPath: ws.stagingDisk.path))
    #expect(metadata.factory == FactoryRecord(file: "img.bin.zst", sha256: spec.image.sha256, rawBytes: Int64(rawImage.count)))
    #expect(metadata.diskBytes == 64 << 20)
    #expect(ws.loadMetadata() == metadata)
    let attrs = try FileManager.default.attributesOfItem(atPath: ws.disk.path)
    #expect((attrs[.size] as? NSNumber)?.int64Value == 64 << 20)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let disk = try FileHandle(forReadingFrom: ws.disk)
    defer { try? disk.close() }
    #expect(try disk.read(upToCount: rawImage.count) == rawImage)
    #expect(try disk.read(upToCount: 4096) == Data(count: 4096))
    var again = false
    #expect(try ws.prepare(lock: lock, spec: spec, image: image, zstd: testZstd!, varsTemplate: vars) { _, _ in again = true } == metadata)
    #expect(!again)

    let run = try ws.newRunDirectory()
    #expect(ws.lastRun.resolvingSymlinksInPath().path == run.url.resolvingSymlinksInPath().path)
    try ws.reset(lock: lock)
    #expect(!ws.isPrepared)
    #expect(FileManager.default.fileExists(atPath: run.url.path))
    #expect(ws.state == .marked)
    #expect(FileManager.default.fileExists(atPath: ws.lockFile.path))
    _ = try ws.prepare(lock: lock, spec: spec, image: image, zstd: testZstd!, varsTemplate: vars)
    #expect(ws.isPrepared)
}

@Test(.enabled(if: testZstd != nil))
func prepareRejectsWrongRawSizeAndCorruptImage() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = try compressedImage(in: root)
    let vars = try varsTemplate(in: root)
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    #expect(throws: ConfigError.self) {
        try ws.prepare(lock: lock, spec: try testSpec(rawBytes: Int64(rawImage.count) + 1), image: image, zstd: testZstd!, varsTemplate: vars)
    }
    let data = try Data(contentsOf: image)
    try data.prefix(data.count / 2).write(to: image)
    #expect(throws: ConfigError.self) {
        try ws.prepare(lock: lock, spec: try testSpec(), image: image, zstd: testZstd!, varsTemplate: vars)
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
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    let spec = try testSpec(rawBytes: 1 << 50, diskBytes: 1 << 50)
    do {
        _ = try ws.prepare(lock: lock, spec: spec, image: root.appendingPathComponent("img.bin.zst"),
                           zstd: URL(fileURLWithPath: "/nonexistent"), varsTemplate: vars)
        Issue.record("prepare succeeded without free space")
    } catch let error as WorkspaceError {
        #expect("\(error)".hasPrefix("not enough free space: "))
    }
    #expect(!FileManager.default.fileExists(atPath: ws.efiVars.path))
}

@Test(.enabled(if: testZstd != nil))
func prepareFindsImageThroughLocations() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let fw = root.appendingPathComponent("fw")
    try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 4096).write(to: fw.appendingPathComponent("edk2-arm-vars.fd"))
    let runtime = root.appendingPathComponent("rt")
    try FileManager.default.createDirectory(at: runtime.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: runtime.appendingPathComponent("bin/zstd"), withDestinationURL: testZstd!)
    let zero = String(repeating: "0", count: 64)
    let specFile = root.appendingPathComponent("spec.json")
    try JSONSerialization.data(withJSONObject: ["schema": 1, "board": "b", "diskBytes": 64 << 20, "image": [
        "file": "img.bin.zst", "bytes": 1, "sha256": zero, "rawBytes": rawImage.count, "rawSha256": zero, "version": "v"]]).write(to: specFile)
    let loc = Locations(root: root, bundleResources: nil, runtime: runtime, firmware: fw, factorySpec: specFile, factoryImageOverride: nil)
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    #expect(throws: ConfigError.self) { try ws.prepare(lock: lock, locations: loc) }
    #expect(!ws.isPrepared)
    _ = try compressedImage(in: root.appendingPathComponent("factory"))
    let metadata = try ws.prepare(lock: lock, locations: loc)
    #expect(metadata.factory.rawBytes == Int64(rawImage.count))
    #expect(ws.isPrepared)
}

@Test func repoFactorySpecLoads() throws {
    let spec = try FactorySpec.load(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../factory/spec.json").standardizedFileURL)
    #expect(spec.board == "arm64-vmware-io")
    #expect(spec.image.rawBytes == 7482718720)
    #expect(spec.diskBytes == 64 << 30)
}
