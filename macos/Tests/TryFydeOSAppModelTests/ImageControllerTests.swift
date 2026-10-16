import Foundation
import Testing
import TryFydeOSCore
@testable import TryFydeOSAppModel

final class FakeImageDriver: ImageDriver {
    var version: String?
    var source: URL?
    var imports: [URL] = []
    var progress: ((ImportProgress) -> Void)?
    var completion: ((Result<FactoryRecord, Error>) -> Void)?
    let expectedFile = "fydeos.bin"

    func installedVersion() -> String? { version }
    func detectSource() -> URL? { source }
    func importImage(from source: URL, progress: @escaping (ImportProgress) -> Void,
                     completion: @escaping (Result<FactoryRecord, Error>) -> Void) {
        imports.append(source)
        self.progress = progress
        self.completion = completion
    }

    func finish(installing version: String?) {
        self.version = version
        completion?(.success(FactoryRecord(file: expectedFile, sha256: "ab", bytes: 1, mtime: 0)))
    }
}

private let sibling = URL(fileURLWithPath: "/Volumes/Try FydeOS/FydeOS/fydeos.bin")

@Test func verifiedStoreStartsInstalled() {
    let driver = FakeImageDriver()
    driver.version = "R150 dev"
    let image = ImageController(driver: driver)
    #expect(image.state == .installed(version: "R150 dev"))
    #expect(image.rowText == "R150 dev" && image.statusText == nil)
    let app = AppController(driver: FakeDriver(), image: image)
    #expect(app.canLaunch)
    #expect(app.statusText { _ in "" } == L(.statusNotRunning))
}

@Test func siblingIsDetectedAndImported() {
    let driver = FakeImageDriver()
    driver.source = sibling
    let image = ImageController(driver: driver)
    var states: [ImageState] = []
    image.onStateChange = { states.append($0) }
    let app = AppController(driver: FakeDriver(), image: image)
    #expect(image.state == .notInstalled(source: sibling) && !image.needsFileChoice)
    #expect(image.rowText == L(.imageNotInstalled))
    #expect(app.statusText { _ in "" } == L(.imageFoundAt, "/Volumes/Try FydeOS/FydeOS"))
    #expect(!app.canLaunch)
    app.launch(LaunchOptions())
    #expect(app.state == .notRunning(nil))

    image.install()
    #expect(driver.imports == [sibling] && image.isImporting && !app.canLaunch)
    image.install()
    #expect(driver.imports.count == 1)
    driver.progress?(ImportProgress(phase: .copying, bytes: 42, total: 100))
    #expect(image.state == .importing(ImportProgress(phase: .copying, bytes: 42, total: 100)))
    #expect(app.statusText { _ in "" } == L(.imageCopying, 42))
    driver.progress?(ImportProgress(phase: .verifying, bytes: 100, total: 100))
    #expect(app.statusText { _ in "" } == L(.imageVerifying, 100))
    driver.finish(installing: "R150 dev")
    #expect(image.state == .installed(version: "R150 dev") && image.lastError == nil)
    #expect(app.canLaunch)
    #expect(states.last == .installed(version: "R150 dev"))
    #expect(!states.contains(.notInstalled(source: sibling)))
}

@Test func noSourceNeedsFileChoice() {
    let driver = FakeImageDriver()
    let image = ImageController(driver: driver)
    #expect(image.needsFileChoice)
    #expect(image.statusText == L(.imageChoose, "fydeos.bin"))
    image.install()
    #expect(driver.imports.isEmpty && !image.isImporting)
    let chosen = URL(fileURLWithPath: "/Users/u/Downloads/fydeos.bin")
    image.install(from: chosen)
    #expect(driver.imports == [chosen] && image.isImporting)
}

@Test func failedImportReturnsToNotInstalledWithError() {
    struct Boom: Error, CustomStringConvertible { var description = "sha256 mismatch" }
    let driver = FakeImageDriver()
    driver.source = sibling
    let image = ImageController(driver: driver)
    var errors: [String] = []
    image.onError = { errors.append($0) }
    image.install()
    driver.completion?(.failure(Boom()))
    let message = L(.imageImportFailed, "sha256 mismatch")
    #expect(image.state == .notInstalled(source: sibling))
    #expect(errors == [message] && image.lastError == message && image.statusText == message)
    image.install()
    #expect(image.lastError == nil && driver.imports.count == 2)
    driver.finish(installing: nil)
    #expect(image.state == .notInstalled(source: sibling))
    #expect(errors.last == L(.imageImportFailed, L(.imageNotVerifiedAfterImport)))
}

@Test func vmStatusWinsWhileActive() {
    let driver = FakeImageDriver()
    driver.version = "v"
    let image = ImageController(driver: driver)
    let vm = FakeDriver()
    let app = AppController(driver: vm, image: image)
    app.launch(LaunchOptions())
    #expect(app.statusText { _ in "" } == L(.statusPreparing))
}
