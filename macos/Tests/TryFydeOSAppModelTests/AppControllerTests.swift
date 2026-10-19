import Foundation
import Testing
import TryFydeOSCore
@testable import TryFydeOSAppModel

final class FakeDriver: VMDriver {
    var calls: [String] = []
    var events: ((VMEvent) -> Void)?
    var resetError: Error?

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
    func emit(_ e: VMEvent) { events?(e) }
}

func makeController() -> (AppController, FakeDriver, Box) {
    let driver = FakeDriver()
    let c = AppController(driver: driver)
    let box = Box()
    c.now = { Date(timeIntervalSince1970: 1000) }
    c.onStateChange = { box.states.append($0) }
    c.onError = { box.errors.append($0) }
    c.onReadyToQuit = { box.quitReady += 1 }
    return (c, driver, box)
}

final class Box {
    var states: [AppState] = []
    var errors: [String] = []
    var quitReady = 0
}

let ok = ExitStatus(code: 0, signal: nil)

@Test func fullCycle() {
    let (c, d, box) = makeController()
    #expect(c.canLaunch && !c.canShutDown && c.canFactoryReset)
    c.launch(LaunchOptions(cpus: 6, memoryMiB: 8192))
    #expect(c.state == .preparing(bytes: 0, total: 0) && !c.canLaunch && !c.canShutDown && !c.canFactoryReset)
    d.emit(.starting)
    #expect(c.state == .starting && c.canShutDown)
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
    d.emit(.preparing(bytes: 50, total: 100))
    #expect(c.state == .preparing(bytes: 50, total: 100))
    d.emit(.starting)
    d.emit(.preparing(bytes: 100, total: 100))
    #expect(c.state == .starting)
}

@Test func guestPowerOffReturnsToNotRunning() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    d.emit(.starting); d.emit(.running); d.emit(.exited(ok))
    #expect(c.state == .notRunning(L(.lastRunStopped, "exit code 0")))
    #expect(box.errors.isEmpty)
}

@Test func unexpectedExitIsAnError() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    d.emit(.starting); d.emit(.running); d.emit(.exited(ExitStatus(code: 1, signal: nil)))
    #expect(c.state == .failed(L(.errorUnexpectedExit, "exit code 1")))
    #expect(box.errors.count == 1 && c.canLaunch)
}

@Test func prepareFailureIsAnError() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    d.emit(.failed("refusing to use /x: foreign"))
    #expect(c.state == .failed("refusing to use /x: foreign"))
    #expect(c.state.statusText { _ in "" } == "refusing to use /x: foreign")
    #expect(box.errors == ["refusing to use /x: foreign"])
    c.launch(LaunchOptions())
    #expect(c.state == .preparing(bytes: 0, total: 0))
}

@Test func quitWhileIdleIsImmediate() {
    let (c, d, _) = makeController()
    #expect(c.requestQuit())
    #expect(d.calls.isEmpty)
}

@Test func quitWhileRunningWaitsForExit() {
    let (c, d, box) = makeController()
    c.launch(LaunchOptions())
    d.emit(.starting); d.emit(.running)
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
    d.emit(.starting)
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
    d.emit(.starting)
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
}
