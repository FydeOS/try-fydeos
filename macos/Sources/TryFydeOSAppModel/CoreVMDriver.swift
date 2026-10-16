import Foundation
import TryFydeOSCore

/// Appends timestamped lines to `~/Library/Logs/Try FydeOS/TryFydeOS.log`.
public final class AppLog: @unchecked Sendable {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Try FydeOS")
    public let url: URL
    private let lock = NSLock()
    private let handle: FileHandle?

    public init(directory: URL = AppLog.directory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("TryFydeOS.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    public func write(_ message: String) {
        lock.lock()
        handle?.write(Data("\(utcTimestamp()) [\(getpid())] \(message)\n".utf8))
        lock.unlock()
    }

    /// `<logs>/VM runs` -> the workspace's runs/, so Logs in Finder reaches console.log and friends.
    public func linkRuns(_ runs: URL) {
        let link = url.deletingLastPathComponent().appendingPathComponent("VM runs")
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == runs.path { return }
        if (try? fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            try? fm.removeItem(at: link)
        }
        try? fm.createSymbolicLink(at: link, withDestinationURL: runs)
    }
}

/// Runs `VMSession` on a background thread. The storage lock is taken on first use and
/// kept for the app's lifetime.
public final class CoreVMDriver: VMDriver, @unchecked Sendable {
    public let workspace: Workspace
    private let log: AppLog
    private let locations: () throws -> Locations
    private let mutex = NSLock()
    private var storageLock: StorageLock?
    private var session: VMSession?

    public init(workspace: Workspace, log: AppLog, locations: @escaping () throws -> Locations = { try Locations.discover() }) {
        self.workspace = workspace
        self.log = log
        self.locations = locations
    }

    private var current: VMSession? {
        mutex.lock(); defer { mutex.unlock() }
        return session
    }

    private func setSession(_ value: VMSession?) {
        mutex.lock(); session = value; mutex.unlock()
    }

    private func takeLock() throws -> StorageLock {
        mutex.lock(); defer { mutex.unlock() }
        if let storageLock { return storageLock }
        let lock = try workspace.open()
        storageLock = lock
        return lock
    }

    public func launch(_ options: LaunchOptions, events: @escaping (VMEvent) -> Void) {
        let deliver: (VMEvent) -> Void = { event in DispatchQueue.main.async { events(event) } }
        let log = self.log
        let thread = Thread { [self] in
            do {
                log.write("launch \(options.cpus) CPUs, \(options.memoryMiB) MiB, full screen \(options.fullScreen), microphone \(options.microphone), workspace \(workspace.url.path)")
                let loc = try locations()
                let lock = try takeLock()
                log.linkRuns(workspace.runsDir)
                let metadata = try workspace.prepare(lock: lock, locations: loc) { spec, image in
                    log.write("verifying sha256 of \(image.path) (\(spec.image.bytes) bytes, once per VM)")
                }
                let session = try VMSession.launch(options: options, locations: loc, workspace: workspace, lock: lock,
                                                   metadata: metadata) { log.write("run: \($0)") }
                setSession(session)
                deliver(.starting)
                do {
                    try session.waitForQMP()
                } catch {
                    let status = session.waitForExit()
                    setSession(nil)
                    deliver(.failed(L(.errorNotReady, "\(error)", status.description)))
                    return
                }
                deliver(.running)
                let status = session.waitForExit()
                setSession(nil)
                deliver(.exited(status))
            } catch {
                log.write("launch failed: \(error)")
                deliver(.failed("\(error)"))
            }
        }
        thread.name = "vm-session"
        thread.start()
    }

    public func shutDown() {
        current?.requestShutdown(force: false, reason: "shutdown requested by the app")
    }

    public func pauseForSleep() {
        current?.pauseForSleep()
    }

    public func resumeAfterWake() {
        current?.resumeAfterWake()
    }

    public func factoryReset() throws {
        let lock = try takeLock()
        try workspace.reset(lock: lock)
        log.write("factory reset \(workspace.url.path)")
    }
}
