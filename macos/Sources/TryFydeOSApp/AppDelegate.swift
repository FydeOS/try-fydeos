import AppKit
import TryFydeOSAppModel
import TryFydeOSCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let host = HostInfo.current()
    private let log = AppLog()
    private var controller: AppController!
    private var window: StartMenuWindow!
    private var signalSources: [DispatchSourceSignal] = []
    private var autoLaunchPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = Workspace(url: Preferences.workspaceURL(store: defaults))
        log.write("app started, version \(appVersion), workspace \(workspace.url.path)")
        let image = ImageController(driver: CoreImageDriver(log: log))
        controller = AppController(driver: CoreVMDriver(workspace: workspace, log: log), image: image)
        image.onStateChange = { [weak self] state in self?.imageStateChanged(state) }
        image.onError = { [weak self] message in self?.showError(message) }
        window = StartMenuWindow(controller: controller, preferences: Preferences.load(from: defaults, host: host), host: host)
        window.onPreferencesChange = { [weak self] prefs in
            guard let self else { return }
            prefs.save(to: self.defaults)
        }
        window.onLaunch = { [weak self] prefs in self?.launch(prefs) }
        controller.onStateChange = { [weak self] state in self?.stateChanged(state) }
        controller.onError = { [weak self] message in self?.showError(message) }
        controller.onReadyToQuit = { [weak self] in
            self?.log.write("VM stopped, terminating")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        NSApp.mainMenu = makeMainMenu()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log.write("host will sleep")
            self?.controller.willSleep()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log.write("host did wake")
            self?.controller.didWake()
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.log.write("received signal \(sig), quitting")
                // Not from inside this main-queue block: terminateLater spins a nested run loop, and the
                // VM's exit event, itself a main-queue block, could never run while this one is on the stack.
                NSApp.performSelector(onMainThread: #selector(NSApplication.terminate(_:)), with: nil, waitUntilDone: false)
            }
            source.resume()
            signalSources.append(source)
        }
        showStartMenu()
        // Hidden test hooks: `open --args -autoImport YES -autoLaunch YES` import the detected image and
        // launch without a click; they live in the argument domain only, so nothing is persisted.
        if argumentFlag("autoImport") {
            log.write("autoImport requested on the command line")
            image.install()
        }
        if argumentFlag("autoLaunch") {
            log.write("autoLaunch requested on the command line")
            autoLaunchPending = true
            autoLaunchIfReady()
        }
    }

    private func argumentFlag(_ key: String) -> Bool {
        defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil && defaults.bool(forKey: key)
    }

    private func autoLaunchIfReady() {
        guard autoLaunchPending, let image = controller.image, !image.isImporting else { return }
        autoLaunchPending = false
        guard image.isInstalled else { return log.write("autoLaunch skipped: the FydeOS image is not installed") }
        launch(Preferences.load(from: defaults, host: host))
    }

    private func launch(_ prefs: Preferences) {
        var options = prefs.launchOptions
        let forwards = Preferences.hostForwards(store: defaults)
        for error in forwards.errors { log.write("ignoring forward: \(error)") }
        options.hostForwards = forwards.forwards
        controller.launch(options)
    }

    private func imageStateChanged(_ state: ImageState) {
        if case .importing = state {} else { log.write("image \(state)") }
        window.refresh()
        autoLaunchIfReady()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func showStartMenu() {
        NSApp.setActivationPolicy(.regular)
        window.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func stateChanged(_ state: AppState) {
        log.write("state \(state)")
        window.refresh()
        switch state {
        case .starting, .running:
            if window.isVisible && !controller.quitPending {
                window.orderOut(nil)
                NSApp.setActivationPolicy(.accessory)
            }
        case .notRunning, .failed:
            if !controller.quitPending { showStartMenu() }
        case .preparing, .shuttingDown:
            break
        }
    }

    private func showError(_ message: String) {
        log.write("error: \(message)")
        showStartMenu()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L(.errorAlertTitle)
        alert.informativeText = message
        alert.addButton(withTitle: L(.ok))
        alert.beginSheetModal(for: window)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller.requestQuit() { return .terminateNow }
        log.write("quit requested while the VM runs; running the shutdown ladder")
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.write("app exiting")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @objc private func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string: L(.aboutCredits), attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: L(.windowTitle), .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L(.menuAbout), action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L(.menuHide), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: L(.menuWindow))
        windowMenu.addItem(withTitle: L(.menuClose), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        return main
    }
}
