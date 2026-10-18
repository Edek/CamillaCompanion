import AppKit
import AutoAudioCore

@MainActor private final class SetupScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class SetupDiscoveryChoices: NSObject {
    let dsp = NSPopUpButton(frame: .zero, pullsDown: false)
    let gui = NSPopUpButton(frame: .zero, pullsDown: false)
    private let useButton: NSButton

    init(useButton: NSButton) {
        self.useButton = useButton
        super.init()
        for menu in [dsp, gui] {
            menu.addItem(withTitle: "Keep current values")
            menu.target = self; menu.action = #selector(selectionChanged)
        }
        dsp.setAccessibilityIdentifier("setup.discovery.dsp")
        gui.setAccessibilityIdentifier("setup.discovery.gui")
        useButton.isEnabled = false
    }

    @objc private func selectionChanged() {
        useButton.isEnabled = dsp.indexOfSelectedItem > 0 || gui.indexOfSelectedItem > 0
    }
}

/// Explicit first-run setup. Browsing and review do not change services or audio.
@MainActor public final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let configurationURL: URL
    private let runtimeStateURL: URL
    private let devices: () throws -> [AudioDevice]
    private let discover: @Sendable () -> SetupDiscoveryResult
    private let onActivate: (Configuration) throws -> Void
    private let onClose: (() -> Void)?
    private let content = NSStackView()
    private let executable = NSTextField(string: "")
    private let yaml = NSTextField(string: "")
    private let capture = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playback = NSPopUpButton(frame: .zero, pullsDown: false)
    private let captureUID = NSTextField(string: "")
    private let playbackUID = NSTextField(string: "")
    private let port = NSTextField(string: "1234")
    private let job = NSTextField(string: "")
    private let presets = NSTextField(string: "")
    private let guiExecutable = NSTextField(string: "")
    private let guiConfiguration = NSTextField(string: "")
    private let guiURL = NSTextField(string: "http://127.0.0.1:5005")
    private let guiAbsent = NSButton(checkboxWithTitle: "CamillaGUI is not installed", target: nil, action: nil)
    private let mode = NSSegmentedControl(labels: ["Companion", "Automatic Switching"], trackingMode: .selectOne, target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let review = NSTextField(wrappingLabelWithString: "")
    private let reviewButton = NSButton(title: "Review Setup", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Only", target: nil, action: nil)
    private let activateButton = NSButton(title: "Save and Activate", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let findButton = NSButton(title: "Find Automatically…", target: nil, action: nil)
    private var discoveryWorker: Task<SetupDiscoveryResult, Never>?
    private var prepared: PreparedSetup?
    private var saved = false
    private var inputViews: [NSView] = []
    private let advanced = NSStackView()
    private let advancedButton = NSButton(title: "Advanced ▸", target: nil, action: nil)
    private var rowStack: NSStackView?
    private var availableDevices: [AudioDevice] = []
    private var task: Task<Void, Never>?
    private var completed = false

    public init(configurationURL: URL, runtimeStateURL: URL,
                devices: @escaping () throws -> [AudioDevice],
                discovery: @escaping @Sendable () -> SetupDiscoveryResult = {
                    SetupDiscovery.find(homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
                },
                onClose: (() -> Void)? = nil,
                onActivate: @escaping (Configuration) throws -> Void) {
        self.configurationURL = configurationURL; self.runtimeStateURL = runtimeStateURL
        self.devices = devices; self.onActivate = onActivate; self.onClose = onClose
        self.discover = discovery
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 740),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Set Up CamillaCompanion"
        window.minSize = NSSize(width: 640, height: 500)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func showSetup() {
        window?.center(); showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func windowWillClose(_ notification: Notification) {
        discoveryWorker?.cancel(); discoveryWorker = nil
        task?.cancel(); task = nil
        if !completed { onClose?() }
    }

    private func build() {
        guard let root = window?.contentView else { return }
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        root.addSubview(scroll)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = SetupScrollDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content); scroll.documentView = document
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)])
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do {
                let existing = try ConfigurationLoader.load(from: configurationURL)
                addText("Already configured", heading: true)
                addText(existing.profiles.map { "\($0.name)\nCapture: \($0.expectedCaptureDevice)\nPlayback: \($0.expectedPlaybackDevice)" }.joined(separator: "\n\n"))
                addText("Setup preserves the existing configuration and settings.\n" + configurationURL.path)
            } catch { addText("The existing configuration needs attention: " + error.localizedDescription) }
            let folder = NSButton(title: "Open Configuration Folder", target: self, action: #selector(openFolder))
            content.addArrangedSubview(folder)
            let close = NSButton(title: "Close", target: self, action: #selector(closeSetup)); content.addArrangedSubview(close)
            return
        }
        addText("Connect an existing CamillaDSP installation", heading: true)
        for (field, identifier) in [(executable, "setup.dspExecutable"), (yaml, "setup.dspConfiguration"),
                                    (job, "setup.dspJob"), (port, "setup.dspPort"),
                                    (guiExecutable, "setup.guiExecutable"), (guiConfiguration, "setup.guiConfiguration"),
                                    (guiURL, "setup.guiURL")] {
            field.setAccessibilityIdentifier(identifier)
        }
        addText("Choose your executable and YAML configuration. Review the setup before activating. CamillaDSP and audio drivers are not installed by this app.")
        addText("CamillaDSP not found? Choose its installed executable below, or see the installation guide.")
        let guide = NSButton(title: "CamillaDSP Installation Guide", target: self, action: #selector(openInstallationGuide))
        findButton.target = self; findButton.action = #selector(findAutomatically)
        findButton.setAccessibilityIdentifier("setup.findAutomatically")
        findButton.toolTip = "Look for existing CamillaDSP and CamillaGUI installations. Nothing is started or saved."
        let discoveryActions = NSStackView(views: [findButton, guide]); discoveryActions.spacing = 10
        content.addArrangedSubview(discoveryActions); inputViews.append(discoveryActions)
        pathRow("CamillaDSP", executable, action: #selector(chooseExecutable))
        pathRow("Configuration", yaml, action: #selector(chooseYAML))
        availableDevices = (try? devices())?.filter(\.hasOutput) ?? []
        for menu in [capture, playback] {
            menu.addItem(withTitle: "Choose a connected device…")
            for device in availableDevices { menu.addItem(withTitle: device.name); menu.lastItem?.representedObject = device.uid }
            menu.target = self; menu.action = #selector(deviceChanged(_:))
        }
        row("Capture device", capture)
        row("Playback device", playback)
        let refreshDevices = NSButton(title: "Refresh Devices", target: self, action: #selector(refreshDevices))
        content.addArrangedSubview(refreshDevices); inputViews.append(refreshDevices)
        captureUID.placeholderString = "Known device UID, if disconnected"
        playbackUID.placeholderString = "Known device UID, if disconnected"
        addText("Devices must match the YAML. This beta uses a separate virtual capture output and physical playback output. For a disconnected device, use Advanced to enter its known device UID and save without activating.")
        job.placeholderString = "Optional. Otherwise create an on-demand DSP job"
        pathRow("Presets folder", presets, action: #selector(choosePresets))
        row("Mode", mode); mode.selectedSegment = 0
        addText("Companion controls DSP without changing macOS outputs. Automatic Switching also manages output routing.")
        addText("CamillaGUI (optional)", heading: true)
        pathRow("GUI executable", guiExecutable, action: #selector(chooseGUIExecutable))
        pathRow("GUI configuration", guiConfiguration, action: #selector(chooseGUIConfiguration))
        content.addArrangedSubview(guiAbsent); inputViews.append(guiAbsent)
        guiAbsent.target = self; guiAbsent.action = #selector(guiAbsentChanged)
        advanced.orientation = .vertical; advanced.alignment = .leading; advanced.spacing = 12
        advanced.translatesAutoresizingMaskIntoConstraints = false
        advancedButton.target = self; advancedButton.action = #selector(toggleAdvanced)
        content.addArrangedSubview(advancedButton); inputViews.append(advancedButton)
        content.addArrangedSubview(advanced); advanced.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        inputViews.append(advanced); rowStack = advanced
        row("Capture UID", captureUID); row("Playback UID", playbackUID)
        row("WebSocket port", port)
        pathRow("Existing LaunchAgent", job, action: #selector(chooseJob))
        row("GUI address", guiURL)
        rowStack = nil; advanced.isHidden = true
        review.font = .systemFont(ofSize: NSFont.systemFontSize); review.isHidden = true
        content.addArrangedSubview(review)
        message.textColor = .systemRed; content.addArrangedSubview(message)
        let actions = NSStackView(views: [reviewButton, editButton, saveButton, activateButton]); actions.spacing = 10
        content.addArrangedSubview(actions)
        for (button, selector) in [(reviewButton, #selector(reviewSetup)), (editButton, #selector(editSetup)),
                                   (saveButton, #selector(saveOnly)), (activateButton, #selector(activate))] {
            button.target = self; button.action = selector
        }
        editButton.isHidden = true; saveButton.isHidden = true; activateButton.isHidden = true
    }

    private func addText(_ text: String, heading: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = heading ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 12)
        label.textColor = heading ? .labelColor : .secondaryLabelColor
        content.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    private func row(_ title: String, _ control: NSView, extra: NSView? = nil) {
        let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let views = extra.map { [label, control, $0] } ?? [label, control]
        let stack = NSStackView(views: views); stack.spacing = 10; stack.alignment = .centerY
        let parent = rowStack ?? content
        parent.addArrangedSubview(stack); stack.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inputViews.append(stack)
    }
    private func pathRow(_ title: String, _ field: NSTextField, action: Selector) {
        let choose = NSButton(title: "Choose…", target: self, action: action); row(title, field, extra: choose)
    }
    private func choose(_ field: NSTextField, directory: Bool = false) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            field.stringValue = url.path
            if field === self?.yaml { self?.matchDevices() }
        }
    }
    private func matchDevices() {
        guard let names = try? SetupConfigurationService.selectors(configurationPath: yaml.stringValue) else { return }
        for (selector, menu, uid) in [(names.capture, capture, captureUID), (names.playback, playback, playbackUID)] {
            let matches = availableDevices.filter { $0.uid == selector || $0.name == selector }
            if matches.count == 1, let device = matches.first {
                uid.stringValue = device.uid
                if let item = menu.itemArray.first(where: { $0.representedObject as? String == device.uid }) { menu.select(item) }
            }
        }
    }
    @objc private func refreshDevices() {
        do {
            availableDevices = try devices().filter(\.hasOutput)
            for (menu, field) in [(capture, captureUID), (playback, playbackUID)] {
                menu.removeAllItems(); menu.addItem(withTitle: "Choose a connected device…")
                for device in availableDevices {
                    menu.addItem(withTitle: device.name); menu.lastItem?.representedObject = device.uid
                    if device.uid == field.stringValue { menu.select(menu.lastItem) }
                }
            }
            matchDevices()
            message.stringValue = ""
        } catch { message.textColor = .systemRed; message.stringValue = error.localizedDescription }
    }
    @objc private func deviceChanged(_ sender: NSPopUpButton) {
        let field = sender === capture ? captureUID : playbackUID
        field.stringValue = sender.selectedItem?.representedObject as? String ?? ""
    }
    @objc private func guiAbsentChanged() {
        let enabled = guiAbsent.state != .on
        for field in [guiExecutable, guiConfiguration, guiURL] { field.isEnabled = enabled }
    }
    @objc private func chooseExecutable() { choose(executable) }
    @objc private func chooseYAML() { choose(yaml) }
    @objc private func chooseJob() { choose(job) }
    @objc private func choosePresets() { choose(presets, directory: true) }
    @objc private func chooseGUIExecutable() { choose(guiExecutable) }
    @objc private func chooseGUIConfiguration() { choose(guiConfiguration) }
    @objc private func toggleAdvanced() {
        advanced.isHidden.toggle(); advancedButton.title = advanced.isHidden ? "Advanced ▸" : "Advanced ▾"
    }
    @objc private func openInstallationGuide() {
        if let url = URL(string: "https://github.com/HEnquist/camilladsp#installing") { NSWorkspace.shared.open(url) }
    }
    @objc private func findAutomatically() {
        guard task == nil, !saved, prepared == nil, window?.attachedSheet == nil else { return }
        findButton.isEnabled = false; reviewButton.isEnabled = false
        message.textColor = .secondaryLabelColor; message.stringValue = "Looking for CamillaDSP and CamillaGUI…"
        let search = discover
        let worker = Task.detached(priority: .userInitiated) { search() }
        discoveryWorker = worker
        task = Task { [weak self] in
            let result = await worker.value
            guard let self, !Task.isCancelled else { return }
            discoveryWorker = nil; task = nil
            findButton.isEnabled = true; reviewButton.isEnabled = true
            message.stringValue = result.summary
            offerDiscovery(result)
        }
    }

    private func offerDiscovery(_ result: SetupDiscoveryResult) {
        guard let window, !result.dsp.isEmpty || !result.gui.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Found Installations"
        alert.informativeText = "Select installations to use in Setup."
        alert.addButton(withTitle: "Use Selection"); alert.addButton(withTitle: "Cancel")
        let choices = SetupDiscoveryChoices(useButton: alert.buttons[0])
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 540, height: 0)
        func add(_ title: String, menu: NSPopUpButton, entries: [(String, String?, String?)]) {
            guard !entries.isEmpty else { return }
            stack.addArrangedSubview(NSTextField(labelWithString: title))
            for (executablePath, configurationPath, context) in entries {
                let path = (executablePath as NSString).abbreviatingWithTildeInPath
                let detail = configurationPath.map { ($0 as NSString).lastPathComponent } ?? "Choose configuration manually"
                menu.addItem(withTitle: path + " · " + detail + (context.map { " · " + $0 } ?? ""))
                menu.lastItem?.toolTip = executablePath + (configurationPath.map { "\n" + $0 } ?? "")
            }
            menu.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(menu); menu.widthAnchor.constraint(equalToConstant: 540).isActive = true
        }
        add("CamillaDSP", menu: choices.dsp, entries: result.dsp.map {
            let port = $0.websocketPort.map { "port \($0)" }
            let context = [port, $0.launchAgentPath == nil ? nil : "existing DSP job"].compactMap { $0 }.joined(separator: ", ")
            return ($0.executablePath, $0.configurationPath, context.isEmpty ? nil : context)
        })
        add("CamillaGUI", menu: choices.gui, entries: result.gui.map { ($0.executablePath, $0.configurationPath, $0.url) })
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width: 540, height: stack.fittingSize.height))
        alert.accessoryView = stack
        alert.beginSheetModal(for: window) { [weak self, choices] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var needsGUIAddress = false
            if choices.dsp.indexOfSelectedItem > 0 {
                let candidate = result.dsp[choices.dsp.indexOfSelectedItem - 1]
                executable.stringValue = candidate.executablePath
                if let path = candidate.configurationPath { yaml.stringValue = path; matchDevices() }
                job.stringValue = candidate.launchAgentPath ?? ""
                if let value = candidate.websocketPort { port.stringValue = String(value) }
            }
            if choices.gui.indexOfSelectedItem > 0 {
                let candidate = result.gui[choices.gui.indexOfSelectedItem - 1]
                guiExecutable.stringValue = candidate.executablePath
                if let path = candidate.configurationPath { guiConfiguration.stringValue = path }
                if let url = candidate.url { guiURL.stringValue = url }
                else if candidate.configurationPath != nil {
                    guiURL.stringValue = ""; needsGUIAddress = true
                    advanced.isHidden = false; advancedButton.title = "Advanced ▾"
                }
                guiAbsent.state = .off; guiAbsentChanged()
            }
            message.textColor = .secondaryLabelColor
            message.stringValue = needsGUIAddress
                ? "Paths filled. Enter the GUI address in Advanced, then Review Setup."
                : "Paths filled. Review Setup to validate."
        }
    }
    @objc private func openFolder() { NSWorkspace.shared.open(configurationURL.deletingLastPathComponent()) }
    @objc private func closeSetup() { window?.close() }
    private func draft() throws -> SetupDraft {
        var draft = SetupDraft()
        draft.executablePath = executable.stringValue; draft.configurationPath = yaml.stringValue
        draft.captureUID = captureUID.stringValue; draft.playbackUID = playbackUID.stringValue
        guard let number = Int(port.stringValue) else { throw SwitcherError.message("Enter a valid WebSocket port.") }
        draft.websocketPort = number
        draft.existingLaunchAgentPath = job.stringValue.isEmpty ? nil : job.stringValue
        draft.presetsFolderPath = presets.stringValue.isEmpty ? nil : presets.stringValue
        draft.automaticSwitching = mode.selectedSegment == 1
        draft.confirmedGUIAbsent = guiAbsent.state == .on
        if !draft.confirmedGUIAbsent && (!guiExecutable.stringValue.isEmpty || !guiConfiguration.stringValue.isEmpty) {
            draft.gui = GUIConfiguration(executablePath: guiExecutable.stringValue, configPath: guiConfiguration.stringValue, url: guiURL.stringValue)
        }
        return draft
    }
    @objc private func reviewSetup() {
        guard task == nil else { return }
        message.textColor = .systemRed; message.stringValue = ""; reviewButton.isEnabled = false; findButton.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            defer { reviewButton.isEnabled = true; findButton.isEnabled = true; task = nil }
            do {
                let prepared = try await SetupConfigurationService.prepare(draft(), configurationURL: configurationURL, devices: devices())
                try Task.checkCancellation()
                self.prepared = prepared; review.stringValue = prepared.summary; review.isHidden = false
                for view in inputViews { view.isHidden = true }
                reviewButton.isHidden = true; editButton.isHidden = false; saveButton.isHidden = false
                activateButton.isHidden = false; activateButton.isEnabled = prepared.hardwareAvailable
            } catch { message.stringValue = error.localizedDescription }
        }
    }
    @objc private func editSetup() {
        guard !saved else { return }
        prepared = nil; review.isHidden = true; message.stringValue = ""
        for view in inputViews { view.isHidden = false }
        advanced.isHidden = true; advancedButton.title = "Advanced ▸"
        reviewButton.isHidden = false; editButton.isHidden = true; saveButton.isHidden = true; activateButton.isHidden = true
    }
    @objc private func saveOnly() {
        guard let prepared else { return }
        do {
            try SetupConfigurationService.save(prepared, configurationURL: configurationURL, runtimeStateURL: runtimeStateURL)
            saved = true; saveButton.isEnabled = false; editButton.isEnabled = false
            activateButton.title = "Activate"; message.textColor = .secondaryLabelColor
            message.stringValue = "Setup saved. DSP and macOS audio outputs are unchanged."
        } catch { message.textColor = .systemRed; message.stringValue = error.localizedDescription }
    }
    @objc private func activate() {
        guard let prepared, prepared.hardwareAvailable else { return }
        activateButton.isEnabled = false; saveButton.isEnabled = false; editButton.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            defer { activateButton.isEnabled = true; saveButton.isEnabled = !saved; editButton.isEnabled = !saved; task = nil }
            do {
                let current = try devices()
                let profile = prepared.configuration.profiles[0]
                guard [profile.captureUID, profile.playbackUID].allSatisfy({ uid in current.contains(where: { $0.uid == uid && $0.hasOutput }) }) else {
                    throw SwitcherError.message("A selected device is disconnected. Save setup and activate once it is connected.")
                }
                try await SetupConfigurationService.checkForConflictingDSP(prepared)
                try Task.checkCancellation()
                if !saved { try SetupConfigurationService.save(prepared, configurationURL: configurationURL, runtimeStateURL: runtimeStateURL); saved = true }
                try SetupConfigurationService.validateForActivation(prepared)
                try onActivate(prepared.configuration)
                completed = true; window?.close()
            } catch { message.textColor = .systemRed; message.stringValue = error.localizedDescription }
        }
    }
}
