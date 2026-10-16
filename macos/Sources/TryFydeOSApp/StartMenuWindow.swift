import AppKit
import TryFydeOSAppModel
import UniformTypeIdentifiers
import TryFydeOSCore

final class StartMenuWindow: NSWindow, NSWindowDelegate, NSTextFieldDelegate {
    var onPreferencesChange: ((Preferences) -> Void)?
    var onLaunch: ((Preferences) -> Void)?

    private let controller: AppController
    private let host: HostInfo
    private var preferences: Preferences
    private let cpuPopup = NSPopUpButton()
    private let memoryPopup = NSPopUpButton()
    private let fullScreenBox = NSButton(checkboxWithTitle: L(.fullScreen), target: nil, action: nil)
    private let microphoneBox = NSButton(checkboxWithTitle: L(.microphone), target: nil, action: nil)
    private let launchButton = NSButton(title: L(.launch), target: nil, action: nil)
    private let shutDownButton = NSButton(title: L(.shutDown), target: nil, action: nil)
    private let logsButton = NSButton(title: L(.logs), target: nil, action: nil)
    private let resetButton = NSButton(title: L(.factoryReset), target: nil, action: nil)
    private let quitButton = NSButton(title: L(.quit), target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let imageLabel = NSTextField(labelWithString: "")
    private let installButton = NSButton(title: L(.imageInstall), target: nil, action: nil)
    private let imageProgress = NSProgressIndicator()
    private var grid: NSGridView!
    private let noteRow = NSStackView()
    private var resetField: NSTextField?
    private var resetConfirmButton: NSButton?
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    init(controller: AppController, preferences: Preferences, host: HostInfo) {
        self.controller = controller
        self.preferences = preferences
        self.host = host
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260), styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = L(.windowTitle)
        isReleasedWhenClosed = false
        delegate = self
        build()
        center()
    }

    private func build() {
        for n in Preferences.cpuChoices(host) { cpuPopup.addItem(withTitle: "\(n)"); cpuPopup.lastItem?.tag = n }
        for m in Preferences.memoryChoices(host) { memoryPopup.addItem(withTitle: L(.memoryValue, m / 1024)); memoryPopup.lastItem?.tag = m }
        cpuPopup.selectItem(withTag: preferences.cpus)
        memoryPopup.selectItem(withTag: preferences.memoryMiB)
        fullScreenBox.state = preferences.fullScreen ? .on : .off
        microphoneBox.state = preferences.microphone ? .on : .off
        for control in [cpuPopup, memoryPopup, fullScreenBox, microphoneBox] as [NSControl] {
            control.target = self
            control.action = #selector(preferencesChanged(_:))
        }
        let actions: [(NSButton, Selector)] = [(launchButton, #selector(launch(_:))), (shutDownButton, #selector(shutDown(_:))),
                                               (logsButton, #selector(openLogs(_:))), (resetButton, #selector(factoryReset(_:))),
                                               (quitButton, #selector(quit(_:))), (installButton, #selector(installImage(_:)))]
        for (button, action) in actions {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        launchButton.keyEquivalent = "\r"

        imageProgress.isIndeterminate = false
        imageProgress.minValue = 0
        imageProgress.maxValue = 1
        imageProgress.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let imageRow = NSStackView(views: [imageLabel, installButton])
        imageRow.alignment = .centerY
        grid = NSGridView(views: [
            [NSTextField(labelWithString: L(.imageRow)), imageRow],
            [NSGridCell.emptyContentView, imageProgress],
            [NSTextField(labelWithString: L(.cpus)), cpuPopup],
            [NSTextField(labelWithString: L(.memory)), memoryPopup],
            [NSGridCell.emptyContentView, fullScreenBox],
            [NSGridCell.emptyContentView, microphoneBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8

        let note = NSTextField(wrappingLabelWithString: L(.firstRunNote))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 300
        let dismiss = NSButton(title: L(.dismiss), target: self, action: #selector(dismissNote(_:)))
        dismiss.controlSize = .small
        dismiss.bezelStyle = .rounded
        noteRow.orientation = .horizontal
        noteRow.alignment = .centerY
        noteRow.addArrangedSubview(note)
        noteRow.addArrangedSubview(dismiss)
        noteRow.isHidden = preferences.firstRunNoteDismissed

        statusLabel.preferredMaxLayoutWidth = 380
        statusLabel.textColor = .secondaryLabelColor

        let primary = NSStackView(views: [launchButton, shutDownButton])
        let secondary = NSStackView(views: [logsButton, resetButton, quitButton])
        let stack = NSStackView(views: [grid, primary, statusLabel, noteRow, secondary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
        refresh()
    }

    func refresh() {
        statusLabel.stringValue = controller.statusText { [timeFormatter] in timeFormatter.string(from: $0) }
        if let image = controller.image {
            imageLabel.stringValue = image.rowText
            installButton.isHidden = image.isInstalled
            installButton.isEnabled = !image.isImporting
            grid.row(at: 1).isHidden = !image.isImporting
            if case .importing(let progress) = image.state { imageProgress.doubleValue = progress.fraction }
        }
        launchButton.isEnabled = controller.canLaunch
        shutDownButton.isEnabled = controller.canShutDown
        resetButton.isEnabled = controller.canFactoryReset
        for control in [cpuPopup, memoryPopup, fullScreenBox, microphoneBox] as [NSControl] {
            control.isEnabled = !controller.state.isActive
        }
    }

    @objc private func preferencesChanged(_ sender: Any?) {
        preferences.cpus = cpuPopup.selectedTag()
        preferences.memoryMiB = memoryPopup.selectedTag()
        preferences.fullScreen = fullScreenBox.state == .on
        preferences.microphone = microphoneBox.state == .on
        onPreferencesChange?(preferences)
    }

    @objc private func dismissNote(_ sender: Any?) {
        preferences.firstRunNoteDismissed = true
        noteRow.isHidden = true
        onPreferencesChange?(preferences)
    }

    @objc private func launch(_ sender: Any?) {
        preferencesChanged(nil)
        onLaunch?(preferences)
    }

    @objc private func shutDown(_ sender: Any?) {
        controller.shutDown()
    }

    @objc private func openLogs(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: AppLog.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppLog.directory)
    }

    @objc private func installImage(_ sender: Any?) {
        guard let image = controller.image else { return }
        guard image.needsFileChoice else { return image.install() }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.message = L(.imageChooseMessage, image.expectedFile)
        panel.beginSheetModal(for: self) { response in
            guard response == .OK, let url = panel.url else { return }
            image.install(from: url)
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func factoryReset(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L(.resetTitle)
        alert.informativeText = L(.resetMessage, Strings.resetPhrase)
        let confirm = alert.addButton(withTitle: L(.resetConfirm))
        confirm.hasDestructiveAction = true
        confirm.isEnabled = false
        alert.addButton(withTitle: L(.cancel))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = Strings.resetPhrase
        field.delegate = self
        alert.accessoryView = field
        resetField = field
        resetConfirmButton = confirm
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self else { return }
            let typed = self.resetField?.stringValue
            self.resetField = nil
            self.resetConfirmButton = nil
            guard response == .alertFirstButtonReturn, typed == Strings.resetPhrase else { return }
            do {
                try self.controller.factoryReset()
            } catch {
                let failure = NSAlert()
                failure.messageText = L(.errorAlertTitle)
                failure.informativeText = "\(error)"
                failure.beginSheetModal(for: self)
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        resetConfirmButton?.isEnabled = resetField?.stringValue == Strings.resetPhrase
    }
}
