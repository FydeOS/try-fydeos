import Foundation
import Testing
@testable import TryFydeOSCore

private func fakeImage(in dir: URL, name: String = "fake.bin", count: Int = 3 << 20) throws -> (URL, FactorySpec) {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
    let spec = try JSONDecoder().decode(FactorySpec.self, from: Data("""
        {"schema": 1, "board": "b", "image": {"file": "\(name)", "bytes": \(count), "sha256": "\(try FactorySpec.sha256(of: url))", "version": "v-test"}}
        """.utf8))
    return (url, spec)
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
}

@Test func emptyStoreNamesImportImage() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, spec) = try fakeImage(in: root.appendingPathComponent("src"))
    let store = FactoryStore(directory: root.appendingPathComponent("store"), spec: spec)
    #expect(store.state == .empty)
    do {
        _ = try store.verifiedImage()
        Issue.record("verifiedImage succeeded on an empty store")
    } catch {
        #expect("\(error)".contains("tryfydeos import-image"))
    }
}

@Test(arguments: [true, false])
func importVerifiesAndRecords(allowClone: Bool) throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, spec) = try fakeImage(in: root.appendingPathComponent("src"))
    let store = FactoryStore(directory: root.appendingPathComponent("store"), spec: spec)
    var seen: [ImportProgress] = []
    let record = try store.importImage(from: source, allowClone: allowClone) { seen.append($0) }
    #expect(record.sha256 == spec.image.sha256 && record.bytes == spec.image.bytes && record.file == "fake.bin")
    #expect(store.state == .verified(record))
    #expect(try Data(contentsOf: store.image) == Data(contentsOf: source))
    let saved = try JSONDecoder().decode(FactoryRecord.self, from: Data(contentsOf: store.recordFile))
    #expect(saved == record)
    #expect(store.recordFile.lastPathComponent == "fake.bin.verified.json")
    #expect(!FileManager.default.fileExists(atPath: store.temporaryImage.path))
    #expect(seen.last?.fraction == 1)
    #expect(seen.last?.phase == (allowClone ? .verifying : .copying))
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.phase != $1.phase || $0.bytes <= $1.bytes })
    #expect(try store.verifiedImage().url == store.image)
}

@Test func digestMismatchLeavesStoreEmpty() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var (source, spec) = try fakeImage(in: root.appendingPathComponent("src"))
    spec.image.sha256 = String(repeating: "0", count: 64)
    let store = FactoryStore(directory: root.appendingPathComponent("store"), spec: spec)
    #expect(throws: ConfigError.self) { try store.importImage(from: source, allowClone: false) }
    #expect(store.state == .empty)
    #expect(!FileManager.default.fileExists(atPath: store.temporaryImage.path))
    #expect(!FileManager.default.fileExists(atPath: store.recordFile.path))
}

@Test func sizeMismatchFailsBeforeCopying() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var (source, spec) = try fakeImage(in: root.appendingPathComponent("src"))
    spec.image.bytes += 1
    let store = FactoryStore(directory: root.appendingPathComponent("store"), spec: spec)
    var progressed = false
    #expect(throws: ConfigError.self) { try store.importImage(from: source) { _ in progressed = true } }
    #expect(!progressed)
    #expect(store.state == .empty)
}

@Test func changedImageNeedsReimport() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, spec) = try fakeImage(in: root.appendingPathComponent("src"))
    let store = FactoryStore(directory: root.appendingPathComponent("store"), spec: spec)
    // A leftover from an interrupted import is replaced, not trusted.
    try touch(store.temporaryImage)
    try store.importImage(from: source)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: store.image.path)
    #expect(store.state == .unverified("changed since it was verified"))
    #expect(throws: FactoryStoreError.self) { try store.verifiedImage() }
    try FileManager.default.removeItem(at: store.recordFile)
    #expect(store.state == .unverified("not verified"))
    try store.importImage(from: source)
    guard case .verified = store.state else { Issue.record("not verified after re-import"); return }
}

@Test func importCandidatesInResolutionOrder() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, spec) = try fakeImage(in: root.appendingPathComponent("src"), name: "img.bin")
    // Repository layout.
    try touch(root.appendingPathComponent("repo/runtime/lock.json"))
    try touch(root.appendingPathComponent("repo/factory/spec.json"))
    let exe = root.appendingPathComponent("repo/macos/.build/release/tryfydeos")
    try touch(exe)
    let repo = try Locations.discover(environment: ["TRY_FYDEOS_FACTORY_IMAGE": "/env/img.bin"], executable: exe)
    #expect(repo.factoryImportCandidates(spec).map(\.path) == ["/env/img.bin", repo.root!.path + "/factory/img.bin"])
    #expect(repo.factoryStoreDirectory == FactoryStore.defaultDirectory)

    // DMG layout: the app beside FydeOS/<file>.
    let volume = root.appendingPathComponent("volume")
    let contents = volume.appendingPathComponent("Try FydeOS.app/Contents")
    let appExe = contents.appendingPathComponent("MacOS/TryFydeOS")
    try touch(appExe)
    try touch(contents.appendingPathComponent("Resources/factory/spec.json"))
    let app = try Locations.discover(environment: [FactoryStore.environmentKey: "/stores/x"], executable: appExe)
    let dir = app.appBundle!.deletingLastPathComponent().path
    #expect(app.factoryImportCandidates(spec).map(\.path) == [
        app.bundleResources!.path + "/factory/img.bin", dir + "/img.bin", dir + "/FydeOS/img.bin",
    ])
    #expect(app.factoryStoreDirectory.path == "/stores/x")
    #expect(FactoryStore.findSource(app.factoryImportCandidates(spec)) == nil)
    try touch(volume.appendingPathComponent("FydeOS/img.bin"))
    #expect(FactoryStore.findSource(app.factoryImportCandidates(spec))?.path == dir + "/FydeOS/img.bin")
    try touch(volume.appendingPathComponent("img.bin"))
    #expect(FactoryStore.findSource(app.factoryImportCandidates(spec))?.path == dir + "/img.bin")
}

@Test func prepareClonesFromStoreWithoutHashing() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, spec) = try fakeImage(in: root.appendingPathComponent("src"), name: "img.bin")
    let fw = root.appendingPathComponent("fw")
    try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 4096).write(to: fw.appendingPathComponent("edk2-arm-vars.fd"))
    let specFile = root.appendingPathComponent("spec.json")
    try JSONSerialization.data(withJSONObject: ["schema": 1, "board": "b", "image": [
        "file": "img.bin", "bytes": spec.image.bytes, "sha256": spec.image.sha256, "version": "v"]]).write(to: specFile)
    let loc = Locations(root: nil, bundleResources: nil, appBundle: nil, runtime: root, firmware: fw, factorySpec: specFile,
                        factoryStoreDirectory: root.appendingPathComponent("store"), factoryImageOverride: nil)
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    #expect(throws: FactoryStoreError.self) { try ws.prepare(lock: lock, locations: loc) }
    #expect(!ws.isPrepared)
    let record = try loc.factoryStore(spec).importImage(from: source)
    var hashed = false
    let metadata = try ws.prepare(lock: lock, locations: loc) { _, _ in hashed = true }
    #expect(!hashed)
    #expect(metadata.factory == record)
    #expect(try Data(contentsOf: ws.disk) == Data(contentsOf: source))
}

@Test func qemuAcceptsEitherBinaryName() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var loc = Locations(root: nil, bundleResources: nil, appBundle: nil, runtime: root, firmware: root,
                        factorySpec: root, factoryStoreDirectory: root, factoryImageOverride: nil)
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
