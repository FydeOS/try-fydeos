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
    try touch(root.appendingPathComponent("factory/spec.json"))
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
    #expect(loc.zstd.path == resources + "/runtime/bin/zstd")
}

@Test func repoLayoutWithoutBundleAndEnvironmentOverrides() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try touch(root.appendingPathComponent("runtime/lock.json"))
    try touch(root.appendingPathComponent("factory/spec.json"))
    let exe = root.appendingPathComponent("macos/.build/release/tryfydeos")
    try touch(exe)
    let loc = try Locations.discover(environment: [:], executable: exe)
    #expect(loc.bundleResources == nil)
    #expect(loc.runtime.path.hasSuffix("/out/runtime/current/runtime"))
    let overridden = try Locations.discover(environment: ["TRY_FYDEOS_RUNTIME": "/opt/rt", "TRY_FYDEOS_FIRMWARE": "/opt/fw"], executable: exe)
    #expect(overridden.runtime.path == "/opt/rt")
    #expect(overridden.firmware.path == "/opt/fw")
}

@Test func factoryImageCandidatesInResolutionOrder() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zero = String(repeating: "0", count: 64)
    let spec = try JSONDecoder().decode(FactorySpec.self, from: Data("""
        {"schema": 1, "board": "b", "diskBytes": 2, "image": {"file": "img.zst", "bytes": 1, "sha256": "\(zero)",
         "rawBytes": 1, "rawSha256": "\(zero)", "version": "v"}}
        """.utf8))
    try touch(root.appendingPathComponent("repo/runtime/lock.json"))
    try touch(root.appendingPathComponent("repo/factory/spec.json"))
    let exe = root.appendingPathComponent("repo/macos/.build/release/tryfydeos")
    try touch(exe)
    let repo = try Locations.discover(environment: ["TRY_FYDEOS_FACTORY_IMAGE": "/env/img.zst"], executable: exe)
    #expect(repo.factoryImageCandidates(spec).map(\.path) == ["/env/img.zst", repo.root!.path + "/factory/img.zst"])
    #expect(repo.factoryImage(spec) == nil)
    try touch(root.appendingPathComponent("repo/factory/img.zst"))
    #expect(repo.factoryImage(spec)?.path == repo.root!.path + "/factory/img.zst")

    let contents = root.appendingPathComponent("Try FydeOS.app/Contents")
    let appExe = contents.appendingPathComponent("MacOS/TryFydeOS")
    try touch(appExe)
    try touch(contents.appendingPathComponent("Resources/factory/spec.json"))
    let app = try Locations.discover(environment: [:], executable: appExe)
    #expect(app.factoryImageCandidates(spec).map(\.path) == [app.bundleResources!.path + "/factory/img.zst"])
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
