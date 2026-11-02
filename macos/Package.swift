// swift-tools-version:6.0
import Foundation
import PackageDescription

// Command Line Tools 6.4 ship the swift-testing macro plugin in plugins/testing
// but do not search it, so `swift test` fails without this path.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
let testSettings: [SwiftSetting] =
    developerDir.hasPrefix("/Library/Developer/CommandLineTools") && FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])] : []

let package = Package(
    name: "TryFydeOS",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TryFydeOSCore", targets: ["TryFydeOSCore"]),
        .executable(name: "tryfydeos", targets: ["TryFydeOSCLI"]),
        .executable(name: "TryFydeOSApp", targets: ["TryFydeOSApp"]),
    ],
    targets: [
        // Compression's zlib decoder consumes past the end of a stream, so the Adler-32 trailer cannot be checked.
        .systemLibrary(name: "CZlib"),
        .target(name: "TryFydeOSCore", dependencies: ["CZlib"]),
        .executableTarget(name: "TryFydeOSCLI", dependencies: ["TryFydeOSCore"]),
        .target(name: "TryFydeOSAppModel", dependencies: ["TryFydeOSCore"]),
        .executableTarget(name: "TryFydeOSApp", dependencies: ["TryFydeOSCore", "TryFydeOSAppModel"]),
        .testTarget(name: "TryFydeOSCoreTests", dependencies: ["TryFydeOSCore", "CZlib"], swiftSettings: testSettings),
        .testTarget(name: "TryFydeOSAppModelTests", dependencies: ["TryFydeOSAppModel"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
