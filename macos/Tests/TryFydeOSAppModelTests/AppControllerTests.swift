import Foundation
import Testing
import TryFydeOSCore
@testable import TryFydeOSAppModel

final class FakeDriver: VMDriver {
    var calls: [String] = []
    var events: ((VMEvent) -> Void)?
    var resetError: Error?
    var prepared: FactoryRecord?

    func launch(_ options: LaunchOptions, events: @escaping (VMEvent) -> Void) {
        calls.append("launch \(options.cpus) \(options.memoryMiB)")
        self.events = events
    }
    func shutDown() { calls.append("shutDown") }
    func pauseForSleep() { calls.append("pause") }
    func resumeAfterWake() { calls.append("resume") }
    func factoryReset() throws {
        calls.append("reset")
        if let resetError { throw resetError }
    }
    func checkRelease(events: @escaping (VMEvent) -> Void) {
        calls.append("release")
        self.events = events
    }
    func preparedFactory() -> FactoryRecord? { prepared }
    func emit(_ e: VMEvent) { events?(e) }
}

func makeController() -> (AppController, FakeDriver, Box) {
    let driver = FakeDriver()
    let c = AppController(driver: driver)
    let box = Box()
    c.now = { Date(timeIntervalSince1970: 1000) }
    c.onStateChange = { box.states.append($0) }
    c.onError = { box.errorTitles.append($0); box.errors.append($1) }
    c.onReadyToQuit = { box.quitReady += 1 }
    return (c, driver, box)
}

final class Box {
    var states: [AppState] = []
    var errors: [String] = []
    var errorTitles: [String] = []
    var quitReady = 0
}

let ok = ExitStatus(code: 0, signal: nil)

@Test func fullCycle() {
    let (c, d, box) = makeController()
    #expect(c.canLaunch && !c.canShutDown && c.canFactoryReset)
    c.launch(LaunchOptions(cpus: 6, memoryMiB: 8192))
    #expect(c.state == .preparing(stage: nil, bytes: 0, total: 0) && !c.canLaunch && !c.canShutDown && !c.canFactoryReset)
    d.emit(.starting(pid: 4242))
    #expect(c.state == .starting && c.canShutDown && c.vmPid == 4242)
    d.emit(.running)
    #expect(c.state == .running(since: Date(timeIntervalSince1970: 1000)))
    c.shutDown()
    #expect(c.state == .shuttingDown && !c.canShutDown && !c.canLaunch)
    d.emit(.exited(ok))
    #expect(c.state == .notRunning(L(.lastRunShutDown, "exit code 0")))
    #expect(d.calls == ["launch 6 8192", "shutDown"])
    #expect(box.states.count == 5 && box.errors.isEmpty && box.quitReady == 0)
    #expect(c.canLaunch)
}

@Test func prepareProgressUpdatesPreparingOnly() {
    let (c, d, _) = makeController()
    c.launch(LaunchOptions())
    d.emit(.preparing(stage: .downloading, bytes: 50, total: 100))
    #expect(c.state == .preparing(stage: .downloading, bytes: 50, total: 100))
    d.emit(.preparing(stage: .converting, bytes: 10, total: 100))
    #expect(c.state == .preparing(stage: .converting, bytes: 10, total: 100))
    d.emit(.starting(pid: 4242))
    d.emit(.preparing(stage: .converting, bytes: 100, total: 100))
    #expect(c.state == .starting)
}

@Test func guestPowerOffReturnsToNotRunning() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    d.emit(.starting(pid: 4242)); d.emit(.running); d.emit(.exited(ok))
    #expect(c.state == .notRunning(L(.lastRunStopped, "exit code 0")))
    #expect(box.errors.isEmpty)
}

@Test func unexpectedExitIsAnError() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    d.emit(.starting(pid: 4242)); d.emit(.running); d.emit(.exited(ExitStatus(code: 1, signal: nil)))
    #expect(c.state == .failed(L(.errorUnexpectedExit, "exit code 1")))
    #expect(box.errors.count == 1 && c.canLaunch)
    #expect(box.errorTitles == [L(.errorAlertTitle)])
}

@Test func prepareFailureIsAnError() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    d.emit(.failed("refusing to use /x: foreign"))
    #expect(c.state == .failed("refusing to use /x: foreign"))
    #expect(c.state.statusText { _ in "" } == "refusing to use /x: foreign")
    #expect(box.errors == ["refusing to use /x: foreign"])
    #expect(box.errorTitles == [L(.errorLaunchTitle)])
    c.launch(LaunchOptions())
    #expect(c.state == .preparing(stage: nil, bytes: 0, total: 0))
}

@Test func quitWhileIdleIsImmediate() {
    let (c, d, _) = makeController()
    #expect(c.requestQuit())
    #expect(d.calls.isEmpty)
}

@Test func quitWhileRunningWaitsForExit() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    d.emit(.starting(pid: 4242)); d.emit(.running)
    #expect(!c.requestQuit())
    #expect(c.state == .shuttingDown && d.calls.last == "shutDown")
    #expect(!c.requestQuit())
    #expect(d.calls.filter { $0 == "shutDown" }.count == 1)
    #expect(box.quitReady == 0)
    d.emit(.exited(ok))
    #expect(box.quitReady == 1)
}

@Test func quitWhilePreparingShutsDownOnceSpawned() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    #expect(!c.requestQuit())
    #expect(!d.calls.contains("shutDown") && !c.canLaunch)
    d.emit(.starting(pid: 4242))
    #expect(c.state == .shuttingDown && d.calls.last == "shutDown")
    d.emit(.running)
    #expect(c.state == .shuttingDown)
    d.emit(.exited(ok))
    #expect(box.quitReady == 1)
}

@Test func quitWhilePreparingThatFailsQuitsWithoutAlert() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    #expect(!c.requestQuit())
    d.emit(.failed("boom"))
    #expect(box.quitReady == 1 && box.errors.isEmpty)
}

@Test func sleepOnlyPausesARunningVM() {
    let (c, d, _) = makeController()
    c.willSleep(); c.didWake()
    #expect(d.calls.isEmpty)
    c.launch(LaunchOptions())
    d.emit(.starting(pid: 4242))
    c.willSleep()
    #expect(!d.calls.contains("pause"))
    d.emit(.running)
    c.willSleep(); c.didWake()
    #expect(d.calls.suffix(2) == ["pause", "resume"])
}

@Test func factoryResetOnlyWhenIdle() throws {
    let (c, d, _) = makeController()
    c.launch(LaunchOptions())
    #expect(throws: ConfigError.self) { try c.factoryReset() }
    d.emit(.failed("x"))
    try c.factoryReset()
    #expect(c.state == .notRunning(L(.resetDone)))
    d.resetError = ConfigError.invalid("busy")
    #expect(throws: ConfigError.self) { try c.factoryReset() }
    #expect(d.calls.filter { $0 == "reset" }.count == 2)
}

@Test func statusTexts() {
    #expect(AppState.notRunning(nil).statusText { _ in "" } == "Not running")
    #expect(AppState.running(since: Date()).statusText { _ in "09:41" } == "Running since 09:41")
    #expect(AppState.shuttingDown.statusText { _ in "" } == "Shutting down…")
    #expect(AppState.preparing(stage: nil, bytes: 0, total: 0).statusText { _ in "" } == "Preparing…")
    #expect(AppState.preparing(stage: .downloading, bytes: 0, total: 0).statusText { _ in "" } == "Preparing…")
    #expect(AppState.preparing(stage: .downloading, bytes: 50, total: 200).statusText { _ in "" } == "Downloading FydeOS… 25%")
    #expect(AppState.preparing(stage: .converting, bytes: 150, total: 200).statusText { _ in "" } == "Converting FydeOS… 75%")
}

@Test func controllerStatusFollowsState() {
    let (c, d, _) = makeController()
    #expect(c.statusText { _ in "" } == L(.statusNotRunning))
    c.launch(LaunchOptions())
    #expect(c.statusText { _ in "" } == L(.statusPreparing))
    d.emit(.preparing(stage: .converting, bytes: 3, total: 4))
    #expect(c.statusText { _ in "" } == L(.statusConverting, 75))
}

@Test func updateNoticeOnlyForAVMFromAnotherImage() {
    let (c, d, _) = makeController()
    var changes = 0
    c.onReleaseChange = { changes += 1 }
    c.checkRelease()
    #expect(c.updateRelease == nil && d.calls == ["release"])
    let r = Release(version: "23.2", releaseDate: "2026-12-01", fileName: "f.zip", sha256: String(repeating: "b", count: 64), url: "https://x/f.zip")
    d.emit(.release(r))
    #expect(changes == 1 && c.updateRelease == nil)
    #expect(c.state == .notRunning(nil))
    d.prepared = FactoryRecord(fileName: "old.zip", sha256: String(repeating: "a", count: 64))
    #expect(c.updateRelease == r)
    #expect(L(.updateAvailable, r.version, r.releaseDate) == "FydeOS 23.2 (2026-12-01) is available. Factory reset installs it.")
    #expect(L(.resetMessageUpdate, r.version, r.releaseDate) == "Erase this VM and install FydeOS 23.2 (2026-12-01)?")
    d.prepared?.sha256 = r.sha256
    #expect(c.updateRelease == nil)
}
