import Darwin
import Foundation
import Testing
@testable import TryFydeOSCore

/// One-connection Unix socket server that runs `script` on its own thread.
final class FakeQMP: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private var client: Int32 = -1
    private var pending = Data()
    let done = DispatchSemaphore(value: 0)

    init(script: @escaping @Sendable (FakeQMP) -> Void) throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("q\(UUID().uuidString.prefix(6)).sock").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8 + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(listener, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread { [self] in
            client = accept(listener, nil, nil)
            script(self)
            close(client)
            close(listener)
            unlink(path)
            done.signal()
        }.start()
    }

    func send(_ text: String) {
        _ = text.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
        usleep(20_000)
    }

    func readLine() -> [String: Any]? {
        var byte: UInt8 = 0
        while true {
            if let nl = pending.firstIndex(of: 0x0a) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            guard read(client, &byte, 1) == 1 else { return nil }
            pending.append(byte)
        }
    }

    func expect(_ command: String) -> Int {
        guard let msg = readLine(), msg["execute"] as? String == command, let id = (msg["id"] as? NSNumber)?.intValue else {
            return -1
        }
        return id
    }
}

let greeting = #"{"QMP": {"version": {"qemu": {"micro": 1, "minor": 1, "major": 11}, "package": ""}, "capabilities": []}}"#

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ e: QMPEvent) { lock.lock(); names.append(e.name); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

@Test func splitAndCoalescedMessagesAndEvents() throws {
    let server = try FakeQMP { s in
        let half = greeting.index(greeting.startIndex, offsetBy: 20)
        s.send(String(greeting[..<half]))
        s.send(String(greeting[half...]) + "\r\n")
        let caps = s.expect("qmp_capabilities")
        s.send(#"{"return": {}, "id": \#(caps)}"# + "\r\n" + #"{"timestamp": {"seconds": 1, "microseconds": 2}, "event": "RESUME"}"# + "\r\n")
        let status = s.expect("query-status")
        let reply = #"{"return": {"status": "running", "singlestep": false, "running": true}, "id": \#(status)}"#
        let cut = reply.index(reply.startIndex, offsetBy: 17)
        s.send(#"{"event": "POWERDOWN", "data": {}, "timestamp": {"seconds": 3, "microseconds": 0}}"# + "\r\n" + String(reply[..<cut]))
        s.send(String(reply[cut...]) + "\r")
        s.send("\n")
        let mice = s.expect("query-mice")
        s.send(#"{"return": [{"name": "QEMU Virtio Tablet", "index": 2, "current": true, "absolute": true}], "id": \#(mice)}"# + "\r\n")
        let bad = s.expect("system_powerdown")
        s.send(#"{"id": \#(bad), "error": {"class": "GenericError", "desc": "nope"}}"# + "\r\n")
        _ = s.readLine()
    }
    let events = EventBox()
    let client = try QMPClient.connect(path: server.path) { events.add($0) }
    #expect((client.greetingInfo?["QMP"] as? [String: Any]) != nil)
    let status = try client.queryStatus()
    #expect(status.status == "running" && status.running)
    #expect(try client.queryMice() == [QMPMouse(name: "QEMU Virtio Tablet", index: 2, current: true, absolute: true)])
    #expect(throws: QMPError.self) { try client.systemPowerdown() }
    #expect(events.all == ["RESUME", "POWERDOWN"])
    client.close()
    #expect(server.done.wait(timeout: .now() + 5) == .success)
}

@Test func experimentalCommandsAreRefusedLocally() throws {
    let server = try FakeQMP { s in
        s.send(greeting + "\r\n")
        let caps = s.expect("qmp_capabilities")
        s.send(#"{"return": {}, "id": \#(caps)}"# + "\r\n")
        let next = s.expect("query-status")
        s.send(#"{"return": {"status": "paused", "running": false}, "id": \#(next)}"# + "\r\n")
        _ = s.readLine()
    }
    let client = try QMPClient.connect(path: server.path)
    #expect(throws: QMPError.self) { try client.execute("x-query-virtio-status", arguments: ["path": "/machine"]) }
    #expect(try client.queryStatus().status == "paused")
    client.close()
    #expect(server.done.wait(timeout: .now() + 5) == .success)
}

@Test func replyTimeout() throws {
    let server = try FakeQMP { s in
        s.send(greeting + "\r\n")
        let caps = s.expect("qmp_capabilities")
        s.send(#"{"return": {}, "id": \#(caps)}"# + "\r\n")
        _ = s.readLine()
        _ = s.readLine()
    }
    let client = try QMPClient.connect(path: server.path, timeout: 0.3)
    let start = Date()
    #expect(throws: QMPError.self) { try client.stop() }
    #expect(Date().timeIntervalSince(start) < 2)
    client.close()
    #expect(server.done.wait(timeout: .now() + 5) == .success)
}

@Test func missingGreetingTimesOut() throws {
    let server = try FakeQMP { s in _ = s.readLine() }
    #expect(throws: QMPError.self) { try QMPClient.connect(path: server.path, timeout: 0.3) }
    #expect(server.done.wait(timeout: .now() + 5) == .success)
}

@Test func connectToMissingSocketFails() {
    #expect(throws: QMPError.self) { try QMPClient.connect(path: "/nonexistent/qmp.sock") }
}
