import Foundation
import TryFydeOSCore

public struct ImportProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case copying
        case verifying
    }

    public var phase: Phase
    public var bytes: Int64
    public var total: Int64

    public init(phase: Phase, bytes: Int64, total: Int64) {
        self.phase = phase
        self.bytes = bytes
        self.total = total
    }

    public var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
}

public enum ImageState: Equatable, Sendable {
    case notInstalled(source: URL?)
    case importing(ImportProgress)
    case installed(version: String)
}

/// The factory image store as the start menu sees it. Callbacks must be delivered on the main thread.
public protocol ImageDriver: AnyObject {
    var expectedFile: String { get }
    /// The spec's version string when the store holds a verified image.
    func installedVersion() -> String?
    func detectSource() -> URL?
    func importImage(from source: URL, progress: @escaping (ImportProgress) -> Void,
                     completion: @escaping (Result<FactoryRecord, Error>) -> Void)
}

/// notInstalled → importing(progress) → installed; a failed import returns to notInstalled with `lastError`.
/// Main thread only.
public final class ImageController {
    public private(set) var state: ImageState = .notInstalled(source: nil) {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var lastError: String?
    public var onStateChange: ((ImageState) -> Void)?
    public var onError: ((String) -> Void)?
    private let driver: ImageDriver

    public init(driver: ImageDriver) {
        self.driver = driver
        refresh()
    }

    public var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    public var isImporting: Bool {
        if case .importing = state { return true }
        return false
    }

    /// True when Install… has nothing to import from and must ask for the file.
    public var needsFileChoice: Bool { state == .notInstalled(source: nil) }

    public var expectedFile: String { driver.expectedFile }

    public func refresh() {
        guard !isImporting else { return }
        reload()
    }

    private func reload() {
        if let version = driver.installedVersion() {
            state = .installed(version: version)
        } else {
            state = .notInstalled(source: driver.detectSource())
        }
    }

    /// Imports `source`, or the detected one when nil. Does nothing while importing or when there is no source.
    public func install(from source: URL? = nil) {
        guard case .notInstalled(let detected) = state, let source = source ?? detected else { return }
        lastError = nil
        state = .importing(ImportProgress(phase: .copying, bytes: 0, total: 0))
        driver.importImage(from: source, progress: { [weak self] progress in
            guard let self, self.isImporting else { return }
            self.state = .importing(progress)
        }, completion: { [weak self] result in
            guard let self else { return }
            var failure: String?
            if case .failure(let error) = result { failure = L(.imageImportFailed, "\(error)") }
            self.lastError = failure
            self.reload()
            if failure == nil, !self.isInstalled { failure = L(.imageImportFailed, L(.imageNotVerifiedAfterImport)) }
            if let failure {
                self.lastError = failure
                self.onError?(failure)
            }
        })
    }

    public var rowText: String {
        switch state {
        case .notInstalled: return L(.imageNotInstalled)
        case .importing: return L(.imageInstalling)
        case .installed(let version): return version
        }
    }

    /// What the status line shows while the image is missing or being installed; nil once installed.
    public var statusText: String? {
        switch state {
        case .installed: return nil
        case .importing(let p):
            return L(p.phase == .copying ? .imageCopying : .imageVerifying, Int(p.fraction * 100))
        case .notInstalled(let source):
            if let lastError { return lastError }
            if let source { return L(.imageFoundAt, source.deletingLastPathComponent().path) }
            return L(.imageChoose, driver.expectedFile)
        }
    }
}

/// `ImageDriver` over the image bundled with the app: installed when it is present, nothing to import.
public final class CoreImageDriver: ImageDriver, @unchecked Sendable {
    private let log: AppLog
    private let locations: () throws -> Locations

    public init(log: AppLog, locations: @escaping () throws -> Locations = { try Locations.discover() }) {
        self.log = log
        self.locations = locations
    }

    private func context() -> (Locations, FactorySpec)? {
        do {
            let loc = try locations()
            return (loc, try FactorySpec.load(loc.factorySpec))
        } catch {
            log.write("factory image: \(error)")
            return nil
        }
    }

    public var expectedFile: String { context()?.1.image.file ?? "FydeOS image" }

    public func installedVersion() -> String? {
        guard let (loc, spec) = context() else { return nil }
        let image = loc.factoryImage(spec)
        log.write("factory image: \(image?.path ?? "not found")")
        return image == nil ? nil : spec.image.version
    }

    public func detectSource() -> URL? { nil }

    public func importImage(from source: URL, progress: @escaping (ImportProgress) -> Void,
                            completion: @escaping (Result<FactoryRecord, Error>) -> Void) {
        completion(.failure(ConfigError.invalid("the FydeOS image ships inside the app; there is nothing to import")))
    }
}
