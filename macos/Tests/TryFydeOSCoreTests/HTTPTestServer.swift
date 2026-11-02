import Darwin
import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// Sends the full Content-Length but only this many body bytes, then closes the connection.
    var cutAfter: Int?
    var delay: TimeInterval = 0

    /// Serves `data` honouring a single `bytes=a-` or `bytes=a-b` Range unless `ignoreRange`.
    static func ranged(_ data: Data, _ request: HTTPRequest, ignoreRange: Bool = false) -> HTTPResponse {
        guard !ignoreRange, let range = request.headers["range"], range.hasPrefix("bytes=") else {
            return HTTPResponse(status: 200, body: data)
        }
        let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first.flatMap({ Int($0) }) else { return HTTPResponse(status: 200, body: data) }
        guard first < data.count else {
            return HTTPResponse(status: 416, headers: ["Content-Range": "bytes */\(data.count)"])
        }
        let last = min(parts.count > 1 ? Int(parts[1]) ?? data.count - 1 : data.count - 1, data.count - 1)
        return HTTPResponse(status: 206, headers: ["Content-Range": "bytes \(first)-\(last)/\(data.count)"],
                            body: data.subdata(in: first..<last + 1))
    }
}

/// A plain HTTP/1.1 server on 127.0.0.1, one thread per connection, every answer closes the connection.
final class HTTPTestServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private let lock = NSLock()
    private var received: [HTTPRequest] = []
    private var stopped = false

    var baseURL: String { "http://127.0.0.1:\(port)" }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    init(handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws {
        self.handler = handler
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        listener = fd
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 16) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        port = UInt16(bigEndian: addr.sin_port)
        Thread { [self] in acceptLoop() }.start()
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        if first { close(listener) }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            var fds = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, 1, 100) > 0, !isStopped else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var head = Data()
        var byte: UInt8 = 0
        while !head.ends(with: Data("\r\n\r\n".utf8)) {
            guard read(client, &byte, 1) == 1 else { return }
            head.append(byte)
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers)
        lock.lock(); received.append(request); lock.unlock()
        let response = handler(request)
        if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
        var text = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
        for (key, value) in response.headers { text += "\(key): \(value)\r\n" }
        text += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(text.utf8)
        out.append(response.cutAfter.map { response.body.prefix($0) } ?? response.body)
        out.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(client, buffer.baseAddress! + sent, buffer.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

private extension Data {
    func ends(with suffix: Data) -> Bool { count >= suffix.count && self.suffix(suffix.count) == suffix }
}
