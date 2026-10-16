import Darwin
import Foundation
import TryFydeOSCore

struct UsageError: Error, CustomStringConvertible {
    var description: String
}

let usage = """
usage: tryfydeos <command> [options]

  doctor                      check host, runtime, firmware, factory image, workspace
  prepare                     verify the factory image and clone the VM disk
  run [vm options]            prepare if needed, boot the VM, supervise until QEMU exits
  inspect [vm options]        print the QEMU argv run would use
  status                      show workspace, last run and live QMP state
  shutdown [--force]          powerdown ladder (--force starts at QMP quit)
  reset --yes                 delete disk.img, efi-vars.fd and metadata.json

vm options: --cpus N (4)  --memory MiB (8192)  --fullscreen  --microphone
            --forward HOSTPORT:GUESTPORT (repeatable, 127.0.0.1 only)  --gl native|angle
all commands: --workspace PATH (default ~/Library/Application Support/Try FydeOS/VM/v1)
"""

struct Options {
    var workspace = Workspace.defaultURL
    var launch = LaunchOptions()
    var force = false
    var yes = false

    init(_ args: ArraySlice<String>, allowed: Set<String>) throws {
        var it = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw UsageError(description: "\(flag) needs a value") }
            return v
        }
        func int(_ flag: String) throws -> Int {
            let v = try value(flag)
            guard let n = Int(v) else { throw UsageError(description: "\(flag) needs an integer, got '\(v)'") }
            return n
        }
        while let arg = it.next() {
            guard allowed.contains(arg) || arg == "--workspace" else { throw UsageError(description: "unknown option \(arg)") }
            switch arg {
            case "--workspace": workspace = URL(fileURLWithPath: (try value(arg) as NSString).expandingTildeInPath)
            case "--cpus": launch.cpus = try int(arg)
            case "--memory": launch.memoryMiB = try int(arg)
            case "--fullscreen": launch.fullScreen = true
            case "--microphone": launch.microphone = true
            case "--forward": launch.hostForwards.append(try HostForward(parsing: try value(arg)))
            case "--gl":
                let v = try value(arg)
                guard let g = GLBackend(rawValue: v) else { throw UsageError(description: "--gl must be native or angle, got '\(v)'") }
                launch.glBackend = g
            case "--force": force = true
            case "--yes": yes = true
            default: throw UsageError(description: "unknown option \(arg)")
            }
        }
    }
}

let vmFlags: Set<String> = ["--cpus", "--memory", "--fullscreen", "--microphone", "--forward", "--gl"]

func say(_ message: String) {
    FileHandle.standardError.write(Data("tryfydeos: \(message)\n".utf8))
}

func report(_ state: String, _ what: String) {
    print(state.padding(toLength: 8, withPad: " ", startingAt: 0) + " " + what)
}

func shellQuote(_ s: String) -> String {
    s.allSatisfy({ $0.isLetter || $0.isNumber || "-_=,.:/+@".contains($0) }) ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func jsonText(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
}

func prepare(_ ws: Workspace, _ lock: StorageLock, _ loc: Locations) throws -> Metadata {
    let spec = try FactorySpec.load(loc.factorySpec)
    let metadata = try ws.prepare(lock: lock, locations: loc) { spec, image in
        say("verifying sha256 of \(image.path) (\(spec.image.bytes) bytes, once per VM)")
    }
    if metadata.factory.sha256 != spec.image.sha256 {
        say("note: this VM was cloned from factory \(metadata.factory.sha256.prefix(12)); spec now pins \(spec.image.sha256.prefix(12)) (reset to switch)")
    }
    return metadata
}

func cmdDoctor(_ o: Options) throws -> Int32 {
    var failed = false
    func check(_ ok: Bool, _ what: String, missing: Bool = false) {
        report(ok ? "ok" : missing ? "missing" : "FAIL", what)
        if !ok { failed = true }
    }
    let host = HostInfo.current()
    let major = Int(host.macOSVersion.split(separator: ".").first ?? "0") ?? 0
    check(host.isAppleSilicon && !host.isTranslated && major >= 15, "Apple Silicon macOS >= 15 (macOS \(host.macOSVersion), native: \(!host.isTranslated))")
    report("info", "host \(host.logicalCores) cores, \(host.memoryMiB) MiB; VM range cpus 4...\(host.logicalCores), memory 4096...\(host.memoryMiB - VMConfig.hostReserveMiB) MiB")
    let loc = try Locations.discover()
    report("info", "repo \(loc.root?.path ?? "-"), bundle resources \(loc.bundleResources?.path ?? "-")")
    let fm = FileManager.default
    if fm.isExecutableFile(atPath: loc.qemu.path) {
        let p = Process()
        p.executableURL = loc.qemu
        p.arguments = ["-version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        check(p.terminationStatus == 0, "runtime \(loc.qemu.path): \(out.split(separator: "\n").first ?? "?")")
    } else {
        check(false, "runtime \(loc.qemu.path)", missing: true)
    }
    let sums = (try? String(contentsOf: loc.firmwareSums, encoding: .utf8)) ?? ""
    for line in sums.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { continue }
        let file = loc.firmware.appendingPathComponent(String(parts[1]))
        if !fm.fileExists(atPath: file.path) { check(false, "firmware \(file.path)", missing: true); continue }
        check((try? FactorySpec.sha256(of: file)) == String(parts[0]), "firmware \(file.path)")
    }
    let spec = try FactorySpec.load(loc.factorySpec)
    report("info", "factory spec \(spec.image.file) \(spec.image.version) \(spec.board)")
    let image = loc.factoryImage(spec)
    if let attrs = try? fm.attributesOfItem(atPath: image.path) {
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        check(size == spec.image.bytes, "factory image \(image.path) size \(size) (sha256 checked by prepare)")
    } else {
        check(false, "factory image \(image.path)", missing: true)
    }
    let ws = Workspace(url: o.workspace)
    switch ws.state {
    case .absent: report("info", "workspace \(ws.url.path) absent (prepare creates it)")
    case .empty: report("info", "workspace \(ws.url.path) empty")
    case .marked:
        let fs = (try? ws.filesystemType()) ?? "?"
        check(fs == "apfs", "workspace \(ws.url.path) on \(fs), prepared: \(ws.isPrepared), in use: \(ws.isLocked)")
    case .foreign(let why): check(false, "workspace \(ws.url.path): \(why)")
    }
    return failed ? 1 : 0
}

func cmdPrepare(_ o: Options) throws -> Int32 {
    let loc = try Locations.discover()
    let ws = Workspace(url: o.workspace)
    let lock = try ws.open()
    let metadata = try prepare(ws, lock, loc)
    print("prepared \(ws.url.path)")
    print("factory \(metadata.factory.file) sha256 \(metadata.factory.sha256)")
    print("mac \(metadata.mac) created \(metadata.created)")
    return 0
}

func cmdInspect(_ o: Options) throws -> Int32 {
    let loc = try Locations.discover()
    let ws = Workspace(url: o.workspace)
    let mac = ws.loadMetadata()?.mac ?? "52:54:00:00:00:00"
    let console = ws.runsDir.appendingPathComponent("<run-id>/console.log")
    let argv = try o.launch.config(locations: loc, workspace: ws, console: console, mac: mac, lockFD: 3).argv(host: .current())
    var lines = [shellQuote(argv[0])]
    var i = 1
    while i < argv.count {
        if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") {
            lines.append("  \(argv[i]) \(shellQuote(argv[i + 1]))")
            i += 2
        } else {
            lines.append("  \(argv[i])")
            i += 1
        }
    }
    print(lines.joined(separator: " \\\n"))
    return 0
}

func cmdRun(_ o: Options) throws -> Int32 {
    let loc = try Locations.discover()
    let ws = Workspace(url: o.workspace)
    let lock = try ws.open()
    let metadata = try prepare(ws, lock, loc)
    let session = try VMSession.launch(options: o.launch, locations: loc, workspace: ws, lock: lock, metadata: metadata, echo: say)
    var sources: [DispatchSourceSignal] = []
    for (sig, force) in [(SIGINT, false), (SIGTERM, false), (SIGUSR1, true)] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            session.requestShutdown(force: force, reason: "received signal \(sig), shutting down\(force ? " (force)" : "")")
        }
        source.resume()
        sources.append(source)
    }
    signal(SIGPIPE, SIG_IGN)
    try? session.waitForQMP()
    let status = session.waitForExit()
    _ = sources
    return status.code ?? 1
}

func cmdStatus(_ o: Options) throws -> Int32 {
    let ws = Workspace(url: o.workspace)
    print("workspace \(ws.url.path)")
    print("state \(ws.state), prepared \(ws.isPrepared), in use \(ws.isLocked)")
    if let m = ws.loadMetadata() { print("factory \(m.factory.sha256) mac \(m.mac) created \(m.created)") }
    guard let (dir, r) = ws.lastRunRecord() else { print("no runs"); return 0 }
    print("last run \(r.id) (\(dir.path))")
    print("  qemu pid \(r.pid.map(String.init) ?? "-"), supervisor pid \(r.supervisorPid), start \(r.start), qmp ready \(r.qmpReady ?? "-")")
    if let end = r.end {
        print("  end \(end), exit code \(r.exitCode.map(String.init) ?? "-"), signal \(r.signal.map(String.init) ?? "-")")
        return 0
    }
    guard ws.isLocked else { print("  not running (record has no end; supervisor died?)"); return 0 }
    do {
        let client = try QMPClient.connect(path: ws.qmpSocket.path)
        defer { client.close() }
        print("  query-status: \(jsonText(try client.execute("query-status")))")
        print("  query-mice: \(jsonText(try client.execute("query-mice")))")
    } catch {
        print("  QMP: \(error)")
    }
    return 0
}

func cmdShutdown(_ o: Options) throws -> Int32 {
    let ws = Workspace(url: o.workspace)
    guard ws.isLocked else { print("not running"); return 0 }
    guard let (dir, r) = ws.lastRunRecord(), r.end == nil else {
        throw UsageError(description: "storage is locked but the last run record has ended; not signalling anything")
    }
    if executablePath(of: r.supervisorPid)?.hasSuffix("/tryfydeos") == true {
        say("asking supervisor \(r.supervisorPid) to shut down\(o.force ? " (force)" : "")")
        kill(r.supervisorPid, o.force ? SIGUSR1 : SIGTERM)
        let deadline = Date().addingTimeInterval(60)
        while ws.isLocked && Date() < deadline { usleep(200_000) }
        guard !ws.isLocked else { throw UsageError(description: "still running after 60 s") }
        let end = ws.lastRunRecord()?.record
        print("stopped: exit code \(end?.exitCode.map(String.init) ?? "-"), signal \(end?.signal.map(String.init) ?? "-")")
        return 0
    }
    guard let pid = r.pid, let path = executablePath(of: pid), path == URL(fileURLWithPath: r.argv[0]).resolvingSymlinksInPath().path else {
        throw UsageError(description: "storage is locked but neither the supervisor nor QEMU of run \(r.id) is alive")
    }
    say("supervisor gone; running the ladder against QEMU pid \(pid)")
    let lifecycle = Lifecycle(process: VMProcess(adopting: pid), qmpSocket: ws.qmpSocket.path)
    lifecycle.log = { say($0) }
    let status = lifecycle.shutdown(force: o.force)
    var record = r
    record.end = utcTimestamp()
    try Workspace.writeRunRecord(record, in: dir)
    print("stopped: \(status)")
    return 0
}

func cmdReset(_ o: Options) throws -> Int32 {
    guard o.yes else { throw UsageError(description: "reset deletes the VM disk; pass --yes") }
    let ws = Workspace(url: o.workspace)
    guard ws.state == .marked else { throw UsageError(description: "\(ws.url.path) is not a Try FydeOS workspace (\(ws.state))") }
    let lock = try ws.open()
    try ws.reset(lock: lock)
    print("reset \(ws.url.path): disk.img, efi-vars.fd and metadata.json removed; runs/ kept")
    return 0
}

let args = CommandLine.arguments.dropFirst()
let commands: [String: (Set<String>, (Options) throws -> Int32)] = [
    "doctor": ([], cmdDoctor), "prepare": ([], cmdPrepare), "run": (vmFlags, cmdRun),
    "inspect": (vmFlags, cmdInspect), "status": ([], cmdStatus), "shutdown": (["--force"], cmdShutdown),
    "reset": (["--yes"], cmdReset),
]
guard let name = args.first, let (flags, command) = commands[name] else {
    print(usage)
    exit(args.first.map { ["-h", "--help", "help"].contains($0) } == true ? 0 : 2)
}
do {
    exit(try command(Options(args.dropFirst(), allowed: flags)))
} catch let error as UsageError {
    say(error.description)
    exit(2)
} catch {
    say("\(error)")
    exit(1)
}
