import Darwin
import Foundation

public struct LaunchOptions: Sendable, Equatable {
    public var cpus: Int
    public var memoryMiB: Int
    public var fullScreen = false
    public var microphone = false
    public var hostForwards: [HostForward] = []
    public var glBackend: GLBackend = .native

    public init(cpus: Int = 4, memoryMiB: Int = 8192, fullScreen: Bool = false, microphone: Bool = false) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.fullScreen = fullScreen
        self.microphone = microphone
    }

    public func config(locations loc: Locations, workspace ws: Workspace, console: URL, mac: String, lockFD: Int32) -> VMConfig {
        var config = VMConfig(cpus: cpus, memoryMiB: memoryMiB,
                              paths: VMPaths(qemu: loc.qemu.path, firmwareCode: loc.firmwareCode.path, efiVars: ws.efiVars.path,
                                             disk: ws.disk.path, console: console.path, qmpSocket: ws.qmpSocket.path),
                              mac: mac, lockFD: lockFD)
        config.fullScreen = fullScreen
        config.microphone = microphone
        config.hostForwards = hostForwards
        config.glBackend = glBackend
        return config
    }
}

extension Workspace {
    public func prepare(lock: StorageLock, locations loc: Locations,
                        beforeHashing: (FactorySpec, URL) -> Void = { _, _ in }) throws -> Metadata {
        let spec = try FactorySpec.load(loc.factorySpec)
        let image = loc.factoryImage(spec)
        return try prepare(lock: lock, spec: spec, image: image, varsTemplate: loc.varsTemplate) {
            beforeHashing(spec, image)
        }
    }
}

/// One QEMU run: run directory, supervisor.log, run.json, the process and its ladder.
public final class VMSession: @unchecked Sendable {
    public let id: String
    public let directory: URL
    public let process: VMProcess
    public let lifecycle: Lifecycle
    private let workspace: Workspace
    private let logHandle: FileHandle
    private let echo: (String) -> Void
    private let lock = NSLock()
    private var record: RunRecord
    private var shutdownLevels: Set<Bool> = []
    private var pausedForSleep = false

    private init(id: String, directory: URL, process: VMProcess, workspace: Workspace, logHandle: FileHandle,
                 record: RunRecord, echo: @escaping (String) -> Void) {
        self.id = id
        self.directory = directory
        self.process = process
        self.workspace = workspace
        self.logHandle = logHandle
        self.record = record
        self.echo = echo
        lifecycle = Lifecycle(process: process, qmpSocket: workspace.qmpSocket.path)
        lifecycle.log = { [weak self] in self?.log($0) }
    }

    public static func launch(options: LaunchOptions, locations: Locations, workspace ws: Workspace, lock: StorageLock,
                              metadata: Metadata, host: HostInfo = .current(),
                              echo: @escaping (String) -> Void = { _ in }) throws -> VMSession {
        try? FileManager.default.removeItem(at: ws.qmpSocket)
        let (id, dir) = try ws.newRunDirectory()
        let logFile = dir.appendingPathComponent("supervisor.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logFile)
        logHandle.seekToEndOfFile()
        let argv = try options.config(locations: locations, workspace: ws, console: dir.appendingPathComponent("console.log"),
                                      mac: metadata.mac, lockFD: lock.fd).argv(host: host)
        var record = RunRecord(id: id, argv: argv, supervisorPid: getpid(), start: utcTimestamp())
        try Workspace.writeRunRecord(record, in: dir)
        let process = try VMProcess.spawn(argv: argv, logPath: dir.appendingPathComponent("qemu.log").path, inheritFD: lock.fd)
        record.pid = process.pid
        let session = VMSession(id: id, directory: dir, process: process, workspace: ws, logHandle: logHandle,
                                record: record, echo: echo)
        session.saveRecord()
        session.log("run \(id): QEMU pid \(process.pid), logs in \(dir.path)")
        return session
    }

    public func log(_ message: String) {
        echo(message)
        lock.lock()
        logHandle.write(Data("\(utcTimestamp()) \(message)\n".utf8))
        lock.unlock()
    }

    private func saveRecord(_ change: (inout RunRecord) -> Void = { _ in }) {
        lock.lock()
        change(&record)
        let snapshot = record
        lock.unlock()
        do { try Workspace.writeRunRecord(snapshot, in: directory) } catch { log("writing run.json: \(error)") }
    }

    /// On failure the ladder is started at QMP quit and the error rethrown; the process may still be exiting.
    public func waitForQMP(timeout: TimeInterval = 30) throws {
        do {
            try lifecycle.waitForQMP(timeout: timeout)
        } catch {
            log("QMP not ready: \(error)")
            if process.exitStatus == nil { requestShutdown(force: true) }
            throw error
        }
        saveRecord { $0.qmpReady = utcTimestamp() }
        log("QMP ready on \(workspace.qmpSocket.path)")
    }

    /// Runs the ladder in the background, once per level; `force` starts at QMP quit.
    public func requestShutdown(force: Bool, reason: String? = nil) {
        lock.lock()
        let first = shutdownLevels.insert(force).inserted
        lock.unlock()
        guard first else { return }
        if let reason { log(reason) }
        DispatchQueue.global().async { self.lifecycle.shutdown(force: force) }
    }

    public var isShuttingDown: Bool {
        lock.lock(); defer { lock.unlock() }
        return !shutdownLevels.isEmpty
    }

    /// QMP `stop` before host sleep, remembered so that only our own stop is undone on wake.
    public func pauseForSleep() {
        guard process.exitStatus == nil, !isShuttingDown else { return }
        do {
            let client = try QMPClient.connect(path: workspace.qmpSocket.path)
            defer { client.close() }
            let status = try client.queryStatus()
            guard status.running else {
                log("host sleep: guest is \(status.status), not stopping it")
                return
            }
            try client.stop()
            lock.lock(); pausedForSleep = true; lock.unlock()
            log("host sleep: QMP stop")
        } catch {
            log("host sleep: QMP stop failed: \(error)")
        }
    }

    public func resumeAfterWake() {
        lock.lock()
        let ours = pausedForSleep
        pausedForSleep = false
        lock.unlock()
        guard ours else {
            log("host wake: no stop of ours to undo")
            return
        }
        guard process.exitStatus == nil else { return }
        do {
            let client = try QMPClient.connect(path: workspace.qmpSocket.path)
            defer { client.close() }
            try client.cont()
            log("host wake: QMP cont")
        } catch {
            log("host wake: QMP cont failed: \(error)")
        }
    }

    /// Blocks until QEMU exits, then completes run.json and removes the QMP socket.
    @discardableResult
    public func waitForExit() -> ExitStatus {
        let status = process.wait()!
        saveRecord {
            $0.end = utcTimestamp()
            $0.exitCode = status.code
            $0.signal = status.signal
        }
        try? FileManager.default.removeItem(at: workspace.qmpSocket)
        log("QEMU \(status)")
        return status
    }
}
