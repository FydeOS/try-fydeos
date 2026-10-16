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

@Test func prepareClonesAndResetKeepsRuns() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("factory.bin")
    let vars = root.appendingPathComponent("vars.fd")
    try Data(repeating: 7, count: 1 << 20).write(to: image)
    try Data(repeating: 0, count: 4096).write(to: vars)
    let digest = try FactorySpec.sha256(of: image)
    let spec = try JSONDecoder().decode(FactorySpec.self, from: Data("""
        {"schema": 1, "board": "b", "image": {"file": "factory.bin", "bytes": \(1 << 20), "sha256": "\(digest)", "version": "v"}}
        """.utf8))
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    var hashed = 0
    let metadata = try ws.prepare(lock: lock, spec: spec, image: image, varsTemplate: vars) { hashed += 1 }
    #expect(hashed == 1)
    #expect(ws.isPrepared)
    #expect(metadata.factory.sha256 == digest)
    #expect(ws.loadMetadata() == metadata)
    #expect(try Data(contentsOf: ws.disk) == Data(contentsOf: image))
    let again = try ws.prepare(lock: lock, spec: spec, image: image, varsTemplate: vars) { hashed += 1 }
    #expect(again == metadata)
    #expect(hashed == 1)
    #expect(try spec.verify(imageAt: image, known: metadata.factory) { hashed += 1 } == metadata.factory)
    #expect(hashed == 1)

    let run = try ws.newRunDirectory()
    #expect(ws.lastRun.resolvingSymlinksInPath().path == run.url.resolvingSymlinksInPath().path)
    try ws.reset(lock: lock)
    #expect(!ws.isPrepared)
    #expect(FileManager.default.fileExists(atPath: run.url.path))
    #expect(ws.state == .marked)
    #expect(FileManager.default.fileExists(atPath: ws.lockFile.path))
}

@Test func factorySizeMismatchFailsWithoutHashing() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("factory.bin")
    try Data(repeating: 1, count: 100).write(to: image)
    let spec = try JSONDecoder().decode(FactorySpec.self, from: Data("""
        {"schema": 1, "board": "b", "image": {"file": "factory.bin", "bytes": 101, "sha256": "\(String(repeating: "0", count: 64))", "version": "v"}}
        """.utf8))
    var hashed = false
    #expect(throws: ConfigError.self) { try spec.verify(imageAt: image) { hashed = true } }
    #expect(!hashed)
}

@Test func repoFactorySpecLoads() throws {
    let spec = try FactorySpec.load(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../factory/spec.json").standardizedFileURL)
    #expect(spec.board == "arm64-vmware-io")
    #expect(spec.image.bytes == 7482718720)
}
