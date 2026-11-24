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
              sha256: String = String(repeating: "0", count: 64), api: String? = "https://example.invalid/api") -> FactorySpec {
    FactorySpec(schema: 2, image: .init(url: url, bytes: bytes, sha256: sha256, version: "v"),
                release: api.map { FactorySpec.ReleaseSource(api: $0, board: "b") }, diskBytes: diskBytes, board: "b")
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
    func load(_ image: [String: Any], schema: Int = 2, api: String = "https://example.invalid/api",
              release: [String: Any]?? = nil) throws -> FactorySpec {
        let url = root.appendingPathComponent("spec.json")
        var json: [String: Any] = ["schema": schema, "board": "b", "diskBytes": 1, "image": image]
        if let body = release ?? ["api": api, "board": "b"] { json["release"] = body }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return try FactorySpec.load(url)
    }
    let good: [String: Any] = ["url": "https://example.invalid/d/x.zip", "bytes": 1, "sha256": zero, "version": "v"]
    #expect(try load(good).image.url == "https://example.invalid/d/x.zip")
    #expect(throws: ConfigError.self) { try load(good, schema: 1) }
    #expect(throws: ConfigError.self) { try load(good, api: "http://example.invalid/api") }
    #expect(try load(good).release?.board == "b")
    #expect(try load(good, release: .some(nil)).release == nil)
    #expect(throws: ConfigError.self) { try load(good, release: ["api": "https://example.invalid/api", "board": ""]) }
    #expect(throws: (any Error).self) { try load(good, release: ["api": "https://example.invalid/api"]) }
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
    #expect(spec.release?.board == "arm64-vmware")
    #expect(try urlFileName(spec.image.url) == "FydeOS-VMWare-v23.1-Preview1-arm64-io.zip")
    #expect(spec.diskBytes == 64 << 30)
}

let testZstd: URL? = [
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../out/runtime/current/runtime/bin/zstd").standardizedFileURL,
    URL(fileURLWithPath: "/opt/homebrew/bin/zstd"),
].first { FileManager.default.isExecutableFile(atPath: $0.path) }

let zstImageBytes = 24 << 20
private let zstPattern = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: ($0 &* 2654435761) >> 13) | 1 })

/// A raw disk of `zstImageBytes`: data in the first MiB and from 12345 bytes into the last MiB to the end,
/// zeros between (APFS allocates holes shorter than about 16 MiB); its GPT header claims the alternate
/// header at sector `alternate` (the last sector by default).
func zstRawImage(gpt: Bool = true, alternate: UInt64 = UInt64(zstImageBytes / 512 - 1)) -> Data {
    var raw = zstPattern + Data(count: zstImageBytes - 2 * zstPattern.count) + Data(count: 12345) + zstPattern.dropFirst(12345)
    raw.replaceSubrange(512..<1024, with: Data(count: 512))
    if gpt {
        raw.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        raw.replaceSubrange(544..<552, with: withUnsafeBytes(of: alternate.littleEndian) { Data($0) })
    }
    return raw
}

/// Compresses `raw` as the bundle does; `fromPipe` leaves the content size out of the frame header.
func zstFile(_ raw: Data, in dir: URL, name: String = "image.zst", fromPipe: Bool = false) throws -> URL {
    let input = dir.appendingPathComponent("\(name).raw")
    try raw.write(to: input)
    defer { try? FileManager.default.removeItem(at: input) }
    let output = dir.appendingPathComponent(name)
    let p = Process()
    p.executableURL = testZstd!
    p.arguments = ["-q", "-f", "-19", "--long=27", "-o", output.path] + (fromPipe ? [] : [input.path])
    if fromPipe { p.standardInput = try FileHandle(forReadingFrom: input) }
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    return output
}

@Test(.enabled(if: testZstd != nil))
func prepareUnpacksZstRawImageSparse() throws {
    for fromPipe in [false, true] {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vars = try varsTemplate(in: root)
        let raw = zstRawImage()
        let image = try zstFile(raw, in: root, fromPipe: fromPipe)
        #expect(zstdContentSize(image) == (fromPipe ? nil : Int64(raw.count)))
        let ws = Workspace(url: root.appendingPathComponent("vm"))
        let lock = try ws.open(requireAPFS: false)
        defer { lock.release() }
        let record = FactoryRecord(url: "u", fileName: "image.zst", sha256: "s", version: "v")
        var reports: [(Int64, Int64)] = []
        let metadata = try ws.prepare(lock: lock, spec: testSpec(), container: image, record: record, varsTemplate: vars,
                                      zstd: testZstd!) { reports.append(($0, $1)) }
        let n = Int64(raw.count)
        #expect(reports.count >= 2 && reports.allSatisfy { $0.1 == n } && reports.last.map { $0.0 } == n, "\(fromPipe)")
        var want = record
        want.rawBytes = n
        #expect(metadata.factory == want)
        #expect(ws.isPrepared)
        #expect(!FileManager.default.fileExists(atPath: ws.stagingDisk.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: ws.disk.path)
        #expect((attrs[.size] as? NSNumber)?.int64Value == 64 << 20)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var st = stat()
        #expect(stat(ws.disk.path, &st) == 0 && Int64(st.st_blocks) * 512 < 8 << 20, "\(st.st_blocks) blocks")
        let disk = try FileHandle(forReadingFrom: ws.disk)
        defer { try? disk.close() }
        #expect(try disk.read(upToCount: raw.count) == raw)
        #expect(try disk.read(upToCount: 4096) == Data(count: 4096))
    }
}

@Test(.enabled(if: testZstd != nil))
func prepareTakesBundledZstThroughLocations() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let fw = root.appendingPathComponent("fw")
    try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 4096).write(to: fw.appendingPathComponent("edk2-arm-vars.fd"))
    let zero = String(repeating: "0", count: 64)
    let specFile = root.appendingPathComponent("spec.json")
    try JSONSerialization.data(withJSONObject: [
        "schema": 2, "board": "b", "diskBytes": 64 << 20,
        "image": ["url": "https://127.0.0.1:1/pinned.zip", "bytes": 1, "sha256": zero, "version": "v"],
    ]).write(to: specFile)
    let raw = zstRawImage()
    let loc = Locations(root: nil, bundleResources: nil, runtime: testZstd!.deletingLastPathComponent().deletingLastPathComponent(),
                        firmware: fw, factorySpec: specFile, factoryImageOverride: nil,
                        bundledImage: try zstFile(raw, in: root), images: root.appendingPathComponent("images"))
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    var lines: [String] = []
    var stages: [PrepareStage] = []
    let metadata = try ws.prepare(lock: lock, locations: loc, say: { lines.append($0) }) { stage, _, _ in stages.append(stage) }
    #expect(metadata.factory == FactoryRecord(url: "https://127.0.0.1:1/pinned.zip", fileName: "image.zst", sha256: zero, version: "v",
                                              rawBytes: Int64(raw.count)))
    #expect(Set(stages) == [.converting])
    #expect(lines.first == "using the bundled image \(loc.bundledImage!.path)")
    #expect(!FileManager.default.fileExists(atPath: loc.images.path))
    let disk = try FileHandle(forReadingFrom: ws.disk)
    defer { try? disk.close() }
    #expect(try disk.read(upToCount: raw.count) == raw)
}

@Test(.enabled(if: testZstd != nil))
func prepareRejectsBrokenZstImages() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let vars = try varsTemplate(in: root)
    let ws = Workspace(url: root.appendingPathComponent("vm"))
    let lock = try ws.open(requireAPFS: false)
    defer { lock.release() }
    let sectors = UInt64(zstImageBytes / 512)
    let corrupt = try zstFile(zstRawImage(), in: root, name: "corrupt.zst")
    let whole = try Data(contentsOf: corrupt)
    try whole.prefix(whole.count / 2).write(to: corrupt)
    let cases: [(URL, String)] = [
        (try zstFile(zstRawImage(alternate: sectors - 2), in: root, name: "long.zst"), "foreign image: data beyond the GPT"),
        (try zstFile(zstRawImage(alternate: sectors), in: root, name: "short.zst"), "truncated image"),
        (try zstFile(zstRawImage(gpt: false), in: root, name: "nogpt.zst"), "no GPT on the disk"),
        (corrupt, "zstd exit"),
    ]
    for (image, why) in cases {
        do {
            _ = try ws.prepare(lock: lock, spec: testSpec(), container: image, record: FactoryRecord(fileName: "x"), varsTemplate: vars,
                               zstd: testZstd!)
            Issue.record("\(image.lastPathComponent) accepted")
        } catch {
            #expect("\(error)".contains(why), "\(image.lastPathComponent): \(error)")
        }
        #expect(!ws.isPrepared)
        #expect(!FileManager.default.fileExists(atPath: ws.disk.path))
        #expect(!FileManager.default.fileExists(atPath: ws.stagingDisk.path))
    }
    do {
        _ = try ws.prepare(lock: lock, spec: testSpec(diskBytes: 4 << 20), container: try zstFile(zstRawImage(), in: root),
                           record: FactoryRecord(fileName: "x"), varsTemplate: vars, zstd: testZstd!)
        Issue.record("image larger than the VM disk accepted")
    } catch {
        #expect("\(error)".contains("more than the"))
    }
}
