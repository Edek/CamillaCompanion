import AppKit
import UniformTypeIdentifiers
import AutoAudioCore

package typealias ProfileAutoActivationConfirmationPresenter =
    @MainActor ([String], @escaping (Bool) -> Void) -> Void

/// Owns one unsaved form. Persistence and runtime activation remain outside this sheet.
@MainActor package final class InterfaceProfileEditor: NSWindowController, NSWindowDelegate {
    private(set) var draft: InterfaceProfileDraft
    private var devices: [AudioDevice]
    private let savedProfiles: [InterfaceProfileDraft]
    private let refreshDevices: () throws -> [AudioDevice]
    private let presetsFolder: () -> String?
    private let openDirectory: (URL) -> Bool
    private let onSave: (InterfaceProfileDraft) async throws -> Void
    private let confirmAutoActivationReplacement: ProfileAutoActivationConfirmationPresenter
    private let name = NSTextField(string: "")
    private let executable = NSTextField(labelWithString: "")
    private let configuration = NSTextField(labelWithString: "")
    private let trigger = NSButton()
    private let input = NSButton()
    private let output = NSButton()
    private let port = NSTextField(string: "")
    private let automatic = NSButton(checkboxWithTitle: "Auto-activate when available", target: nil, action: nil)
    private let manageFeed = NSButton(checkboxWithTitle: "Support automatic routing", target: nil, action: nil)
    private let alerts = NSButton(checkboxWithTitle: "Route system alerts", target: nil, action: nil)
    private let advancedToggle = NSButton(title: "Advanced", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let mappingNote = NSTextField(wrappingLabelWithString: "")
    private var mappingSuggestions: ProfileDeviceMappingSuggestions?
    private let overlapNote = NSTextField(wrappingLabelWithString: "")
    private let modeNote = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save Profile", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let findButton = NSButton(title: "Find…", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate Preset…", target: nil, action: nil)
    private let openPresetsButton = NSButton(title: "Open Presets Folder", target: nil, action: nil)
    private let revealPresetButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let presetHelp = NSTextField(wrappingLabelWithString:
        "Loaded when this interface starts. Choose a CamillaDSP YAML preset.")
    private let bodyScroll = NSScrollView()
    private var form: NSStackView!
    private var footer: NSStackView!
    private var controls: [NSControl] = []
    private var advanced: NSStackView!
    private var deviceBrowser: InterfaceDeviceBrowser?
    private var saving = false
    private var finding = false
    private var confirmationPending = false
    private var confirmationGeneration = 0
    private var editorTask: Task<Void, Never>?

    package init(draft: InterfaceProfileDraft, devices: [AudioDevice], savedProfiles: [InterfaceProfileDraft],
                 presetsFolder: @escaping () -> String? = { nil },
                 openDirectory: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
                 refresh: @escaping () throws -> [AudioDevice],
                 onSave: @escaping (InterfaceProfileDraft) async throws -> Void,
                 confirmationPresenter: ProfileAutoActivationConfirmationPresenter? = nil) {
        self.draft = draft; self.devices = devices; self.savedProfiles = savedProfiles
        refreshDevices = refresh; self.onSave = onSave
        self.presetsFolder = presetsFolder; self.openDirectory = openDirectory
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = savedProfiles.contains(where: { $0.id == draft.id }) ? "Edit Profile" : "Add Profile"
        window.isReleasedWhenClosed = false
        confirmAutoActivationReplacement = confirmationPresenter ?? { names, completion in
            let alert = NSAlert()
            alert.messageText = "Change Automatic Profile?"
            alert.informativeText = "Only one profile can auto-activate for this connection trigger. Saving will enable it here and turn it off for \(names.joined(separator: ", ")). Other profile settings are kept."
            alert.addButton(withTitle: "Make Automatic")
            alert.addButton(withTitle: "Cancel")
            // A device/file picker may be ending its own sheet in this callback.
            DispatchQueue.main.async {
                alert.beginSheetModal(for: window) { response in
                    completion(response == .alertFirstButtonReturn)
                }
            }
        }
        super.init(window: window)
        window.delegate = self
        buildUI()
        if !draft.configurationPath.isEmpty {
            mappingSuggestions = try? ProfileDeviceMapping.suggestions(configurationPath: draft.configurationPath, devices: devices)
        }
        showDraft()
        resizeToFitContent()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    package func present(asSheetOf parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(name)
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }
        window?.backgroundColor = .windowBackgroundColor
        name.identifier = .init("Interface profile name")
        name.placeholderString = "Profile name"
        port.identifier = .init("Interface WebSocket port")
        port.widthAnchor.constraint(equalToConstant: 100).isActive = true
        for field in [executable, configuration] {
            field.lineBreakMode = .byTruncatingMiddle
            field.isSelectable = true
            field.font = .systemFont(ofSize: 12)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        configuration.setAccessibilityLabel("Startup preset file")
        let chooseDSP = button("Choose…", #selector(chooseExecutable))
        let revealDSP = button("Show in Finder", #selector(revealExecutable))
        let choosePreset = button("Choose Preset…", #selector(chooseConfiguration))
        duplicateButton.target = self; duplicateButton.action = #selector(duplicateConfiguration)
        duplicateButton.toolTip = "Copy the selected preset without changing its DSP settings. The copy remains after Cancel."
        revealPresetButton.target = self; revealPresetButton.action = #selector(revealConfiguration)
        openPresetsButton.target = self; openPresetsButton.action = #selector(openPresetsFolder)
        automatic.target = self; automatic.action = #selector(changeAutomatic)
        findButton.target = self; findButton.action = #selector(findDSP)
        trigger.target = self; trigger.action = #selector(chooseTrigger)
        input.target = self; input.action = #selector(chooseInput)
        output.target = self; output.action = #selector(chooseOutput)
        for (control, label) in [(trigger, "Connection trigger"), (input, "DSP input"), (output, "DSP output")] {
            control.bezelStyle = .rounded; control.alignment = .left
            control.cell?.lineBreakMode = .byTruncatingMiddle
            control.setAccessibilityLabel(label)
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        manageFeed.target = self; manageFeed.action = #selector(changeFeed)
        advancedToggle.target = self; advancedToggle.action = #selector(toggleAdvanced)
        advancedToggle.title = ""; advancedToggle.setAccessibilityLabel("Advanced")
        advancedToggle.bezelStyle = .disclosure; advancedToggle.setButtonType(.onOff)
        let advancedTitle = NSTextField(labelWithString: "Advanced")
        advancedTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let advancedHeader = NSStackView(views: [advancedToggle, advancedTitle])
        advancedHeader.spacing = 4
        let executableActions = NSStackView(views: [chooseDSP, revealDSP, findButton]); executableActions.spacing = 8
        advanced = vertical([row("DSP executable", executable), executableActions, row("WebSocket port", port), alerts], spacing: 8)
        advanced.isHidden = true
        for note in [modeNote, mappingNote, presetHelp] {
            note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        }
        mappingNote.maximumNumberOfLines = 3; mappingNote.isHidden = true
        overlapNote.font = .systemFont(ofSize: 12); overlapNote.maximumNumberOfLines = 4
        overlapNote.isHidden = true
        message.font = .systemFont(ofSize: 12); message.maximumNumberOfLines = 4
        message.textColor = .systemRed; message.isHidden = true
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        footer = NSStackView(views: [NSView(), cancelButton, saveButton]); footer.spacing = 8
        let presetActions = NSStackView(views: [choosePreset, openPresetsButton]); presetActions.spacing = 8
        let fileActions = NSStackView(views: [duplicateButton, revealPresetButton]); fileActions.spacing = 8
        form = vertical([
            section("Profile", [row("Name", name)]),
            section("Audio Devices", [row("Connection trigger", trigger), row("DSP input", input), row("DSP output", output), mappingNote]),
            section("Startup Preset", [configuration, presetActions, fileActions, presetHelp]),
            section("Behavior", [automatic, overlapNote, manageFeed, modeNote]),
            advancedHeader, advanced, message
        ], spacing: 18)
        let document = InterfaceEditorDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.drawsBackground = false; bodyScroll.autohidesScrollers = true
        bodyScroll.hasVerticalScroller = true; bodyScroll.scrollerStyle = .overlay
        bodyScroll.documentView = document
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form)
        root.addSubview(bodyScroll); root.addSubview(footer)
        NSLayoutConstraint.activate([
            bodyScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyScroll.topAnchor.constraint(equalTo: root.topAnchor),
            bodyScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            form.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        controls = [name, port, trigger, input, output, automatic, manageFeed, alerts,
                    advancedToggle, chooseDSP, choosePreset, openPresetsButton, duplicateButton, revealDSP, revealPresetButton,
                    findButton, saveButton, cancelButton]
        for control in controls.compactMap({ $0 as? NSButton }) where control !== advancedToggle {
            control.bezelStyle = .rounded
        }
        window?.defaultButtonCell = saveButton.cell as? NSButtonCell
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views {
            view.setContentHuggingPriority(.required, for: .vertical)
            if view is NSStackView || view is NSTextField {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }
    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.identifier = .init("Profile editor " + title)
        return vertical([heading] + views, spacing: 8)
    }
    private func resizeToFitContent() {
        guard let window, let root = window.contentView, form != nil else { return }
        root.layoutSubtreeIfNeeded()
        let titleHeight = window.frame.height - root.frame.height
        let maximum = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 768
        let height = min(form.fittingSize.height + footer.fittingSize.height + 56, maximum - titleHeight - 24)
        window.setContentSize(NSSize(width: 620, height: max(360, height)))
        root.layoutSubtreeIfNeeded()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let row = NSStackView(views: [label, control])
        row.alignment = .centerY; row.spacing = 8
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if control is NSButton || control === name { control.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true }
        return row
    }

    private func showDraft() {
        name.stringValue = draft.name; port.stringValue = String(draft.websocketPort)
        executable.stringValue = draft.executablePath.isEmpty ? "Not selected" : draft.executablePath
        executable.toolTip = draft.executablePath
        configuration.stringValue = draft.configurationPath.isEmpty ? "No preset selected" : URL(fileURLWithPath: draft.configurationPath).lastPathComponent
        configuration.toolTip = draft.configurationPath
        updatePresetFolderButton()
        duplicateButton.isEnabled = !saving && !finding && !draft.configurationPath.isEmpty
        revealPresetButton.isEnabled = !saving && !finding && !draft.configurationPath.isEmpty
        automatic.state = draft.autoActivate ? .on : .off
        alerts.state = draft.routeAlerts ? .on : .off
        updateDevices()
    }
    private func deviceTitle(_ uid: String) -> String {
        if uid.isEmpty { return "Choose…" }
        return devices.first(where: { $0.uid == uid })?.name ?? "Offline: \(uid)"
    }
    private func updateDevices() {
        trigger.title = deviceTitle(draft.triggerUID); trigger.toolTip = draft.triggerUID
        input.title = deviceTitle(draft.captureUID); input.toolTip = draft.captureUID
        output.title = deviceTitle(draft.playbackUID); output.toolTip = draft.playbackUID
        let capture = devices.first { $0.uid == draft.captureUID }
        let canManage = capture.map { DeviceRole.managedFeed.accepts($0) } == true
            && draft.captureUID != draft.playbackUID && draft.captureUID != draft.triggerUID
        manageFeed.state = draft.managedFeedUID == nil ? .off : .on
        manageFeed.isEnabled = !saving && !finding && !confirmationPending && (canManage || draft.managedFeedUID != nil)
        modeNote.stringValue = draft.managedFeedUID == nil ? "Companion Mode only. macOS output stays under your control." :
            "System audio feeds the DSP input when Automatic Switching is enabled."
        alerts.isEnabled = !saving && !finding && !confirmationPending && draft.managedFeedUID != nil
        updateOverlapNote()
        if let mappingSuggestions {
            let issues = ProfileDeviceMapping.review(draft, suggestions: mappingSuggestions, devices: devices)
            mappingNote.stringValue = issues.joined(separator: "\n"); mappingNote.isHidden = issues.isEmpty
        }
    }

    private func updateOverlapNote() {
        let notice = InterfaceProfileOverlap.review(draft, against: savedProfiles)
        let approved = notice?.automaticAmbiguity == true
            && notice?.conflictingProfileIDs == draft.confirmedAutoActivationReplacementIDs
        overlapNote.stringValue = approved ? "Saving will make this the automatic profile for this connection trigger." : notice?.message ?? ""
        overlapNote.toolTip = overlapNote.stringValue
        overlapNote.textColor = notice?.automaticAmbiguity == true && !approved ? .systemOrange : .secondaryLabelColor
        overlapNote.isHidden = notice == nil
    }
    @objc private func changeAutomatic() {
        if automatic.state == .on {
            var proposed = draft
            proposed.autoActivate = true
            let ids = InterfaceProfileOverlap.automaticReplacementIDs(proposed, against: savedProfiles)
            if ids.isEmpty || draft.confirmedAutoActivationReplacementIDs == ids {
                draft.autoActivate = true
                draft.confirmedAutoActivationReplacementIDs = ids
                updateDevices(); resizeToFitContent()
                return
            }
            let priorValue = draft.autoActivate
            requestReplacementConfirmation(ids: ids, candidate: proposed, onAccept: { [weak self] in
                guard let self else { return }
                self.draft.autoActivate = true
                self.draft.confirmedAutoActivationReplacementIDs = ids
            }, onCancel: { [weak self] in
                guard let self else { return }
                self.draft.autoActivate = priorValue
                self.automatic.state = priorValue ? .on : .off
                self.updateDevices()
            })
        } else {
            invalidatePendingConfirmation()
            draft.autoActivate = false
            draft.confirmedAutoActivationReplacementIDs = []
            updateBusy(); updateDevices(); resizeToFitContent()
        }
    }

    private func setTriggerUID(_ uid: String) {
        let previousUID = draft.triggerUID
        let previousConfirmedIDs = draft.confirmedAutoActivationReplacementIDs
        guard uid != previousUID else { return }
        invalidatePendingConfirmation()
        draft.triggerUID = uid
        draft.confirmedAutoActivationReplacementIDs = []
        let ids = InterfaceProfileOverlap.automaticReplacementIDs(draft, against: savedProfiles)
        guard !ids.isEmpty else { updateDevices(); resizeToFitContent(); return }
        requestReplacementConfirmation(ids: ids, candidate: draft, onAccept: { [weak self] in
            guard let self else { return }
            self.draft.confirmedAutoActivationReplacementIDs = ids
        }, onCancel: { [weak self] in
            guard let self else { return }
            self.draft.triggerUID = previousUID
            let priorConflicts = InterfaceProfileOverlap.automaticReplacementIDs(self.draft, against: self.savedProfiles)
            self.draft.confirmedAutoActivationReplacementIDs = previousConfirmedIDs == priorConflicts ? previousConfirmedIDs : []
            self.updateDevices()
        })
    }

    private func requestReplacementConfirmation(ids: Set<String>, candidate: InterfaceProfileDraft,
                                                onAccept: @escaping () -> Void,
                                                onCancel: @escaping () -> Void) {
        guard !confirmationPending else { return }
        let currentIDs = InterfaceProfileOverlap.automaticReplacementIDs(candidate, against: savedProfiles)
        guard currentIDs == ids, !ids.isEmpty else { return }
        confirmationGeneration += 1
        let generation = confirmationGeneration
        confirmationPending = true
        updateBusy()
        let names = InterfaceProfileOverlap.automaticReplacementNames(candidate, against: savedProfiles)
        confirmAutoActivationReplacement(names) { [weak self] accepted in
            guard let self, self.confirmationGeneration == generation else { return }
            self.confirmationPending = false
            var latestCandidate = self.draft
            latestCandidate.autoActivate = candidate.autoActivate
            let stillCurrent = self.draft.triggerUID == candidate.triggerUID
                && InterfaceProfileOverlap.automaticReplacementIDs(latestCandidate, against: self.savedProfiles) == ids
            if stillCurrent {
                if accepted { onAccept() } else { onCancel() }
            }
            self.updateBusy(); self.updateDevices(); self.resizeToFitContent()
        }
    }

    private func invalidatePendingConfirmation() {
        confirmationGeneration += 1
        confirmationPending = false
    }

    /// Resolve on demand, so changes in General are used by the next picker or folder action.
    private var presetDirectory: URL? {
        let paths = [presetsFolder(), draft.configurationPath.isEmpty ? nil :
            URL(fileURLWithPath: draft.configurationPath).deletingLastPathComponent().path]
        for case let path? in paths where path.hasPrefix("/") && !path.contains("\0") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
        }
        return nil
    }
    private func updatePresetFolderButton() {
        openPresetsButton.isEnabled = !saving && !finding && !confirmationPending && presetDirectory != nil
        openPresetsButton.toolTip = presetDirectory?.path ?? "Choose a presets folder in Settings > General."
    }
    @objc private func openPresetsFolder() {
        guard !saving, !finding else { return }
        guard let directory = presetDirectory else {
            show("Choose an available presets folder in Settings > General."); return
        }
        if !openDirectory(directory) { show("Could not open the presets folder.") }
    }

    private func chooseDevice(_ role: DeviceRole, selectedUID: String, onSelect: @escaping (String) -> Void) {
        guard !saving, !finding, let window else { return }
        let savedUIDs = savedProfiles.flatMap { [$0.triggerUID, $0.captureUID, $0.playbackUID] }
        let browser = InterfaceDeviceBrowser(devices: devices, selectedUID: selectedUID, role: role, savedUIDs: savedUIDs,
            refresh: { [weak self] in
                guard let self else { return [] }
                let latest = try self.refreshDevices(); self.devices = latest
                if !self.draft.configurationPath.isEmpty {
                    self.mappingSuggestions = try ProfileDeviceMapping.suggestions(configurationPath: self.draft.configurationPath, devices: latest)
                }
                self.updateDevices()
                return latest
            }, onSelect: { [weak self] uid in
                guard let self else { return }
                onSelect(uid); self.updateDevices(); self.clearMessage()
            })
        deviceBrowser = browser
        browser.present(asSheetOf: window)
    }
    @objc private func chooseTrigger() {
        chooseDevice(.trigger, selectedUID: draft.triggerUID) { [weak self] in self?.setTriggerUID($0) }
    }
    @objc private func chooseInput() {
        chooseDevice(.dspInput, selectedUID: draft.captureUID) { [weak self] uid in
            guard let self else { return }
            self.draft.captureUID = uid
            // Preserve explicit routing intent only while the new input can accept system audio.
            if self.draft.managedFeedUID != nil {
                self.draft.managedFeedUID = self.devices.first(where: { $0.uid == uid && DeviceRole.managedFeed.accepts($0) })?.uid
            }
        }
    }
    @objc private func chooseOutput() {
        chooseDevice(.dspOutput, selectedUID: draft.playbackUID) { [weak self] uid in
            guard let self else { return }
            if self.draft.triggerUID.isEmpty { self.setTriggerUID(uid) }
            self.draft.playbackUID = uid
        }
    }
    @objc private func changeFeed() {
        draft.managedFeedUID = manageFeed.state == .on ? draft.captureUID : nil
        if draft.managedFeedUID == nil { draft.routeAlerts = false; alerts.state = .off }
        updateDevices()
    }
    @objc private func toggleAdvanced() {
        advanced.isHidden = advancedToggle.state != .on
        resizeToFitContent()
    }

    @objc private func chooseExecutable() { chooseFile(isExecutable: true) }
    @objc private func chooseConfiguration() { chooseFile(isExecutable: false) }
    private func chooseFile(isExecutable: Bool) {
        guard !saving, !finding, let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = isExecutable ? "Choose DSP Executable" : "Choose Startup Preset"
        if !isExecutable {
            panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .text]
            panel.directoryURL = presetDirectory
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path, let self else { return }
            self.captureText()
            if isExecutable { self.draft.executablePath = path }
            else {
                self.draft.configurationPath = path
                self.mappingSuggestions = nil
                do { try self.suggestMappings() } catch { self.show(error.localizedDescription) }
            }
            self.showDraft()
        }
    }
    private func suggestMappings() throws {
        let suggestion = try ProfileDeviceMapping.suggestions(configurationPath: draft.configurationPath, devices: devices)
        mappingSuggestions = suggestion
        // A new YAML is an explicit mapping change. Do not retain mappings from the old file.
        let hadManagedFeed = draft.managedFeedUID != nil
        draft.captureUID = suggestion.capture.candidateUID ?? ""
        draft.playbackUID = suggestion.playback.candidateUID ?? ""
        let previousTriggerUID = draft.triggerUID
        let suggestedTriggerUID = previousTriggerUID.isEmpty ? draft.playbackUID : previousTriggerUID
        draft.triggerUID = suggestedTriggerUID
        draft.managedFeedUID = hadManagedFeed && suggestion.managedFeed.candidateUID == draft.captureUID && !draft.captureUID.isEmpty
            && draft.captureUID != draft.playbackUID && draft.captureUID != draft.triggerUID ? draft.captureUID : nil
        draft.triggerUID = previousTriggerUID
        if previousTriggerUID.isEmpty { setTriggerUID(suggestedTriggerUID) }
        let unresolved = [suggestion.capture, suggestion.playback].contains { $0.candidateUID == nil }
        if unresolved { show("Review the preset’s device settings. Missing, ambiguous or unsupported devices were left unselected.") }
        else { clearMessage() }
    }
    @objc private func duplicateConfiguration() {
        guard !saving, !finding, !draft.configurationPath.isEmpty, let window else { return }
        let source = URL(fileURLWithPath: draft.configurationPath)
        let panel = NSSavePanel()
        panel.title = "Duplicate Preset"
        panel.message = "Save beside the original to keep relative coefficient-file references working. The copy will not be activated."
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " Copy." + source.pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .text]; panel.canCreateDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            do { try self.duplicatePreset(to: destination) }
            catch { self.show(error.localizedDescription) }
        }
    }
    private func duplicatePreset(to destination: URL) throws {
        let suggestions = try ProfileDeviceMapping.suggestions(configurationPath: draft.configurationPath, devices: devices)
        let path = try PresetFileDuplication.copy(source: URL(fileURLWithPath: draft.configurationPath), to: destination)
        captureText(); draft.configurationPath = path.path
        // The bytes and their relative file context are identical, so device choices stay local and unchanged.
        mappingSuggestions = suggestions
        showDraft(); clearMessage()
    }
    @objc private func revealExecutable() { reveal(draft.executablePath) }
    @objc private func revealConfiguration() { reveal(draft.configurationPath) }
    private func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    @objc private func findDSP() {
        guard !saving, !finding, !confirmationPending else { return }
        finding = true; updateBusy()
        let home = FileManager.default.homeDirectoryForCurrentUser
        editorTask = Task { @MainActor [weak self] in
            let result = await Task.detached { SetupDiscovery.find(homeDirectory: home) }.value
            guard let self else { return }
            self.finding = false; self.updateBusy()
            let paths = Array(Set(result.dsp.map(\.executablePath))).sorted()
            guard !paths.isEmpty else { self.show("No DSP executable found. Choose its location manually."); return }
            let menu = NSMenu()
            for path in paths {
                let item = NSMenuItem(title: path, action: #selector(self.selectDiscoveredDSP(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = path
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.findButton.bounds.height), in: self.findButton)
        }
    }
    @objc private func selectDiscoveredDSP(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        captureText(); draft.executablePath = path; showDraft(); clearMessage()
    }
    private func captureText() {
        draft.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.routeAlerts = alerts.state == .on && draft.managedFeedUID != nil
        if let value = Int(port.stringValue) { draft.websocketPort = value }
    }
    @objc private func save() {
        guard !saving, !finding, !confirmationPending else { return }
        captureText()
        guard let value = Int(port.stringValue), (1...65535).contains(value) else {
            advancedToggle.state = .on; advanced.isHidden = false
            show("WebSocket port must be between 1 and 65535."); return
        }
        draft.websocketPort = value
        guard !draft.name.isEmpty else { show("Enter a profile name."); return }
        guard !draft.configurationPath.isEmpty else { show("Choose a startup preset."); return }
        let currentConflicts = InterfaceProfileOverlap.automaticReplacementIDs(draft, against: savedProfiles)
        if draft.autoActivate, !currentConflicts.isEmpty,
           draft.confirmedAutoActivationReplacementIDs != currentConflicts {
            requestReplacementConfirmation(ids: currentConflicts, candidate: draft, onAccept: { [weak self] in
                guard let self else { return }
                self.draft.confirmedAutoActivationReplacementIDs = currentConflicts
                self.performSave()
            }, onCancel: { [weak self] in
                self?.show("Profile was not saved.")
            })
            return
        }
        draft.confirmedAutoActivationReplacementIDs = draft.autoActivate ? currentConflicts : []
        performSave()
    }
    private func performSave() {
        guard !saving, !finding, !confirmationPending else { return }
        saving = true; updateBusy(); clearMessage()
        let snapshot = draft
        editorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.onSave(snapshot); self.saving = false; self.closeSheet() }
            catch { self.saving = false; self.updateBusy(); self.show(error.localizedDescription) }
        }
    }
    private func updateBusy() {
        for control in controls { control.isEnabled = !saving && !finding && !confirmationPending }
        updateDevices()
        updatePresetFolderButton()
        duplicateButton.isEnabled = !saving && !finding && !confirmationPending && !draft.configurationPath.isEmpty
        revealPresetButton.isEnabled = !saving && !finding && !confirmationPending && !draft.configurationPath.isEmpty
    }
    @objc private func cancel() { guard !saving, !finding, !confirmationPending else { return }; closeSheet() }
    private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window); window.orderOut(nil) }
        else { close() }
    }
    package func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !saving, !finding, !confirmationPending else { return false }
        if sender.sheetParent != nil { closeSheet(); return false }
        return true
    }
    private func show(_ text: String) {
        message.stringValue = text; message.toolTip = text; message.isHidden = text.isEmpty
        resizeToFitContent()
    }
    private func clearMessage() { show("") }

    package var presetDirectoryForVerification: URL? { presetDirectory }
    package func openPresetsForVerification() { openPresetsFolder() }
    package var overlapMessageForVerification: String { overlapNote.stringValue }
    package func setAutoActivateForVerification(_ enabled: Bool) {
        automatic.state = enabled ? .on : .off; changeAutomatic()
    }
    package func setTriggerForVerification(_ uid: String) { setTriggerUID(uid) }
    package var confirmedReplacementIDsForVerification: Set<String> { draft.confirmedAutoActivationReplacementIDs }
    package var draftForVerification: InterfaceProfileDraft { captureText(); return draft }
    package var pathMinimumWidthsForVerification: Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        return configuration.frame.width >= 400
    }
    package var sectionTitlesForVerification: [String] {
        form.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first as? NSTextField }.map(\.stringValue)
    }
    package var presetDescriptionForVerification: String { presetHelp.stringValue }
    package var presetNameForVerification: String { configuration.stringValue }
    package var duplicateEnabledForVerification: Bool { duplicateButton.isEnabled }
    package var advancedHiddenForVerification: Bool { advanced.isHidden }
    package func toggleAdvancedForVerification() {
        advancedToggle.state = advancedToggle.state == .on ? .off : .on; toggleAdvanced()
    }
    package var contentHeightForVerification: CGFloat { window?.contentView?.frame.height ?? 0 }
    package var contentFitsForVerification: Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        return form.fittingSize.height <= bodyScroll.contentSize.height + 1
    }
    package func duplicateForVerification(to url: URL) throws { try duplicatePreset(to: url) }
    package func editNameForVerification(_ value: String) { name.stringValue = value }
    package func saveForVerification() { save() }
    package func waitForOperationForVerification() async { await editorTask?.value }
    package var displayedErrorForVerification: String { message.stringValue }
}

@MainActor private final class InterfaceEditorDocument: NSView {
    override var isFlipped: Bool { true }
}
