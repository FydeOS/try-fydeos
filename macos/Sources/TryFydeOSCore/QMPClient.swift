import Darwin
import Foundation

public enum QMPError: Error, CustomStringConvertible {
    case connect(String, Int32)
    case timeout(String)
    case closed
    case refused(String)
    case command(String, String, String)
    case malformed(String)

    public var description: String {
        switch self {
        case .connect(let path, let code): return "QMP connect \(path): \(String(cString: strerror(code)))"
        case .timeout(let what): return "QMP timeout waiting for \(what)"
        case .closed: return "QMP connection closed"
        case .refused(let cmd): return "QMP command \(cmd) refused: x- commands are unstable and can abort QEMU"
        case .command(let cmd, let cls, let desc): return "QMP \(cmd) failed: \(cls): \(desc)"
        case .malformed(let line): return "QMP malformed message: \(line)"
        }
    }
}

public struct QMPEvent: @unchecked Sendable {
    public var name: String
    public var data: [String: Any]
}

public struct QMPMouse: Equatable, Sendable {
    public var name: String
    public var index: Int
    public var current: Bool
    public var absolute: Bool
}

/// QMP over a Unix socket: one reader thread splits newline-delimited JSON, matches
/// replies to requests by id and hands events to `eventHandler`, which runs on the
/// reader thread and must not call `execute`.
public final class QMPClient: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 2

    public let timeout: TimeInterval
    private let fd: Int32
    private let lock = NSCondition()
    private var nextID = 1
    private var replies: [Int: [String: Any]] = [:]
    private var greeting: [String: Any]?
    private var isClosed = false
    private var fdOpen = true
    private let eventHandler: ((QMPEvent) -> Void)?

    public static func connect(path: String, timeout: TimeInterval = defaultTimeout,
                               eventHandler: ((QMPEvent) -> Void)? = nil) throws -> QMPClient {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QMPError.connect(path, errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { Darwin.close(fd); throw QMPError.connect(path, ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { let code = errno; Darwin.close(fd); throw QMPError.connect(path, code) }
        let client = QMPClient(fd: fd, timeout: timeout, eventHandler: eventHandler)
        do {
            try client.handshake()
        } catch {
            client.close()
            throw error
        }
        return client
    }

    private init(fd: Int32, timeout: TimeInterval, eventHandler: ((QMPEvent) -> Void)?) {
        self.fd = fd
        self.timeout = timeout
        self.eventHandler = eventHandler
        let thread = Thread { [self] in readLoop() }
        thread.name = "qmp-reader"
        thread.start()
    }

    public var greetingInfo: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return greeting
    }

    private func handshake() throws {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        while greeting == nil && !isClosed {
            if !lock.wait(until: deadline) { break }
        }
        let ok = greeting != nil
        let closed = isClosed
        lock.unlock()
        guard ok else { throw closed ? QMPError.closed : QMPError.timeout("greeting (another client may hold the QMP socket)") }
        _ = try execute("qmp_capabilities")
    }

    @discardableResult
    public func execute(_ command: String, arguments: [String: Any]? = nil, timeout: TimeInterval? = nil) throws -> Any {
        guard !command.hasPrefix("x-") else { throw QMPError.refused(command) }
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        var message: [String: Any] = ["execute": command, "id": id]
        if let arguments { message["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(contentsOf: [0x0d, 0x0a])
        try writeAll(data)

        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        lock.lock()
        defer { lock.unlock() }
        while replies[id] == nil && !isClosed {
            if !lock.wait(until: deadline) { break }
        }
        guard let reply = replies.removeValue(forKey: id) else {
            throw isClosed ? QMPError.closed : QMPError.timeout(command)
        }
        if let error = reply["error"] as? [String: Any] {
            throw QMPError.command(command, error["class"] as? String ?? "?", error["desc"] as? String ?? "?")
        }
        return reply["return"] ?? [String: Any]()
    }

    public func close() {
        lock.lock()
        isClosed = true
        if fdOpen { shutdown(fd, SHUT_RDWR) }
        lock.broadcast()
        lock.unlock()
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw QMPError.closed
                }
                offset += n
            }
        }
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                dispatch(line)
            }
        }
        lock.lock()
        isClosed = true
        fdOpen = false
        Darwin.close(fd)
        lock.broadcast()
        lock.unlock()
    }

    private func dispatch(_ line: Data) {
        let trimmed = line.filter { $0 != 0x0d && $0 != 0x20 && $0 != 0x09 }
        guard !trimmed.isEmpty else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let name = object["event"] as? String {
            eventHandler?(QMPEvent(name: name, data: object["data"] as? [String: Any] ?? [:]))
            return
        }
        lock.lock()
        if object["QMP"] != nil {
            greeting = object
        } else if let id = (object["id"] as? NSNumber)?.intValue {
            replies[id] = object
        }
        lock.broadcast()
        lock.unlock()
    }

    public func queryStatus() throws -> (status: String, running: Bool) {
        guard let r = try execute("query-status") as? [String: Any], let status = r["status"] as? String else {
            throw QMPError.malformed("query-status")
        }
        return (status, r["running"] as? Bool ?? false)
    }

    public func queryMice() throws -> [QMPMouse] {
        guard let list = try execute("query-mice") as? [[String: Any]] else { throw QMPError.malformed("query-mice") }
        return list.map {
            QMPMouse(name: $0["name"] as? String ?? "", index: ($0["index"] as? NSNumber)?.intValue ?? -1,
                     current: $0["current"] as? Bool ?? false, absolute: $0["absolute"] as? Bool ?? false)
        }
    }

    public func systemPowerdown() throws { try execute("system_powerdown") }
    public func quit() throws { try execute("quit") }
    public func stop() throws { try execute("stop") }
    public func cont() throws { try execute("cont") }
}
