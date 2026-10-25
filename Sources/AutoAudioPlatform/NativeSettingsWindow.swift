import AppKit
import AutoAudioCore

@MainActor private final class SettingsNumberField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a", let editor = currentEditor() {
            editor.selectAll(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor private final class SettingsScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 || (modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "w") {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 || (modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "w") {
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// Scrolling is available only when a tab exceeds its actual viewport.
@MainActor private final class SettingsScrollView: NSScrollView {
    override func layout() {
        super.layout()
        documentView?.layoutSubtreeIfNeeded()
        let needsScroller = (documentView?.frame.height ?? 0) > contentSize.height + 1
        if hasVerticalScroller != needsScroller {
            hasVerticalScroller = needsScroller
            super.layout()
        }
    }
}

public enum SettingsTab: Int { case general, mainOutput, auxOutputs, interfaces }

/// Event-driven settings. The owner persists and applies each successful change.
@MainActor public final class NativeSettingsWindow: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private let tabs = NSTabView()
    private var auxContent: AuxFaderSettingsContent?
    private var interfacesContent: InterfacesSettingsContent?
    private var latestAuxSnapshot: AuxFaderSnapshot?
    private let onSaveAux: ((String, AuxPreferences) async throws -> Void)?
    private var selectedProfileID: String?
    private var selectedProfileName: String?
    private var numericTask: Task<Void, Never>?
    private var pendingNumericGroups = Set<NumericGroup>()
    private var pendingMainInputs: [String: (String, String)] = [:]
    private var numericSaveErrors: [NumericGroup: String] = [:]
    private var rebindingProfile = false
    private var committingNumbers = false
    private var preferences: UIPreferences
    private let onChange: (UIPreferences) throws -> Void
    private let onRefreshFaders: (() -> Void)?
    private let loginItemManager: LoginItemManager?
    private let onSetup: (() -> Void)?
    private let settingsDirectoryURL: URL?
    private let revealSettingsDirectory: (URL) -> Bool
    private var startupTask: Task<Void, Never>?
    package let startAtLoginButton = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
    package let startupMessage = NSTextField(wrappingLabelWithString: "")
    package let setupButton = NSButton(title: "Setup…", target: nil, action: nil)
    private let presetsFolderLabel = NSTextField(labelWithString: "No presets folder selected")
    private let openFolderButton = NSButton(title: "Open Folder", target: nil, action: nil)
    package let refreshFadersButton = NSButton(title: "Read Levels from DSP", target: nil, action: nil)
    private let refreshResultLabel = NSTextField(wrappingLabelWithString: "")
    private let silentModeButton = NSButton(checkboxWithTitle: "Silent Mode", target: nil, action: nil)
    private let keepActiveColorsButton = NSButton(checkboxWithTitle: "Keep Active Colors", target: nil, action: nil)
    private let followMacOSOutputButton = NSButton(checkboxWithTitle: "Follow macOS Output", target: nil, action: nil)
    private let automaticSwitchingButton = NSButton(checkboxWithTitle: "Automatic Switching", target: nil, action: nil)
    private let showMenuBarIconButton = NSButton(checkboxWithTitle: "Show Menu Bar Icon", target: nil, action: nil)
    private let openSettingsFolderButton = NSButton(title: "Open Settings Folder", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let numberHold = SettingsNumberField(string: "")
    private var saveError: String?
    private var settingsDirectoryError: String?
    private var numberFields: [String: NSTextField] = [:]
    private let peakHold = SettingsNumberField(string: "")
    private let falloff = SettingsNumberField(string: "")
    private let refreshRate = SettingsNumberField(string: "")
    private let meterMinimum = SettingsNumberField(string: "")
    private let meterMaximum = SettingsNumberField(string: "")
    private let mainMinimum = SettingsNumberField(string: "")
    private let mainMaximum = SettingsNumberField(string: "")
    private let numericMode = NSSegmentedControl(labels: ["Realtime", "Peak Hold"], trackingMode: .selectOne, target: nil, action: nil)
    private let profileLabel = NSTextField(labelWithString: "")
    private var profileID: String?
    private var profileName: String?

    public init(preferences: UIPreferences, error: String? = nil, profileID: String? = nil, profileName: String? = nil,
                auxSnapshot: AuxFaderSnapshot? = nil,
                loginItemManager: LoginItemManager? = nil, onSetup: (() -> Void)? = nil,
                settingsDirectoryURL: URL? = nil,
                revealSettingsDirectory: ((URL) -> Bool)? = nil,
                onSaveAux: ((String, AuxPreferences) async throws -> Void)? = nil,
                onRefreshFaders: (() -> Void)? = nil,
                interfaceProfiles: InterfaceProfilesHandlers? = nil,
                onChange: @escaping (UIPreferences) throws -> Void) {
        self.onSaveAux = onSaveAux
        self.latestAuxSnapshot = auxSnapshot
        self.selectedProfileID = profileID; self.selectedProfileName = profileName
        self.preferences = preferences
        self.onChange = onChange
        self.onRefreshFaders = onRefreshFaders
        self.loginItemManager = loginItemManager
        self.onSetup = onSetup
        self.settingsDirectoryURL = settingsDirectoryURL
        self.revealSettingsDirectory = revealSettingsDirectory ?? { NSWorkspace.shared.open($0) }
        self.profileID = profileID; self.profileName = profileName
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let titleHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled, .closable]).height
        let contentHeight = min(660, max(1, screenFrame.height - titleHeight))
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: min(620, screenFrame.width), height: contentHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(startupApplicationActivated),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        let root = NSView()
        window.contentView = root
        let explanation = NSTextField(wrappingLabelWithString: "Hide pop-up notifications.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setAccessibilityLabel("Settings error")
        profileLabel.lineBreakMode = .byTruncatingTail
        silentModeButton.target = self
        silentModeButton.action = #selector(toggleSilentMode)
        silentModeButton.setAccessibilityHelp(explanation.stringValue)
        keepActiveColorsButton.target = self
        keepActiveColorsButton.action = #selector(toggleKeepActiveColors)
        let appearanceExplanation = NSTextField(wrappingLabelWithString:
            "Keep colors when the panel is unfocused.")
        appearanceExplanation.font = .systemFont(ofSize: 12)
        appearanceExplanation.textColor = .secondaryLabelColor
        keepActiveColorsButton.setAccessibilityHelp(appearanceExplanation.stringValue)
        followMacOSOutputButton.target = self
        followMacOSOutputButton.action = #selector(toggleFollowMacOSOutput)
        automaticSwitchingButton.target = self
        automaticSwitchingButton.action = #selector(toggleAutomaticSwitching)
        let routingExplanation = NSTextField(wrappingLabelWithString:
            "Remember manual macOS output choices while Automatic Switching is on.")
        routingExplanation.font = .systemFont(ofSize: 12)
        routingExplanation.textColor = .secondaryLabelColor
        followMacOSOutputButton.setAccessibilityHelp("During Automatic Switching, manual macOS output changes update the saved Fallback/Bypass Output. Companion Mode does not follow them.")
        numberHold.toolTip = "In Realtime, higher fresh peaks appear immediately. Lower readings wait until the hold expires. 0 ms shows every fresh peak; range 0 to 5000 ms."
        peakHold.toolTip = "In Realtime, hold the peak marker before falloff. Peak Hold retains the maximum until you switch back to Realtime."
        refreshRate.toolTip = "Target queries per second, from 1 to 120. DSP chunk timing and response time limit fresh data; higher targets can add work without new readings."
        meterMinimum.toolTip = "Lower display bound for all input/output meters; changes no audio gain."
        meterMaximum.toolTip = "Upper display bound for all input/output meters. Clipping remains at 0 dBFS."
        numericMode.target = self; numericMode.action = #selector(changeNumericMode)
        numericMode.identifier = NSUserInterfaceItemIdentifier("Meter numeric mode")
        numericMode.setAccessibilityLabel("Meter numeric mode")
        let travelExplanation = NSTextField(wrappingLabelWithString: "Display range only; DSP gain limits still apply.")
        travelExplanation.font = .systemFont(ofSize: 12); travelExplanation.textColor = .secondaryLabelColor
        presetsFolderLabel.lineBreakMode = .byTruncatingMiddle
        presetsFolderLabel.cell?.usesSingleLineMode = true
        presetsFolderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        presetsFolderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        presetsFolderLabel.font = .systemFont(ofSize: 12)
        presetsFolderLabel.textColor = .secondaryLabelColor
        presetsFolderLabel.setAccessibilityLabel("CamillaDSP presets folder")
        let chooseFolder = NSButton(title: "Choose Folder…", target: self, action: #selector(choosePresetsFolder))
        chooseFolder.bezelStyle = .rounded
        let clearFolder = NSButton(title: "Clear", target: self, action: #selector(clearPresetsFolder))
        clearFolder.bezelStyle = .rounded
        chooseFolder.toolTip = "Choose the CamillaDSP presets folder."
        clearFolder.toolTip = "Clear the selected presets folder."
        openFolderButton.bezelStyle = .rounded
        openFolderButton.target = self; openFolderButton.action = #selector(openPresetsFolder)
        let folderControls = NSStackView(views: [chooseFolder, openFolderButton, clearFolder])
        let presetsHelp = NSTextField(wrappingLabelWithString: "Choose the folder containing your CamillaDSP presets.")
        presetsHelp.font = .systemFont(ofSize: 12); presetsHelp.textColor = .secondaryLabelColor
        let folderSection = NSStackView(views: [presetsHelp, folderControls, presetsFolderLabel])
        folderSection.orientation = .vertical; folderSection.alignment = .leading; folderSection.spacing = 4
        folderSection.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let settingsFolderHelp = NSTextField(wrappingLabelWithString: "Quit the app before editing JSON files. Reopen to apply changes.")
        settingsFolderHelp.font = .systemFont(ofSize: 12); settingsFolderHelp.textColor = .secondaryLabelColor
        openSettingsFolderButton.bezelStyle = .rounded
        openSettingsFolderButton.target = self; openSettingsFolderButton.action = #selector(openSettingsFolder)
        openSettingsFolderButton.isEnabled = settingsDirectoryURL != nil
        openSettingsFolderButton.toolTip = settingsDirectoryURL == nil ? "The active settings folder is unavailable." : nil
        let settingsFolderSection = NSStackView(views: [openSettingsFolderButton, settingsFolderHelp])
        settingsFolderSection.orientation = .vertical; settingsFolderSection.alignment = .leading; settingsFolderSection.spacing = 4
        refreshFadersButton.bezelStyle = .rounded
        refreshFadersButton.target = self; refreshFadersButton.action = #selector(refreshFaders)
        refreshFadersButton.isEnabled = false
        refreshResultLabel.font = .systemFont(ofSize: 11)
        refreshResultLabel.maximumNumberOfLines = 3
        refreshResultLabel.lineBreakMode = .byTruncatingTail
        let syncHelp = NSTextField(wrappingLabelWithString: "Refresh Main/Aux levels, mutes and limits without changing audio.")
        syncHelp.font = .systemFont(ofSize: 12); syncHelp.textColor = .secondaryLabelColor
        let refreshAction = NSStackView(views: [refreshFadersButton, refreshResultLabel])
        refreshAction.alignment = .centerY; refreshAction.spacing = 8
        refreshResultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let refreshSection = NSStackView(views: [refreshAction, syncHelp])
        refreshSection.orientation = .vertical; refreshSection.alignment = .leading; refreshSection.spacing = 4
        refreshResultLabel.isHidden = true
        func section(_ title: String, _ views: [NSView]) -> NSStackView {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            let section = NSStackView(views: [heading] + views)
            section.identifier = NSUserInterfaceItemIdentifier("Settings " + title)
            section.orientation = .vertical; section.alignment = .leading; section.spacing = 8
            section.translatesAutoresizingMaskIntoConstraints = false
            return section
        }
        func divider() -> NSBox {
            let line = NSBox(); line.boxType = .separator
            return line
        }
        let automaticHelp = NSTextField(wrappingLabelWithString: "Turn off for DSP-only Companion Mode. Keeps the current macOS output.")
        automaticHelp.font = .systemFont(ofSize: 12); automaticHelp.textColor = .secondaryLabelColor
        automaticSwitchingButton.setAccessibilityHelp(automaticHelp.stringValue)
        startAtLoginButton.target = self; startAtLoginButton.action = #selector(toggleStartAtLogin)
        startAtLoginButton.setAccessibilityHelp("Open CamillaCompanion after signing in. Changing this leaves the current audio session running.")
        startupMessage.font = .systemFont(ofSize: 12); startupMessage.textColor = .secondaryLabelColor
        startupMessage.maximumNumberOfLines = 3
        setupButton.bezelStyle = .rounded; setupButton.target = self; setupButton.action = #selector(openSetup)
        setupButton.isEnabled = onSetup != nil
        setupButton.toolTip = "Inspect your CamillaDSP setup. Existing settings are preserved."
        showMenuBarIconButton.target = self; showMenuBarIconButton.action = #selector(toggleShowMenuBarIcon)
        let menuBarHelp = NSTextField(wrappingLabelWithString: "Open the app again to show its panel when the icon is hidden.")
        menuBarHelp.font = .systemFont(ofSize: 12); menuBarHelp.textColor = .secondaryLabelColor
        showMenuBarIconButton.setAccessibilityHelp(menuBarHelp.stringValue)
        renderStartupStatus()
        let generalSections = [section("Startup", [startAtLoginButton, startupMessage, setupButton]),
            section("Menu Bar", [showMenuBarIconButton, menuBarHelp]),
            section("Appearance", [keepActiveColorsButton, appearanceExplanation]),
            section("Routing", [automaticSwitchingButton, automaticHelp, followMacOSOutputButton, routingExplanation]),
            section("Notifications", [silentModeButton, explanation]),
            section("Presets", [folderSection]), section("Settings Files", [settingsFolderSection]), section("DSP Levels", [refreshSection])]
        let meterModeHelp = NSTextField(wrappingLabelWithString: "Realtime follows levels. Peak Hold keeps the highest reading.")
        meterModeHelp.font = .systemFont(ofSize: 12); meterModeHelp.textColor = .secondaryLabelColor
        let meterModeGroup = NSStackView(views: [numericMode, meterModeHelp])
        meterModeGroup.orientation = .vertical; meterModeGroup.alignment = .leading; meterModeGroup.spacing = 4
        let meterFields = NSStackView(views: [numberRow("Number hold", numberHold, unit: "ms"),
            numberRow("Peak marker hold", peakHold, unit: "ms"), numberRow("Falloff", falloff, unit: "dB/s"),
            numberRow("Refresh rate", refreshRate, unit: "Hz"), numberRow("Meter minimum", meterMinimum, unit: "dBFS"),
            numberRow("Meter maximum", meterMaximum, unit: "dBFS")])
        meterFields.orientation = .vertical; meterFields.alignment = .leading; meterFields.spacing = 8
        let volumeSection = section("Volume Controls", [profileLabel, numberRow("Main minimum", mainMinimum, unit: "dB"),
            numberRow("Main maximum", mainMaximum, unit: "dB"), travelExplanation])
        let meteringSection = section("Live Metering", [meterModeGroup, meterFields])
        meteringSection.spacing = 14
        let mainSections = [volumeSection, meteringSection]
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.identifier = NSUserInterfaceItemIdentifier("Settings tabs")
        root.addSubview(tabs)
        func addTab(_ title: String, _ tab: SettingsTab, _ content: NSView) {
            let item = NSTabViewItem(identifier: tab.rawValue); item.label = title
            let scroll = SettingsScrollView(); scroll.hasVerticalScroller = false; scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false; scroll.identifier = NSUserInterfaceItemIdentifier("Settings scroll " + title)
            let document = SettingsScrollDocument(); document.translatesAutoresizingMaskIntoConstraints = false
            content.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = document; document.addSubview(content)
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: tab == .auxOutputs ? 0 : 24),
                content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: tab == .auxOutputs ? 0 : -24),
                content.topAnchor.constraint(equalTo: document.topAnchor, constant: tab == .auxOutputs ? 0 : 20),
                content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: tab == .auxOutputs ? 0 : -16)])
            item.view = scroll; tabs.addTabViewItem(item)
        }
        func body(_ sections: [NSStackView]) -> NSStackView {
            var views: [NSView] = []
            for (index, section) in sections.enumerated() {
                if index > 0 { views.append(divider()) }; views.append(section)
            }
            let stack = NSStackView(views: views)
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
            stack.identifier = NSUserInterfaceItemIdentifier("Settings body")
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            for section in sections {
                for view in section.arrangedSubviews where view is NSTextField || view is NSStackView {
                    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
            return stack
        }
        addTab("General", .general, body(generalSections))
        addTab("Main Output", .mainOutput, body(mainSections))
        if let auxSnapshot {
            let content = AuxFaderSettingsContent(snapshot: auxSnapshot)
            auxContent = content
            configureAux(content)
            addTab("Aux Outputs", .auxOutputs, content)
        } else {
            addTab("Aux Outputs", .auxOutputs, NSTextField(wrappingLabelWithString: "Select a profile to configure Aux Outputs."))
        }
        let interfaceContent = InterfacesSettingsContent(handlers: interfaceProfiles,
            presetsFolder: { [weak self] in self?.preferences.presetsFolderPath })
        interfacesContent = interfaceContent
        addTab("Interfaces", .interfaces, interfaceContent)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        let page = NSStackView(views: [errorLabel, tabs])
        page.orientation = .vertical; page.alignment = .leading; page.spacing = 8
        page.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            page.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            page.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            tabs.widthAnchor.constraint(equalTo: page.widthAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12)
        ])
        updatePreferences(preferences, error: error)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func numberRow(_ title: String, _ field: NSTextField, unit: String) -> NSStackView {
        field.identifier = NSUserInterfaceItemIdentifier(title)
        field.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 145).isActive = true
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [label, field, NSTextField(labelWithString: unit)])
        row.spacing = 8
        field.delegate = self
        field.setAccessibilityHelp(field.toolTip)
        numberFields[title] = field
        return row
    }

    public func updateInterfaceDevices(_ devices: [AudioDevice]) {
        interfacesContent?.updateDevices(devices)
    }

    package func interfaceEditorForVerification(_ draft: InterfaceProfileDraft) -> InterfaceProfileEditor? {
        interfacesContent?.editorForVerification(draft)
    }

    public func updateInterfaceRuntime(activeID: String?, selectedID: String?) {
        interfacesContent?.updateRuntime(activeID: activeID, selectedID: selectedID)
    }

    public func updateProfile(id: String?, name: String?) {
        selectedProfileID = id; selectedProfileName = name
        guard !rebindingProfile else { return }
        guard profileID != id else { profileName = name; refreshProfileLabel(); return }
        rebindingProfile = true
        defer { rebindingProfile = false }
        window?.makeFirstResponder(nil)
        // Complete valid old-profile edits before rebinding. Incomplete inputs
        // remain with that profile and can never reach the newly selected one.
        saveNumericChanges()
        if let old = profileID, pendingNumericGroups.contains(.mainRange) {
            pendingMainInputs[old] = (mainMinimum.stringValue, mainMaximum.stringValue)
        }
        pendingNumericGroups.remove(.mainRange); numericSaveErrors[.mainRange] = nil
        profileID = id; profileName = name
        if let id, let inputs = pendingMainInputs[id] {
            mainMinimum.stringValue = inputs.0; mainMaximum.stringValue = inputs.1
            pendingNumericGroups.insert(.mainRange)
        } else { showMainRange() }
        auxContent?.selectProfile(id)
        if pendingNumericGroups.contains(.mainRange) { saveNumericChanges() }
        refreshProfileLabel(); refreshNumericFeedback()
    }

    private func refreshProfileLabel() {
        mainMinimum.isEnabled = profileID != nil; mainMaximum.isEnabled = profileID != nil
        profileLabel.stringValue = profileID.map { "Main range: " + (profileName ?? $0) } ?? "Main range: select a profile first"
    }

    private func showMainRange() {
        let range = preferences.mainSliderRange(profileID: profileID)
        mainMinimum.stringValue = String(format: "%g", range.minimumDB)
        mainMaximum.stringValue = String(format: "%g", range.maximumDB)
    }

    private func configureAux(_ content: AuxFaderSettingsContent) {
        content.selectProfile(profileID)
        content.onSave = onSaveAux
    }

    public func updateAuxSnapshot(_ snapshot: AuxFaderSnapshot?) {
        latestAuxSnapshot = snapshot
        guard let snapshot else { auxContent?.invalidateAuthority(); return }
        if let auxContent { auxContent.updateSnapshot(snapshot); return }
        let content = AuxFaderSettingsContent(snapshot: snapshot)
        auxContent = content; configureAux(content)
        if let scroll = tabs.tabViewItems[SettingsTab.auxOutputs.rawValue].view as? NSScrollView,
           let document = scroll.documentView {
            document.subviews.forEach { $0.removeFromSuperview() }
            content.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                content.topAnchor.constraint(equalTo: document.topAnchor),
                content.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        }
    }

    public func updatePreferences(_ preferences: UIPreferences, error: String? = nil, preserveNumericDrafts: Bool = false) {
        self.preferences = preferences
        silentModeButton.state = preferences.silentMode ? .on : .off
        keepActiveColorsButton.state = preferences.keepActiveColors ? .on : .off
        followMacOSOutputButton.state = preferences.followMacOSOutput ? .on : .off
        automaticSwitchingButton.state = preferences.automaticSwitching ? .on : .off
        showMenuBarIconButton.state = preferences.showMenuBarIcon ? .on : .off
        followMacOSOutputButton.isEnabled = preferences.automaticSwitching
        presetsFolderLabel.stringValue = preferences.presetsFolderPath ?? "No presets folder selected"
        presetsFolderLabel.toolTip = preferences.presetsFolderPath
        let folder = presetsFolderAvailability
        openFolderButton.isEnabled = folder.url != nil
        openFolderButton.toolTip = folder.reason ?? "Open the selected presets folder in Finder."
        openFolderButton.setAccessibilityHelp(openFolderButton.toolTip)
        let settingsFolder = settingsDirectoryAvailability
        openSettingsFolderButton.isEnabled = settingsFolder.url != nil
        openSettingsFolderButton.toolTip = settingsFolder.reason ?? "Open the active settings folder in Finder."
        openSettingsFolderButton.setAccessibilityHelp(openSettingsFolderButton.toolTip)
        numericMode.selectedSegment = preferences.meterNumericMode == .realtime ? 0 : 1
        for group in NumericGroup.allCases where !pendingNumericGroups.contains(group) && !fields(for: group).contains(where: { $0.currentEditor() != nil }) {
            switch group {
            case .numberHold: numberHold.stringValue = String(format: "%g", preferences.meterOptions.numberHoldMilliseconds)
            case .peakHold: peakHold.stringValue = String(format: "%g", preferences.meterOptions.peakHoldMilliseconds)
            case .falloff: falloff.stringValue = String(format: "%g", preferences.meterOptions.falloffDBPerSecond)
            case .refresh: refreshRate.stringValue = String(format: "%g", preferences.meterOptions.refreshHz)
            case .meterRange:
                meterMinimum.stringValue = String(format: "%g", preferences.meterOptions.minimumDB)
                meterMaximum.stringValue = String(format: "%g", preferences.meterOptions.maximumDB)
            case .mainRange: showMainRange()
            }
        }
        refreshProfileLabel(); saveError = error; refreshNumericFeedback()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    public var selectedTab: SettingsTab { SettingsTab(rawValue: tabs.indexOfTabViewItem(tabs.selectedTabViewItem!)) ?? .general }

    public func selectTab(_ tab: SettingsTab) { tabs.selectTabViewItem(at: tab.rawValue) }

    public func show(tab: SettingsTab? = nil) {
        if let tab { selectTab(tab) }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if selectedProfileID != profileID { updateProfile(id: selectedProfileID, name: selectedProfileName) }
        refreshStartupStatus()
    }

    @objc private func startupApplicationActivated() {
        if window?.isVisible == true { refreshStartupStatus() }
    }

    /// Read registration only on relevant UI events, never on a timer or audio snapshot.
    package func refreshStartupStatus() {
        guard startupTask == nil, let loginItemManager else { return }
        startAtLoginButton.isEnabled = false
        startupTask = Task { @MainActor [weak self] in
            _ = await loginItemManager.refresh()
            guard let self else { return }
            self.startupTask = nil
            self.renderStartupStatus()
        }
    }

    private func renderStartupStatus(error: String? = nil) {
        let status = loginItemManager?.status
        startAtLoginButton.state = status?.isEnabled == true ? .on : .off
        startAtLoginButton.isEnabled = startupTask == nil && status?.canChange == true
        startupMessage.stringValue = error ?? status?.message ?? "Startup is unavailable in this preview."
        startupMessage.textColor = error == nil ? .secondaryLabelColor : .systemRed
        startupMessage.isHidden = startupMessage.stringValue.isEmpty
        startupMessage.toolTip = startupMessage.stringValue
        startAtLoginButton.setAccessibilityValue(startAtLoginButton.state == .on ? "On" : "Off")
    }

    @objc private func toggleStartAtLogin() {
        guard startupTask == nil, let loginItemManager else { renderStartupStatus(); return }
        let enabled = startAtLoginButton.state == .on
        startAtLoginButton.isEnabled = false
        startupTask = Task { @MainActor [weak self] in
            var failure: String?
            do { _ = try await loginItemManager.setEnabled(enabled) }
            catch { failure = error.localizedDescription }
            guard let self else { return }
            self.startupTask = nil
            self.renderStartupStatus(error: failure)
        }
    }

    @objc private func openSetup() { onSetup?() }

    package func waitForStartupUpdate() async { await startupTask?.value }

    public func updateFaderRefreshAvailability(reason: String?) {
        refreshFadersButton.isEnabled = reason == nil && onRefreshFaders != nil
        refreshFadersButton.toolTip = reason
        refreshFadersButton.setAccessibilityHelp(reason ?? "Refresh Main/Aux levels, mutes and limits without changing audio.")
    }

    public func updateFaderRefreshResult(error: String?) {
        refreshResultLabel.stringValue = error ?? "Fader values synced."
        refreshResultLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
        refreshResultLabel.toolTip = refreshResultLabel.stringValue
        refreshResultLabel.isHidden = false
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    public var faderRefreshEnabled: Bool { refreshFadersButton.isEnabled }
    public var faderRefreshHelp: String? { refreshFadersButton.toolTip }
    public var faderRefreshResult: String? { refreshResultLabel.isHidden ? nil : refreshResultLabel.stringValue }
    @objc private func refreshFaders() {
        guard refreshFadersButton.isEnabled else { return }
        refreshResultLabel.isHidden = true
        onRefreshFaders?()
    }

    @objc private func choosePresetsFolder() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose CamillaDSP Presets Folder"
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.allowsMultipleSelection = false; picker.canCreateDirectories = true
        if let path = preferences.presetsFolderPath { picker.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = picker.url else { return }
            self.savePresetsFolder(url.path)
        }
    }

    @objc private func clearPresetsFolder() { savePresetsFolder(nil) }

    private var presetsFolderAvailability: (url: URL?, reason: String?) {
        guard let path = preferences.presetsFolderPath, !path.isEmpty else {
            return (nil, "Choose a presets folder first.")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return (nil, "Choose an absolute presets folder path.") }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (nil, "The selected presets folder is missing or is not a directory.")
        }
        return (url, nil)
    }

    @objc private func openPresetsFolder() {
        let folder = presetsFolderAvailability
        guard let url = folder.url else {
            saveError = folder.reason; refreshNumericFeedback(); return
        }
        if !NSWorkspace.shared.open(url) {
            saveError = "Could not open the presets folder: " + url.path
            refreshNumericFeedback()
        }
    }

    private var settingsDirectoryAvailability: (url: URL?, reason: String?) {
        guard let settingsDirectoryURL else { return (nil, "The active settings folder is unavailable.") }
        let url = settingsDirectoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            return (nil, "The active settings folder is missing or inaccessible.")
        }
        return (url, nil)
    }

    @objc private func openSettingsFolder() {
        let folder = settingsDirectoryAvailability
        guard let url = folder.url else {
            settingsDirectoryError = folder.reason; refreshNumericFeedback(); return
        }
        guard revealSettingsDirectory(url) else {
            settingsDirectoryError = "Could not open the settings folder in Finder."
            refreshNumericFeedback(); return
        }
        settingsDirectoryError = nil; refreshNumericFeedback()
    }

    private func savePreferences(_ next: UIPreferences) {
        do { try onChange(try next.validated()); updatePreferences(next, preserveNumericDrafts: true) }
        catch { updatePreferences(preferences, error: "Could not save Settings: " + error.localizedDescription, preserveNumericDrafts: true) }
    }

    private func savePresetsFolder(_ path: String?) {
        var next = preferences; next.presetsFolderPath = path; savePreferences(next)
    }
    @objc private func toggleSilentMode() {
        var next = preferences; next.silentMode = silentModeButton.state == .on; savePreferences(next)
    }
    @objc private func toggleShowMenuBarIcon() {
        var next = preferences; next.showMenuBarIcon = showMenuBarIconButton.state == .on; savePreferences(next)
    }
    @objc private func toggleKeepActiveColors() {
        var next = preferences; next.keepActiveColors = keepActiveColorsButton.state == .on; savePreferences(next)
    }
    @objc private func toggleFollowMacOSOutput() {
        var next = preferences; next.followMacOSOutput = followMacOSOutputButton.state == .on; savePreferences(next)
    }
    @objc private func toggleAutomaticSwitching() {
        var next = preferences; next.automaticSwitching = automaticSwitchingButton.state == .on; savePreferences(next)
    }
    @objc private func changeNumericMode() {
        var next = preferences; next.meterNumericMode = numericMode.selectedSegment == 1 ? .peakHold : .realtime
        savePreferences(next)
    }

    private enum NumericGroup: CaseIterable, Hashable {
        case numberHold, peakHold, falloff, refresh, meterRange, mainRange
    }
    private func fields(for group: NumericGroup) -> [NSTextField] {
        switch group {
        case .numberHold: [numberHold]
        case .peakHold: [peakHold]
        case .falloff: [falloff]
        case .refresh: [refreshRate]
        case .meterRange: [meterMinimum, meterMaximum]
        case .mainRange: [mainMinimum, mainMaximum]
        }
    }
    private func numericCandidate(for group: NumericGroup) throws -> UIPreferences {
        func number(_ field: NSTextField, _ name: String) throws -> Double {
            guard let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
                throw SwitcherError.message("\(name) must be a finite number.")
            }
            return value
        }
        // Always merge into the latest confirmed preferences, including meter
        // mode changes received from the main panel while a field is edited.
        var candidate = preferences
        switch group {
        case .numberHold: candidate.meterOptions.numberHoldMilliseconds = try number(numberHold, "Number hold")
        case .peakHold: candidate.meterOptions.peakHoldMilliseconds = try number(peakHold, "Peak marker hold")
        case .falloff: candidate.meterOptions.falloffDBPerSecond = try number(falloff, "Falloff")
        case .refresh: candidate.meterOptions.refreshHz = try number(refreshRate, "Refresh rate")
        case .meterRange:
            candidate.meterOptions.minimumDB = try number(meterMinimum, "Meter minimum")
            candidate.meterOptions.maximumDB = try number(meterMaximum, "Meter maximum")
        case .mainRange:
            if let profileID {
                let range = try MainSliderRange(minimumDB: number(mainMinimum, "Main minimum"), maximumDB: number(mainMaximum, "Main maximum")).validated()
                if range != preferences.mainSliderRange(profileID: profileID) { candidate.mainSliderRanges[profileID] = range }
            }
        }
        return try candidate.validated()
    }

    public func controlTextDidChange(_ notification: Notification) {
        let changedField = notification.object as? NSTextField
        for group in NumericGroup.allCases {
            if let changedField {
                if fields(for: group).contains(where: { $0 === changedField }) { pendingNumericGroups.insert(group); numericSaveErrors[group] = nil }
            } else if (try? numericCandidate(for: group)) != preferences {
                pendingNumericGroups.insert(group); numericSaveErrors[group] = nil
            }
        }
        saveError = nil; refreshNumericFeedback()
        numericTask?.cancel()
        numericTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            self?.saveNumericChanges()
        }
    }
    public func controlTextDidEndEditing(_ notification: Notification) { saveNumericChanges() }

    private func saveNumericChanges() {
        guard !committingNumbers else { return }
        committingNumbers = true
        defer { committingNumbers = false }
        numericTask?.cancel(); numericTask = nil
        for group in NumericGroup.allCases where pendingNumericGroups.contains(group) {
            let candidate: UIPreferences
            do { candidate = try numericCandidate(for: group) }
            catch { continue }
            do {
                if candidate != preferences { try onChange(candidate) }
                preferences = candidate; pendingNumericGroups.remove(group); numericSaveErrors[group] = nil
                if group == .mainRange, let profileID { pendingMainInputs[profileID] = nil }
            } catch { numericSaveErrors[group] = "Could not save Settings: " + error.localizedDescription }
        }
        refreshNumericFeedback()
    }

    private func refreshNumericFeedback() {
        for field in numberFields.values { field.textColor = .labelColor; field.setAccessibilityHelp(field.toolTip) }
        var validation: String?
        for group in NumericGroup.allCases {
            do { _ = try numericCandidate(for: group) }
            catch {
                if validation == nil { validation = error.localizedDescription }
                for field in fields(for: group) { field.textColor = .systemRed; field.setAccessibilityHelp(error.localizedDescription) }
            }
        }
        let failure = NumericGroup.allCases.compactMap { numericSaveErrors[$0] }.first
        errorLabel.stringValue = settingsDirectoryError ?? saveError ?? failure ?? validation ?? ""
        errorLabel.textColor = .systemRed; errorLabel.toolTip = errorLabel.stringValue
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
    }

    package func waitForPendingChanges() async {
        saveNumericChanges()
        await auxContent?.waitForPendingChanges()
    }
    private func flushPendingChanges() { saveNumericChanges(); auxContent?.flushPendingChanges() }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { window?.makeFirstResponder(nil); flushPendingChanges(); return true }
    public override func close() { window?.makeFirstResponder(nil); flushPendingChanges(); super.close() }
}
