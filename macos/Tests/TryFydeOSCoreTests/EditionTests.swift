import Foundation
import Testing
@testable import TryFydeOSCore

@Test func editionResolvesFromPlistThenEnvironment() {
    #expect(Edition.resolve(infoValue: nil, environment: [:]) == .io)
    #expect(Edition.resolve(infoValue: nil, environment: ["TRY_FYDEOS_EDITION": "com"]) == .com)
    #expect(Edition.resolve(infoValue: "io", environment: ["TRY_FYDEOS_EDITION": "com"]) == .io)
    #expect(Edition.resolve(infoValue: nil, environment: ["TRY_FYDEOS_EDITION": "cn"]) == .io)
}

@Test func repoComFactorySpecLoads() throws {
    let spec = try FactorySpec.load(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../factory/arm64-vmware-com.json").standardizedFileURL)
    #expect(spec.release.api == "https://release-api.fydeos.com/api/downloads?l=zh")
    #expect(spec.release.board == "arm64-vmware")
    #expect(try urlFileName(spec.image.url) == "FydeOS-VMWare-v23.1-Preview1-arm64-com.zip")
}
