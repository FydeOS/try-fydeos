import Darwin
import Foundation

public struct ExitStatus: Equatable, Sendable, CustomStringConvertible {
    public var code: Int32?
    public var signal: Int32?

    init(waitStatus status: Int32) {
        if status & 0x7f == 0 {
            code = (status >> 8) & 0xff
        } else {
            signal = status & 0x7f
        }
    }

    public init(code: Int32?, signal: Int32?) {
        self.code = code
        self.signal = signal
    }

    public var description: String {
        if let code { return "exit code \(code)" }
        if let signal { return "signal \(signal)" }
        return "exited (status unknown, not our child)"
    }
}

public enum SpawnError: Error, CustomStringConvertible {
    case failed(String, Int32)

    public var description: String {
        switch self {
        case .failed(let what, let code): return "\(what): \(String(cString: strerror(code)))"
        }
    }
}

public func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// A QEMU process: a spawned child reaped with waitpid, or an adopted pid polled for liveness.
public final class VMProcess: @unchecked Sendable {
    public let pid: pid_t
    private let condition = NSCondition()
    private var status: ExitStatus?

    /// posix_spawn in a new session (so the pid is also the process group), stdin from
    /// /dev/null, stdout and stderr appended to `logPath`, and only `inheritFD` inherited.
    public static func spawn(argv: [String], logPath: String, inheritFD: Int32) throws -> VMProcess {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGUSR1] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addinherit_np(&actions, inheritFD)

        let flagsNow = fcntl(inheritFD, F_GETFD)
        guard flagsNow >= 0, fcntl(inheritFD, F_SETFD, flagsNow & ~FD_CLOEXEC) == 0 else {
            throw SpawnError.failed("fcntl lock fd \(inheritFD)", errno)
        }

        let cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, environ)
        guard rc == 0 else { throw SpawnError.failed("posix_spawn \(argv[0])", rc) }
        return VMProcess(child: pid)
    }

    private init(child pid: pid_t) {
        self.pid = pid
        let thread = Thread { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
            finish(ExitStatus(waitStatus: raw))
        }
        thread.name = "qemu-wait"
        thread.start()
    }

    public init(adopting pid: pid_t) {
        self.pid = pid
        let thread = Thread { [self] in
            while kill(pid, 0) == 0 || errno == EPERM { usleep(100_000) }
            finish(ExitStatus(code: nil, signal: nil))
        }
        thread.name = "qemu-poll"
        thread.start()
    }

    private func finish(_ value: ExitStatus) {
        condition.lock()
        status = value
        condition.broadcast()
        condition.unlock()
    }

    public var exitStatus: ExitStatus? {
        condition.lock(); defer { condition.unlock() }
        return status
    }

    @discardableResult
    public func wait(timeout: TimeInterval? = nil) -> ExitStatus? {
        let deadline = timeout.map { Date().addingTimeInterval($0) } ?? .distantFuture
        condition.lock()
        defer { condition.unlock() }
        while status == nil {
            if !condition.wait(until: deadline) { break }
        }
        return status
    }

    /// Signals the whole process group; a no-op once the process is gone.
    public func signalGroup(_ sig: Int32) {
        condition.lock()
        defer { condition.unlock() }
        if status == nil { kill(-pid, sig) }
    }
}

public enum Readiness: Equatable, Sendable {
    case processAlive
    case qmpReady
    case guestShutdown
    case exited(ExitStatus)
}

public final class Lifecycle: @unchecked Sendable {
    public let process: VMProcess
    public let qmpSocket: String
    public var powerdownTimeout: TimeInterval = 20
    /// FydeOS runs Chrome with --aura-legacy-power-button: the first press opens
    /// the power menu, a second press while it is open shuts down.
    public var powerButtonRepeatDelay: TimeInterval = 2
    public var quitTimeout: TimeInterval = 5
    public var termTimeout: TimeInterval = 3
    public var log: (String) -> Void = { _ in }
    private let stateLock = NSLock()
    private var _readiness = Readiness.processAlive

    public init(process: VMProcess, qmpSocket: String) {
        self.process = process
        self.qmpSocket = qmpSocket
    }

    public var readiness: Readiness {
        stateLock.lock(); defer { stateLock.unlock() }
        if let status = process.exitStatus { return .exited(status) }
        return _readiness
    }

    private func advance(to state: Readiness) {
        stateLock.lock()
        _readiness = state
        stateLock.unlock()
    }

    /// QMP readiness only means QEMU is up; it says nothing about the guest.
    public func waitForQMP(timeout: TimeInterval = 30) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = QMPError.timeout("socket \(qmpSocket)")
        while Date() < deadline {
            if let status = process.exitStatus {
                throw SpawnError.failed("QEMU exited before QMP was ready (\(status))", 0)
            }
            do {
                let client = try QMPClient.connect(path: qmpSocket)
                defer { client.close() }
                _ = try client.queryStatus()
                advance(to: .qmpReady)
                return
            } catch {
                lastError = error
                usleep(200_000)
            }
        }
        throw lastError
    }

    private func connect() -> QMPClient? {
        do {
            return try QMPClient.connect(path: qmpSocket) { [weak self] event in
                self?.log("QMP event \(event.name)")
                if event.name == "SHUTDOWN" { self?.advance(to: .guestShutdown) }
            }
        } catch {
            log("QMP unavailable: \(error)")
            return nil
        }
    }

    /// system_powerdown, QMP quit after `powerdownTimeout`, SIGTERM to the group,
    /// SIGKILL after `termTimeout`. `force` starts at quit.
    @discardableResult
    public func shutdown(force: Bool = false) -> ExitStatus {
        if let status = process.exitStatus { return status }
        if !force {
            log("system_powerdown twice, \(Int(powerButtonRepeatDelay)) s apart, waiting \(Int(powerdownTimeout)) s")
            if let client = connect() {
                defer { client.close() }
                do { try client.systemPowerdown() } catch { log("system_powerdown: \(error)") }
                if let status = process.wait(timeout: powerButtonRepeatDelay) { return status }
                do { try client.systemPowerdown() } catch { log("second system_powerdown: \(error)") }
                if let status = process.wait(timeout: powerdownTimeout - powerButtonRepeatDelay) { return status }
            }
        }
        log("quit, waiting \(Int(quitTimeout)) s")
        if let client = connect() {
            do { try client.quit() } catch { log("quit: \(error)") }
            client.close()
        }
        if let status = process.wait(timeout: quitTimeout) { return status }
        log("SIGTERM to process group \(process.pid), waiting \(Int(termTimeout)) s")
        process.signalGroup(SIGTERM)
        if let status = process.wait(timeout: termTimeout) { return status }
        log("SIGKILL to process group \(process.pid)")
        process.signalGroup(SIGKILL)
        return process.wait()!
    }
}
