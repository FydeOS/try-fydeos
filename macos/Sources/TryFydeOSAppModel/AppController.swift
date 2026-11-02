import Foundation
import TryFydeOSCore

public enum AppState: Equatable, Sendable {
    case notRunning(String?)
    case preparing(stage: PrepareStage?, bytes: Int64, total: Int64)
    case starting
    case running(since: Date)
    case shuttingDown
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .notRunning, .failed: return false
        case .preparing, .starting, .running, .shuttingDown: return true
        }
    }

    public func statusText(timeFormatter: (Date) -> String) -> String {
        switch self {
        case .notRunning(nil): return L(.statusNotRunning)
        case .notRunning(let message?): return L(.statusNotRunningAfter, message)
        case .preparing(let stage?, let bytes, let total) where total > 0:
            let percent = Int(min(1, Double(bytes) / Double(total)) * 100)
            return L(stage == .downloading ? .statusDownloading : .statusConverting, percent)
        case .preparing: return L(.statusPreparing)
        case .starting: return L(.statusStarting)
        case .running(let since): return L(.statusRunningSince, timeFormatter(since))
        case .shuttingDown: return L(.statusShuttingDown)
        case .failed(let message): return message
        }
    }
}

/// What the driver reports. `.exited` and `.failed` both mean nothing is running any more;
/// `.release` carries the release API's answer.
public enum VMEvent: Equatable, Sendable {
    case preparing(stage: PrepareStage, bytes: Int64, total: Int64)
    case starting(pid: pid_t)
    case running
    case exited(ExitStatus)
    case failed(String)
    case release(Release)
}

/// Runs the VM. `events` must be delivered on the main thread.
public protocol VMDriver: AnyObject {
    func launch(_ options: LaunchOptions, events: @escaping (VMEvent) -> Void)
    func shutDown()
    func pauseForSleep()
    func resumeAfterWake()
    func factoryReset() throws
    /// Asks the release API once and reports `.release` if it answers.
    func checkRelease(events: @escaping (VMEvent) -> Void)
    /// The image the prepared VM was converted from.
    func preparedFactory() -> FactoryRecord?
}

/// The start menu's state machine. Main thread only.
public final class AppController {
    public private(set) var state: AppState = .notRunning(nil) {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var quitPending = false
    /// The QEMU process of the current run, from `.starting` until it exits.
    public private(set) var vmPid: pid_t?
    public var onStateChange: ((AppState) -> Void)?
    public var onError: ((_ title: String, _ message: String) -> Void)?
    public var onReadyToQuit: (() -> Void)?
    /// Runs when the release API's answer arrives.
    public var onReleaseChange: (() -> Void)?
    public var now: () -> Date = Date.init
    private let driver: VMDriver
    private var release: Release?

    public init(driver: VMDriver) {
        self.driver = driver
    }

    public var canLaunch: Bool { !state.isActive && !quitPending }

    public func checkRelease() {
        driver.checkRelease { [weak self] in self?.handle($0) }
    }

    /// The release API's image when the prepared VM was converted from another one.
    public var updateRelease: Release? {
        guard let release, let factory = driver.preparedFactory(), factory.sha256 != release.sha256 else { return nil }
        return release
    }

    public func statusText(timeFormatter: (Date) -> String) -> String {
        state.statusText(timeFormatter: timeFormatter)
    }
    public var canShutDown: Bool {
        switch state {
        case .starting, .running: return true
        default: return false
        }
    }
    public var canFactoryReset: Bool { !state.isActive && !quitPending }

    public func launch(_ options: LaunchOptions) {
        guard canLaunch else { return }
        state = .preparing(stage: nil, bytes: 0, total: 0)
        driver.launch(options) { [weak self] in self?.handle($0) }
    }

    public func shutDown() {
        guard canShutDown else { return }
        state = .shuttingDown
        driver.shutDown()
    }

    /// True when the app may terminate now; otherwise the VM is being stopped and
    /// `onReadyToQuit` fires once nothing runs any more.
    public func requestQuit() -> Bool {
        guard state.isActive else { return true }
        quitPending = true
        shutDown()
        return false
    }

    public func willSleep() {
        if case .running = state { driver.pauseForSleep() }
    }

    public func didWake() {
        if state.isActive { driver.resumeAfterWake() }
    }

    public func factoryReset() throws {
        guard canFactoryReset else { throw ConfigError.invalid(L(.errorBusy)) }
        try driver.factoryReset()
        state = .notRunning(L(.resetDone))
    }

    public func handle(_ event: VMEvent) {
        switch event {
        case .preparing(let stage, let bytes, let total):
            guard case .preparing = state else { return }
            state = .preparing(stage: stage, bytes: bytes, total: total)
        case .starting(let pid):
            guard case .preparing = state else { return }
            vmPid = pid
            state = .starting
            if quitPending { shutDown() }
        case .running:
            guard state == .starting else { return }
            state = .running(since: now())
        case .exited(let status):
            if state == .shuttingDown {
                state = .notRunning(L(.lastRunShutDown, status.description))
            } else if status.code == 0 {
                state = .notRunning(L(.lastRunStopped, status.description))
            } else {
                fail(L(.errorUnexpectedExit, status.description), title: L(.errorAlertTitle))
            }
            finishQuit()
        case .failed(let message):
            fail(message, title: L(.errorLaunchTitle))
            finishQuit()
        case .release(let release):
            self.release = release
            onReleaseChange?()
        }
    }

    private func fail(_ message: String, title: String) {
        state = .failed(message)
        if !quitPending { onError?(title, message) }
    }

    private func finishQuit() {
        if quitPending { onReadyToQuit?() }
    }
}
