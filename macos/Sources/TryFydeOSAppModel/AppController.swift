import Foundation
import TryFydeOSCore

public enum AppState: Equatable, Sendable {
    case notRunning(String?)
    case preparing
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
        case .preparing: return L(.statusPreparing)
        case .starting: return L(.statusStarting)
        case .running(let since): return L(.statusRunningSince, timeFormatter(since))
        case .shuttingDown: return L(.statusShuttingDown)
        case .failed(let message): return message
        }
    }
}

/// What the driver reports. `.exited` and `.failed` both mean nothing is running any more.
public enum VMEvent: Equatable, Sendable {
    case starting
    case running
    case exited(ExitStatus)
    case failed(String)
}

/// Runs the VM. `events` must be delivered on the main thread.
public protocol VMDriver: AnyObject {
    func launch(_ options: LaunchOptions, events: @escaping (VMEvent) -> Void)
    func shutDown()
    func pauseForSleep()
    func resumeAfterWake()
    func factoryReset() throws
}

/// The start menu's state machine. Main thread only.
public final class AppController {
    public private(set) var state: AppState = .notRunning(nil) {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var quitPending = false
    public var onStateChange: ((AppState) -> Void)?
    public var onError: ((String) -> Void)?
    public var onReadyToQuit: (() -> Void)?
    public var now: () -> Date = Date.init
    public let image: ImageController?
    private let driver: VMDriver

    public init(driver: VMDriver, image: ImageController? = nil) {
        self.driver = driver
        self.image = image
    }

    public var canLaunch: Bool { !state.isActive && !quitPending && image?.isInstalled != false }

    /// The image's status while it is missing or installing, otherwise the VM's.
    public func statusText(timeFormatter: (Date) -> String) -> String {
        if !state.isActive, let text = image?.statusText { return text }
        return state.statusText(timeFormatter: timeFormatter)
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
        state = .preparing
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
        case .starting:
            guard state == .preparing else { return }
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
                fail(L(.errorUnexpectedExit, status.description))
            }
            finishQuit()
        case .failed(let message):
            fail(message)
            finishQuit()
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        if !quitPending { onError?(message) }
    }

    private func finishQuit() {
        if quitPending { onReadyToQuit?() }
    }
}
