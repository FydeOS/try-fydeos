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
