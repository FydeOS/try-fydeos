import AppKit
import TryFydeOSAppModel
import TryFydeOSCore

private final class CardView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

final class StartMenuWindow: NSWindow, NSWindowDelegate, NSTextFieldDelegate {
    var onPreferencesChange: ((Preferences) -> Void)?
    var onLaunch: ((Preferences) -> Void)?

    private static let width: CGFloat = 520
    private static let margin: CGFloat = 20
    private static let contentWidth = width - 2 * margin

    private let controller: AppController
    private let host: HostInfo
    private var preferences: Preferences
    private let stack = NSStackView()
    private let cpuPopup = NSPopUpButton()
    private let memoryPopup = NSPopUpButton()
    private let fullScreenSwitch = NSSwitch()
    private let microphoneSwitch = NSSwitch()
    private let resetButton = NSButton(title: L(.resetButton), target: nil, action: nil)
    private let launchButton = NSButton(title: L(.launch), target: nil, action: nil)
    private let launchSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let imageProgress = NSProgressIndicator()
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = L(.windowTitle)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        delegate = self
        build()
        center()
    }

    private func build() {
        for n in Preferences.cpuChoices(host) { cpuPopup.addItem(withTitle: L(.cpuValue, n)); cpuPopup.lastItem?.tag = n }
        for m in Preferences.memoryChoices(host) { memoryPopup.addItem(withTitle: L(.memoryValue, m / 1024)); memoryPopup.lastItem?.tag = m }
        cpuPopup.selectItem(withTag: preferences.cpus)
        memoryPopup.selectItem(withTag: preferences.memoryMiB)
        fullScreenSwitch.state = preferences.fullScreen ? .on : .off
        microphoneSwitch.state = preferences.microphone ? .on : .off
        for control in [cpuPopup, memoryPopup, fullScreenSwitch, microphoneSwitch] as [NSControl] {
            control.target = self
            control.action = #selector(preferencesChanged(_:))
        }
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(factoryReset(_:))

        launchButton.bezelStyle = .rounded
        launchButton.controlSize = .large
        launchButton.keyEquivalent = "\r"
        launchButton.target = self
        launchButton.action = #selector(launch(_:))
        launchButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        launchSpinner.style = .spinning
        launchSpinner.controlSize = .small
        launchSpinner.isDisplayedWhenStopped = false
        launchSpinner.translatesAutoresizingMaskIntoConstraints = false
        launchButton.addSubview(launchSpinner)
        NSLayoutConstraint.activate([
            launchSpinner.centerYAnchor.constraint(equalTo: launchButton.centerYAnchor),
            launchSpinner.leadingAnchor.constraint(equalTo: launchButton.leadingAnchor, constant: 16),
        ])

        imageProgress.style = .bar
        imageProgress.minValue = 0
        imageProgress.maxValue = 1

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = Self.contentWidth

        let header = header()
        let captions = [caption(L(.sectionResources)), caption(L(.sectionDisplay)), caption(L(.sectionReset))]
        let cards = [
            card([row(L(.cpus), control: cpuPopup), row(L(.memory), control: memoryPopup)]),
            card([row(L(.fullScreen), detail: L(.fullScreenDetail), control: fullScreenSwitch),
                  row(L(.microphone), detail: L(.microphoneDetail), control: microphoneSwitch)]),
            card([row(L(.factoryReset), detail: L(.factoryResetDetail), control: resetButton)]),
        ]
        stack.setViews([header, captions[0], cards[0], captions[1], cards[1], captions[2], cards[2],
                        statusLabel, launchButton, imageProgress], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        for view in [header, launchButton, imageProgress] + cards {
            view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }
        for caption in captions { stack.setCustomSpacing(6, after: caption) }
        stack.setCustomSpacing(8, after: launchButton)
        // The top inset clears the traffic lights drawn over the full-size content view.
        stack.edgeInsets = NSEdgeInsets(top: 32, left: Self.margin, bottom: Self.margin, right: Self.margin)
        contentView = stack
        refresh()
    }

    private func header() -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: L(.windowTitle))
        title.font = .boldSystemFont(ofSize: 24)
        let subtitle = NSTextField(labelWithAttributedString: NSAttributedString(string: L(.subtitle), attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .kern: 1.2,
        ]))
        let versionString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let version = NSTextField(labelWithString: L(.version, versionString))
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor

        let titles = NSStackView(views: [title, subtitle, version])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3
        let header = NSStackView(views: [icon, titles])
        header.alignment = .centerY
        header.spacing = 14
        return header
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func row(_ title: String, detail: String? = nil, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        var labels: [NSView] = [titleLabel]
        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.preferredMaxLayoutWidth = 300
            labels.append(detailLabel)
        }
        let text = NSStackView(views: labels)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [text, spacer, control])
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        return row
    }

    private func card(_ rows: [NSView]) -> NSView {
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                body.addArrangedSubview(line)
                line.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16).isActive = true
                line.trailingAnchor.constraint(equalTo: body.trailingAnchor).isActive = true
            }
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let card = CardView()
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    func refresh() {
        let state = controller.state
        let idle = !state.isActive
        statusLabel.stringValue = controller.statusText { [timeFormatter] in timeFormatter.string(from: $0) }
        for control in [cpuPopup, memoryPopup, fullScreenSwitch, microphoneSwitch] as [NSControl] {
            control.isEnabled = idle
        }
        resetButton.isEnabled = controller.canFactoryReset
        standardWindowButton(.closeButton)?.isEnabled = idle
        launchButton.isEnabled = controller.canLaunch

        switch state {
        case .notRunning, .failed: launchButton.title = L(.launch)
        case .preparing: launchButton.title = L(.launchPreparing)
        case .starting: launchButton.title = L(.launchStarting)
        case .running: launchButton.title = L(.launchRunning)
        case .shuttingDown: launchButton.title = L(.launchShuttingDown)
        }
        if state == .starting { launchSpinner.startAnimation(nil) } else { launchSpinner.stopAnimation(nil) }

        if case .preparing(let bytes, let total) = state {
            imageProgress.isHidden = false
            imageProgress.isIndeterminate = total == 0
            if total > 0 {
                imageProgress.stopAnimation(nil)
                imageProgress.doubleValue = Double(bytes) / Double(total)
            } else {
                imageProgress.startAnimation(nil)
            }
        } else {
            imageProgress.stopAnimation(nil)
            imageProgress.isHidden = true
        }
        fitToContent()
    }

    private func fitToContent() {
        stack.layoutSubtreeIfNeeded()
        var height = stack.fittingSize.height
        if let visible = (screen ?? NSScreen.main)?.visibleFrame { height = min(height, visible.height) }
        let size = frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height)).size
        guard size != frame.size else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !controller.state.isActive { NSApp.terminate(nil) }
        return false
    }

    @objc private func preferencesChanged(_ sender: Any?) {
        preferences.cpus = cpuPopup.selectedTag()
        preferences.memoryMiB = memoryPopup.selectedTag()
        preferences.fullScreen = fullScreenSwitch.state == .on
        preferences.microphone = microphoneSwitch.state == .on
        onPreferencesChange?(preferences)
    }

    @objc private func launch(_ sender: Any?) {
        preferencesChanged(nil)
        onLaunch?(preferences)
    }

    @objc private func factoryReset(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L(.resetTitle)
        alert.informativeText = L(.resetMessage)
        alert.addButton(withTitle: L(.cancel))
        let confirm = alert.addButton(withTitle: L(.resetConfirm))
        confirm.hasDestructiveAction = true
        confirm.isEnabled = false

        let prompt = NSTextField(labelWithString: L(.resetPrompt, Strings.resetPhrase))
        prompt.font = .systemFont(ofSize: 12, weight: .medium)
        prompt.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField(string: "")
        field.placeholderString = Strings.resetPhrase
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        accessory.addSubview(prompt)
        accessory.addSubview(field)
        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            prompt.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor),
            prompt.topAnchor.constraint(equalTo: accessory.topAnchor),
            field.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            field.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 7),
            field.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
        ])
        alert.accessoryView = accessory
        resetField = field
        resetConfirmButton = confirm
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self else { return }
            let typed = self.resetField?.stringValue
            self.resetField = nil
            self.resetConfirmButton = nil
            guard response == .alertSecondButtonReturn, typed == Strings.resetPhrase else { return }
            do {
                try self.controller.factoryReset()
            } catch {
                let failure = NSAlert()
                failure.messageText = L(.resetFailedTitle)
                failure.informativeText = "\(error)"
                failure.addButton(withTitle: L(.ok))
                failure.beginSheetModal(for: self)
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        resetConfirmButton?.isEnabled = resetField?.stringValue == Strings.resetPhrase
    }
}
