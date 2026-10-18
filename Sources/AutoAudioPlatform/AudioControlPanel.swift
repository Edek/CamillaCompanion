import AppKit
import AutoAudioCore

/// Native controls stay alive across updates so keyboard and accessibility focus survive.
@MainActor package final class AudioControlPanel: NSView, NSMenuDelegate {
    package override var isFlipped: Bool { true }
    // One neutral wash covers the complete document, including its outer padding.
    // The popover still owns the glass; sections do not add separate surfaces.
    package static func continuousGlassTint(dark: Bool, reduceTransparency: Bool) -> NSColor {
        if reduceTransparency {
            let gray: CGFloat = dark ? 0.14 : 0.94
            return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
        }
        return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: dark ? 0.18 : 0.07)
    }
    package override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Self.continuousGlassTint(dark: dark,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency).setFill()
        dirtyRect.intersection(bounds).fill()
        super.draw(dirtyRect)
    }
    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) { needsDisplay = true }
    package var onLayout: (() -> Void)?
    package var onClose: (() -> Void)?
    package var onPin: ((Bool) -> Void)?
    package var onChildMenuTracking: ((Bool) -> Void)?
    package var onDSPMode: ((Int) -> Void)?
    package var onGUIMode: ((Int) -> Void)?
    package var onRouting: ((Int) -> Void)?
    package var onFallbackMode: ((String, FallbackOutputMode) -> Void)?
    package var onFallbackOutput: ((String, AudioDevice) -> Void)?
    var onProfile: ((String) -> Void)?
    package var onOpen: (() -> Void)?
    package var onRestart: (() -> Void)?
    package var onDSPContext: (() -> Void)?
    package var onGUIContext: (() -> Void)?
    package var onDismissError: (() -> Void)?
    var onMore: ((NSButton) -> Void)?
    package var onPreset: ((String) -> Void)?
    package var onPreparePresetMenu: (() async -> Bool)? {
        didSet { presetPicker.prepareMenu = onPreparePresetMenu }
    }

    package let mainPanel = AuxFaderPanel(frame: .zero, mainOnly: true)
    package let metersPanel = SignalLevelsPanel(frame: .zero)
    package let auxPanel = AuxFaderPanel(frame: .zero)
    package let stack = NSStackView()
    package let controlsDisclosure = NSButton(title: "Audio Controls", target: nil, action: nil)
    package let controlsBody = NSStackView()
    package private(set) var controlsExpanded = true
    package private(set) var trackedMenus: Set<ObjectIdentifier> = []
    package var pendingControlsExpansion: Bool?
    package let pinButton = AudioPinButton(title: "Pin", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: ApplicationMetadata.name)
    private let profilePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    package let statusLabel = NSTextField(labelWithString: "Controller starting")
    package let routingStatusLabel = NSTextField(labelWithString: "Routing unavailable")
    package let guiStatusLabel = NSTextField(labelWithString: "GUI unavailable")
    package let dspStatusIcon = NSImageView()
    package let routingStatusIcon = NSImageView()
    package let guiStatusIcon = NSImageView()
    package let outputLabel = NSTextField(labelWithString: "System Output: Unavailable")
    package let dspOutputLabel = NSTextField(labelWithString: "DSP Output: Unavailable")
    package let statusUpdateLabel = NSTextField(labelWithString: "Status: Starting")
    package let dspControl = NSSegmentedControl(labels: ["Auto", "On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    package let routingControl = NSSegmentedControl(labels: ["Processed", "Bypassed"], trackingMode: .selectOne, target: nil, action: nil)
    package let fallbackControl = NSSegmentedControl(labels: ["Auto", "Force", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    package let fallbackPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    package let guiControl = NSSegmentedControl(labels: ["Auto", "On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    package let openButton = AudioRoundedButton(title: "Open Web Interface", target: nil, action: nil)
    package let restartButton = AudioRestartButton(title: "Restart DSP", target: nil, action: nil)
    package let statusActionButton = AudioRoundedButton(title: "Actions", target: nil, action: nil)
    package private(set) var statusActions: [MenuPanelStatusAction] = []
    package let statusActionSlot = NSView()
    package let moreButton = AudioRoundedButton(title: "More", target: nil, action: nil)
    package let presetPicker = PresetPopUpButton(frame: .zero, pullsDown: false)
    package var compactButtons: [AudioRoundedButton] { [pinButton, moreButton, statusActionButton] }
    private var presetChoices: [PresetChoice] = []
    private var updatingPresets = false
    private weak var observedWindow: NSWindow?
    private struct PresetChoice: Equatable {
        let id: String
        let title: String
    }
    package let header = NSStackView()
    private var profileIDs: [String?] = []
    private struct RenderState: Equatable {
        let texts: [String?]
        let flags: [Bool]
        let selections: [Int]
    }
    private var observedRoutingSegment = -1
    private var routingActionAvailability = [false, false]
    private var renderedState: RenderState?
    private var geometryState: [String?]?
    private var emphasisStates: [ObjectIdentifier: String] = [:]
    package struct FallbackRenderState: Equatable {
        let profileID: String?
        let preference: FallbackOutputPreference
        let devices: [AudioDevice]
        let enabled: Bool
        let automaticOutput: AudioDevice?
    }
    private var fallbackState: FallbackRenderState?
    private var fallbackModeRow: NSView?
    private var fallbackOutputRow: NSView?
    private var routingRow: NSView?
    package var pendingFallbackState: FallbackRenderState?
    private var fallbackMenuTracking = false
    private var fallbackDevices: [AudioDevice] = []
    private var companionDSPControls: Bool?
    private var renderedGUIInstallation: GUIInstallationState?
    private var actualGUIStatusEmphasis: MenuStatusEmphasis = .neutral

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        mainPanel.presentsStatusFeedbackLocally = false
        auxPanel.presentsStatusFeedbackLocally = false
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 388),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15)
        ])
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(profilePicker)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
        AudioControlStyle.configureCompact(pinButton, width: AudioControlStyle.pinWidth)
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.target = self; pinButton.action = #selector(pinPressed)
        pinButton.toolTip = "Keep this panel open when switching applications. Escape or the status icon closes it."
        pinButton.setAccessibilityLabel("Pin panel")
        header.addArrangedSubview(pinButton)
        profilePicker.menu?.delegate = self
        presetPicker.menu?.delegate = self
        fallbackPicker.menu?.delegate = self
        addFullWidth(header)
        profilePicker.target = self; profilePicker.action = #selector(profileChanged)
        profilePicker.font = .systemFont(ofSize: 12)
        profilePicker.setAccessibilityLabel("Audio profile")
        profilePicker.toolTip = "Choose the routing and equalization profile."
        let statusGroup = NSStackView(views: [statusRow(statusLabel, icon: dspStatusIcon), statusRow(routingStatusLabel, icon: routingStatusIcon), statusRow(guiStatusLabel, icon: guiStatusIcon), outputLabel, dspOutputLabel])
        statusGroup.orientation = .vertical; statusGroup.alignment = .leading; statusGroup.spacing = 5
        for row in statusGroup.arrangedSubviews where row is NSStackView {
            row.widthAnchor.constraint(equalTo: statusGroup.widthAnchor).isActive = true
        }
        outputLabel.widthAnchor.constraint(equalTo: statusGroup.widthAnchor).isActive = true
        dspOutputLabel.widthAnchor.constraint(equalTo: statusGroup.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        routingStatusLabel.lineBreakMode = .byTruncatingTail
        guiStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        guiStatusLabel.textColor = .secondaryLabelColor
        guiStatusLabel.lineBreakMode = .byTruncatingTail
        outputLabel.lineBreakMode = .byTruncatingTail
        outputLabel.font = .systemFont(ofSize: 12)
        outputLabel.textColor = .secondaryLabelColor
        dspOutputLabel.lineBreakMode = .byTruncatingTail
        dspOutputLabel.font = .systemFont(ofSize: 12)
        dspOutputLabel.textColor = .secondaryLabelColor
        for label in [outputLabel, dspOutputLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        statusUpdateLabel.font = .systemFont(ofSize: 12)
        statusUpdateLabel.textColor = .secondaryLabelColor
        statusUpdateLabel.maximumNumberOfLines = 1
        statusUpdateLabel.lineBreakMode = .byTruncatingTail
        statusUpdateLabel.cell?.wraps = false
        statusUpdateLabel.cell?.usesSingleLineMode = true
        statusUpdateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusUpdateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configureButton(statusActionButton, action: #selector(statusActionPressed))
        statusActionSlot.translatesAutoresizingMaskIntoConstraints = false
        statusActionSlot.setContentHuggingPriority(.required, for: .horizontal)
        statusActionButton.translatesAutoresizingMaskIntoConstraints = false
        statusActionSlot.addSubview(statusActionButton)
        NSLayoutConstraint.activate([
            statusActionSlot.widthAnchor.constraint(equalToConstant: AudioControlStyle.compactWidth),
            statusActionSlot.heightAnchor.constraint(equalToConstant: AudioControlStyle.compactControlHeight),
            statusActionButton.leadingAnchor.constraint(equalTo: statusActionSlot.leadingAnchor),
            statusActionButton.centerYAnchor.constraint(equalTo: statusActionSlot.centerYAnchor)
        ])
        statusActionButton.isHidden = true
        let statusUpdateRow = NSStackView(views: [statusUpdateLabel, statusActionSlot])
        statusUpdateRow.orientation = .horizontal; statusUpdateRow.alignment = .centerY; statusUpdateRow.spacing = 8
        statusUpdateRow.distribution = .fill
        statusUpdateRow.heightAnchor.constraint(equalToConstant: AudioControlStyle.compactControlHeight).isActive = true
        statusGroup.setCustomSpacing(0, after: dspOutputLabel)
        statusGroup.addArrangedSubview(statusUpdateRow)
        statusUpdateRow.widthAnchor.constraint(equalTo: statusGroup.widthAnchor).isActive = true
        addFullWidth(statusGroup)
        let separator = NSBox(); separator.boxType = .separator
        AudioControlStyle.configureDisclosure(controlsDisclosure)
        controlsDisclosure.target = self; controlsDisclosure.action = #selector(controlsDisclosurePressed)
        AudioControlStyle.refreshDisclosure(controlsDisclosure, expanded: controlsExpanded)
        controlsBody.orientation = .vertical; controlsBody.alignment = .leading; controlsBody.spacing = 12
        configureControl(dspControl, label: "CamillaDSP mode", action: #selector(dspChanged))
        configureControl(guiControl, label: "CamillaGUI mode", action: #selector(guiChanged))
        guiControl.widthAnchor.constraint(equalToConstant: guiControl.intrinsicContentSize.width).isActive = true
        dspControl.toolTip = "Auto selects a profile when its interface connects. On runs DSP for the selected profile while its interface is connected, then turns Off on disconnect. Off stops DSP."
        guiControl.toolTip = "Auto follows the configured automatic startup policy. On starts the GUI. Off stops it. These choices apply to this session."
        addControlsRow(modeRow("CamillaDSP", dspControl))
        addControlsRow(modeRow("CamillaGUI", guiControl))
        configureControl(fallbackControl, label: "Fallback mode", action: #selector(fallbackModeChanged))
        fallbackControl.toolTip = "Auto restores output automatically. Force selects the chosen device on disconnection and reconnection. Off leaves output selection to macOS on disconnection."
        fallbackControl.isEnabled = false
        let fallbackMode = modeRow("Fallback", fallbackControl)
        fallbackModeRow = fallbackMode
        addControlsRow(fallbackMode)
        fallbackPicker.target = self; fallbackPicker.action = #selector(fallbackOutputChanged)
        fallbackPicker.controlSize = .small
        fallbackPicker.font = .systemFont(ofSize: 12)
        fallbackPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fallbackPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fallbackPicker.setAccessibilityLabel("Fallback and bypass output device")
        // The shared segmented track is inset by half a point on each side.
        // Native popups paint to their frame, so match that visible track.
        fallbackPicker.heightAnchor.constraint(equalToConstant: AudioControlStyle.compactBezelHeight).isActive = true
        (fallbackPicker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        fallbackPicker.addItem(withTitle: "No Outputs Available")
        fallbackPicker.isEnabled = false
        let fallbackOutputLabel = NSTextField(labelWithString: "Fallback/Bypass Output")
        fallbackOutputLabel.font = .systemFont(ofSize: 13)
        let pickerTrack = NSView()
        pickerTrack.translatesAutoresizingMaskIntoConstraints = false
        fallbackPicker.translatesAutoresizingMaskIntoConstraints = false
        pickerTrack.addSubview(fallbackPicker)
        NSLayoutConstraint.activate([
            pickerTrack.heightAnchor.constraint(equalTo: fallbackPicker.heightAnchor),
            fallbackPicker.trailingAnchor.constraint(equalTo: pickerTrack.trailingAnchor, constant: -0.5),
            fallbackPicker.centerYAnchor.constraint(equalTo: pickerTrack.centerYAnchor)
        ])
        let fallbackOutputRow = NSStackView(views: [fallbackOutputLabel, NSView(), pickerTrack])
        fallbackOutputRow.orientation = .horizontal; fallbackOutputRow.alignment = .centerY; fallbackOutputRow.spacing = 8
        self.fallbackOutputRow = fallbackOutputRow
        addControlsRow(fallbackOutputRow)
        configureControl(routingControl, label: "Audio routing", action: #selector(routingChanged))
        for index in 0..<2 { routingControl.setWidth(76, forSegment: index) }
        routingControl.toolTip = "Processed routes audio through DSP. Bypassed sends audio to the fallback output while retaining a healthy DSP service."
        let routingRow = modeRow("Routing", routingControl)
        self.routingRow = routingRow
        addControlsRow(routingRow)
        // Cross-row sizing requires both native controls in their common body.
        NSLayoutConstraint.activate([
            fallbackPicker.widthAnchor.constraint(equalTo: routingControl.widthAnchor, constant: -1),
            pickerTrack.widthAnchor.constraint(equalTo: routingControl.widthAnchor)
        ])
        configureButton(openButton, action: #selector(openPressed), compact: false)
        configureButton(restartButton, action: #selector(restartPressed), compact: false)
        // Match the other action bezels, retaining these actions' natural widths.
        for button in [openButton, restartButton] {
            button.heightAnchor.constraint(equalToConstant: AudioControlStyle.compactControlHeight).isActive = true
        }
        restartButton.toolTip = "Restart DSP and briefly interrupt audio."
        let primaryActions = NSStackView(views: [openButton, restartButton])
        primaryActions.orientation = .horizontal; primaryActions.spacing = 8; primaryActions.distribution = .fillProportionally
        addControlsRow(primaryActions)
        addFullWidth(mainPanel)
        addFullWidth(metersPanel)
        addFullWidth(auxPanel)
        addFullWidth(separator)
        addFullWidth(controlsDisclosure)
        addFullWidth(controlsBody)
        configureButton(moreButton, action: #selector(morePressed))
        moreButton.controlSize = .small
        presetPicker.target = self; presetPicker.action = #selector(presetChanged)
        presetPicker.controlSize = .small
        presetPicker.font = .systemFont(ofSize: 12)
        // Native popups fill their frame; rounded actions inset their bezel.
        // Match the visible height, keeping native menu tracking and text size.
        presetPicker.heightAnchor.constraint(equalToConstant: AudioControlStyle.compactBezelHeight).isActive = true
        presetPicker.setAccessibilityLabel("Equalizer preset")
        presetPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setPresetChoices([], selectedID: nil, enabled: false, reason: "Presets unavailable.")
        presetPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        (presetPicker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        moreButton.setContentHuggingPriority(.required, for: .horizontal)
        moreButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [presetPicker, moreButton])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8; footer.distribution = .fill
        addFullWidth(footer)
    }

    package convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification]
        if let observedWindow {
            for name in names { center.removeObserver(self, name: name, object: observedWindow) }
        }
        observedWindow = window
        if let window {
            for name in names { center.addObserver(self, selector: #selector(windowFocusChanged), name: name, object: window) }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.removeObserver(self, name: name, object: NSApp)
            center.addObserver(self, selector: #selector(windowFocusChanged), name: name, object: NSApp)
        }
        refreshSelectionAppearance()
    }

    package func setPinned(_ pinned: Bool) {
        pinButton.state = pinned ? .on : .off
        pinButton.needsDisplay = true
    }
    func cancelPresetOpening() { presetPicker.cancelOpening() }
    @objc private func pinPressed() { onPin?(pinButton.state == .on) }
    package func menuWillOpen(_ menu: NSMenu) {
        trackedMenus.insert(ObjectIdentifier(menu))
        if menu === fallbackPicker.menu { fallbackMenuTracking = true }
        onChildMenuTracking?(true)
    }
    package func menuDidClose(_ menu: NSMenu) {
        trackedMenus.remove(ObjectIdentifier(menu))
        if menu === fallbackPicker.menu {
            fallbackMenuTracking = false
            if let pending = pendingFallbackState {
                pendingFallbackState = nil
                let previous = fallbackState
                Task { @MainActor [weak self] in
                    guard let self, self.fallbackState == previous else { return }
                    self.renderFallback(profileID: pending.profileID, preference: pending.preference,
                                        devices: pending.devices, enabled: pending.enabled,
                                        automaticOutput: pending.automaticOutput)
                }
            }
        }
        onChildMenuTracking?(false)
        if trackedMenus.isEmpty, let expanded = pendingControlsExpansion {
            pendingControlsExpansion = nil
            Task { @MainActor [weak self] in self?.setControlsExpanded(expanded) }
        }
    }

    @objc private func windowFocusChanged(_ notification: Notification) { refreshSelectionAppearance() }

    package func refreshSelectionAppearance() {
        AudioControlStyle.refreshDisclosure(controlsDisclosure, expanded: controlsExpanded)
        for control in [dspControl, guiControl, fallbackControl, routingControl] { AudioControlStyle.refreshSelectionAppearance(control) }
        refreshGUIStatusAppearance()
        restartButton.refreshAppearance()
        pinButton.needsDisplay = true
        metersPanel.refreshFocusAppearance()
        auxPanel.refreshFocusAppearance()
        func redrawButtons(_ view: NSView) {
            if view is AudioRoundedButton || view is NSSlider { view.needsDisplay = true }
            for child in view.subviews { redrawButtons(child) }
        }
        redrawButtons(mainPanel)
        redrawButtons(auxPanel)
    }

    package func refreshGUIStatusAppearance() {
        let state = actualGUIStatusEmphasis
        emphasize(guiStatusLabel, icon: guiStatusIcon, state: state)
    }

    package func setPresetChoices(_ choices: [(id: String, title: String)], selectedID: String?, enabled: Bool, reason: String?, unavailableIDs: [String: String] = [:], restartingIDs: [String: String] = [:], placeholderTitle: String = "Presets…", allowsRefresh: Bool = false) {
        updatingPresets = true
        defer { updatingPresets = false }
        let next = choices.map { PresetChoice(id: $0.id, title: $0.title) }
        let needsPlaceholder = selectedID == nil || !next.contains { $0.id == selectedID }
        let titles = (needsPlaceholder ? [placeholderTitle] : []) + next.map(\.title)
        if next != presetChoices || presetPicker.itemTitles != titles {
            presetChoices = next
            presetPicker.removeAllItems()
            if needsPlaceholder {
                presetPicker.addItem(withTitle: placeholderTitle)
                // Informational selection has no command identity. Keep its
                // native title readable and allow the popup to open normally.
                presetPicker.lastItem?.isEnabled = enabled && !next.isEmpty
            }
            for choice in next {
                presetPicker.addItem(withTitle: choice.title)
                presetPicker.lastItem?.representedObject = choice.id
            }
        }
        presetPicker.menu?.autoenablesItems = false
        for item in presetPicker.itemArray {
            guard let id = item.representedObject as? String else {
                item.isEnabled = enabled && !next.isEmpty
                continue
            }
            item.isEnabled = unavailableIDs[id] == nil
            item.toolTip = unavailableIDs[id] ?? restartingIDs[id] ?? (item.title + "\n" + id)
            if item.isEnabled, restartingIDs[id] != nil {
                let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Restarts audio")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
                item.image = image
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                    .font: presetPicker.font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange])
                item.setAccessibilityHelp(item.toolTip)
            } else {
                item.image = nil
                item.attributedTitle = nil
                item.setAccessibilityHelp(item.toolTip)
            }
        }
        if let selectedID, let item = presetPicker.itemArray.first(where: { ($0.representedObject as? String) == selectedID }) {
            presetPicker.select(item)
        } else { presetPicker.selectItem(at: 0) }
        presetPicker.isEnabled = enabled && (!next.isEmpty || allowsRefresh)
        presetPicker.toolTip = reason ?? presetPicker.selectedItem?.toolTip ?? presetPicker.selectedItem?.title ?? "Choose an equalizer preset."
        presetPicker.setAccessibilityHelp(presetPicker.toolTip)
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addControlsRow(_ view: NSView) {
        controlsBody.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: controlsBody.widthAnchor).isActive = true
    }

    @objc private func controlsDisclosurePressed() { setControlsExpanded(!controlsExpanded) }

    package func setControlsExpanded(_ expanded: Bool) {
        guard trackedMenus.isEmpty else { pendingControlsExpansion = expanded; return }
        guard expanded != controlsExpanded else { return }
        if !expanded, let responder = window?.firstResponder as? NSView,
           responder === controlsBody || responder.isDescendant(of: controlsBody) {
            window?.makeFirstResponder(controlsDisclosure)
        }
        controlsExpanded = expanded
        controlsBody.isHidden = !expanded
        AudioControlStyle.refreshDisclosure(controlsDisclosure, expanded: expanded)
        onLayout?()
    }

    private func fallbackSegment(_ mode: FallbackOutputMode) -> Int {
        switch mode { case .automatic: return 0; case .manual: return 1; case .off: return 2 }
    }

    private func configureDSPModeControl(companionMode: Bool) {
        guard companionDSPControls != companionMode || dspControl.segmentCount != (companionMode ? 2 : 3) else { return }
        companionDSPControls = companionMode
        dspControl.segmentCount = companionMode ? 2 : 3
        let labels = companionMode ? ["On", "Off"] : ["Auto", "On", "Off"]
        for (index, label) in labels.enumerated() {
            dspControl.setLabel(label, forSegment: index)
            dspControl.setWidth(companionMode ? 76.5 : 51, forSegment: index)
        }
        dspControl.toolTip = companionMode
            ? "Companion Mode controls the selected CamillaDSP profile only. On starts or resumes it when available; Off stops it. macOS output selection is left unchanged."
            : "Auto selects a profile when its interface connects. On runs DSP for the selected profile while its interface is connected, then turns Off on disconnect. Off stops DSP."
        dspControl.setAccessibilityHelp(dspControl.toolTip)
    }

    private func configureGUIModeControl(installation: GUIInstallationState) {
        let label = installation.unavailableLabel
        let count = label == nil ? 3 : 1
        guard renderedGUIInstallation != installation || guiControl.segmentCount != count else { return }
        renderedGUIInstallation = installation
        // Availability changes the contents, never the shared control track's width.
        guiControl.segmentCount = count
        let labels: [String] = label.map { [$0] } ?? ["Auto", "On", "Off"]
        for index in labels.indices {
            guiControl.setLabel(labels[index], forSegment: index)
            guiControl.setWidth(count == 1 ? 153 : 51, forSegment: index)
            guiControl.setEnabled(label == nil, forSegment: index)
        }
        guiControl.selectedSegment = -1
        AudioControlStyle.setOffSelected(guiControl, selected: false)
        guiControl.toolTip = label.map { "CamillaGUI: " + $0 }
            ?? "Auto follows the configured automatic startup policy. On starts the GUI. Off stops it. These choices apply to this session."
        guiControl.setAccessibilityHelp(guiControl.toolTip)
    }

    private func configureControl(_ control: NSSegmentedControl, label: String, action: Selector) {
        control.target = self; control.action = action
        AudioControlStyle.configureSegments(control)
        control.font = .systemFont(ofSize: 12)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setAccessibilityLabel(label)
        for index in 0..<control.segmentCount { control.setWidth(51, forSegment: index) }
    }

    private func configureButton(_ button: NSButton, action: Selector, compact: Bool = true) {
        button.target = self; button.action = action
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        button.setAccessibilityLabel(button.title)
        if compact, let rounded = button as? AudioRoundedButton { AudioControlStyle.configureCompact(rounded) }
    }

    private func statusRow(_ label: NSTextField, icon: NSImageView) -> NSStackView {
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 5
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func emphasisIndex(_ state: MenuStatusEmphasis) -> Int {
        switch state { case .neutral: return 0; case .active: return 1; case .bypassed: return 2; case .transition: return 3; case .error: return 4; case .off: return 5; case .direct: return 6; case .waiting: return 7 }
    }

    package func emphasize(_ label: NSTextField, icon: NSImageView, state: MenuStatusEmphasis, symbolOverride: String? = nil, weightOverride: NSFont.Weight? = nil) {
        let identity = ObjectIdentifier(label)
        let index = emphasisIndex(state)
        let key = "\(index):\(symbolOverride ?? ""):\(weightOverride?.rawValue ?? -1)"
        guard emphasisStates[identity] != key else { return }
        emphasisStates[identity] = key
        let color: NSColor
        let symbol: String
        let weight: NSFont.Weight
        switch state {
        case .active: color = .systemGreen; symbol = "checkmark.circle.fill"; weight = .bold
        case .bypassed: color = .systemOrange; symbol = "arrow.triangle.branch"; weight = .bold
        case .transition: color = .systemOrange; symbol = "clock"; weight = .medium
        case .error: color = .systemRed; symbol = "exclamationmark.circle.fill"; weight = .bold
        case .off: color = .systemRed; symbol = "xmark.circle.fill"; weight = .bold
        case .direct: color = .systemYellow; symbol = "arrow.triangle.branch"; weight = .bold
        case .waiting: color = .systemYellow; symbol = "circle"; weight = .medium
        case .neutral: color = .secondaryLabelColor; symbol = "circle"; weight = .medium
        }
        label.font = .systemFont(ofSize: 12, weight: weightOverride ?? weight)
        label.textColor = color
        icon.image = NSImage(systemSymbolName: symbolOverride ?? symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
    }

    private func modeRow(_ title: String, _ control: NSSegmentedControl) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        return row
    }

    @discardableResult package func render(_ model: MenuBarPresentation?, error: String?) -> Bool {
        let dspIndex: Int
        let guiIndex: Int
        switch model?.mode {
        case .automatic: dspIndex = 0
        case .forceOn: dspIndex = model?.companionMode == true ? 0 : 1
        case .forceOff: dspIndex = model?.companionMode == true ? 1 : 2
        case nil: dspIndex = -1
        }
        switch model?.guiPolicy { case .automatic: guiIndex = 0; case .manualOn: guiIndex = 1; case .manualOff: guiIndex = 2; case nil: guiIndex = -1 }
        let routeIndex: Int
        switch model?.routingControlSelection { case .processed: routeIndex = 0; case .direct: routeIndex = 1; case .pending, .unknown, nil: routeIndex = -1 }
        let update = model?.panelStatus(surfacedError: error)
        let state = RenderState(texts: [model?.title, model?.selectedProfileID, model?.dspStatusText, model?.routingStatusText, model?.guiStatusText, model?.systemOutputLine, model?.dspOutputLine, model?.panelContext,
                                       model.flatMap { $0.panelRoutingReason }, model?.routingProcessed.reason, model?.routingDirect.reason,
                                       model?.guiInstallationState.rawValue, model?.guiControls.reason, model?.openWeb.reason, model?.restartDSP.reason,
                                       model?.resumeDSP.reason, model?.retryDSP.reason, model?.retryGUI.reason,
                                       model?.contextualDSPAction?.rawValue, model?.contextualGUIAction?.rawValue, error, update?.text, update?.detail]
                                      + (model?.profiles.flatMap { [Optional($0.id), Optional($0.name)] } ?? []),
                                flags: [model != nil, model?.companionMode == true, model?.dspOn.enabled == true, model?.guiControls.enabled == true,
                                        model?.openWeb.enabled == true, model?.restartDSP.enabled == true,
                                        model?.resumeDSP.enabled == true, model?.retryDSP.enabled == true, model?.retryGUI.enabled == true,
                                        model?.routingProcessed.enabled == true, model?.routingDirect.enabled == true],
                                selections: [dspIndex, guiIndex, routeIndex, model.map { emphasisIndex($0.dspStatusEmphasis) } ?? -1, model.map { emphasisIndex($0.routingStatusEmphasis) } ?? -1, model.map { emphasisIndex($0.guiStatusEmphasis) } ?? -1])
        guard state != renderedState else { return false }
        renderedState = state
        // Status text, actions and failure detail occupy permanent fixed bounds.
        let geometry: [String?] = [String(model?.profiles.count ?? 0), String(model?.companionMode ?? false)]
        let geometryChanged = geometry != geometryState
        geometryState = geometry
        guard let model else {
            configureDSPModeControl(companionMode: false)
            configureGUIModeControl(installation: .configured)
            profilePicker.isHidden = true
            statusUpdateLabel.stringValue = "Status: Starting"
            statusUpdateLabel.textColor = .secondaryLabelColor
            statusUpdateLabel.toolTip = nil
            statusUpdateLabel.setAccessibilityLabel(statusUpdateLabel.stringValue)
            statusUpdateLabel.setAccessibilityHelp(nil)
            statusActions = []; statusActionButton.isHidden = true
            routingControl.isEnabled = false
            dspControl.isEnabled = false; guiControl.isEnabled = false
            openButton.isEnabled = false; restartButton.isEnabled = false
            return geometryChanged
        }
        titleLabel.stringValue = model.profiles.count == 1 ? ApplicationMetadata.name : model.title
        let hideSystemRouting = model.companionMode
        configureDSPModeControl(companionMode: hideSystemRouting)
        if hideSystemRouting, let responder = window?.firstResponder as? NSView,
           [fallbackModeRow, fallbackOutputRow, routingRow].compactMap({ $0 }).contains(where: {
               responder === $0 || responder.isDescendant(of: $0)
           }) {
            window?.makeFirstResponder(dspControl)
        }
        fallbackModeRow?.isHidden = hideSystemRouting
        fallbackOutputRow?.isHidden = hideSystemRouting
        routingRow?.isHidden = hideSystemRouting
        profilePicker.isHidden = model.profiles.count < 2
        titleLabel.isHidden = model.profiles.count > 1
        let needsSelection = model.selectedProfileID == nil && model.profiles.count > 1
        let ids: [String?] = (needsSelection ? [nil] : []) + model.profiles.map { Optional($0.id) }
        let names = (needsSelection ? ["Choose a profile…"] : []) + model.profiles.map(\.name)
        if ids != profileIDs || profilePicker.itemTitles != names {
            profileIDs = ids
            profilePicker.removeAllItems()
            profilePicker.addItems(withTitles: names)
            if needsSelection { profilePicker.item(at: 0)?.isEnabled = false }
        }
        if let index = profileIDs.firstIndex(of: model.selectedProfileID) { profilePicker.selectItem(at: index) }
        statusLabel.stringValue = model.dspStatusText
        routingStatusLabel.stringValue = model.routingStatusText
        guiStatusLabel.stringValue = model.guiStatusText
        actualGUIStatusEmphasis = model.guiStatusEmphasis
        guiStatusLabel.setAccessibilityLabel(model.guiStatusText)
        emphasize(statusLabel, icon: dspStatusIcon, state: model.dspStatusEmphasis)
        emphasize(routingStatusLabel, icon: routingStatusIcon, state: model.routingStatusEmphasis)
        refreshGUIStatusAppearance()
        observedRoutingSegment = routeIndex
        routingActionAvailability = [model.routingProcessed.enabled, model.routingDirect.enabled]
        routingControl.selectedSegment = routeIndex
        AudioControlStyle.setDirectSelected(routingControl, selected: routeIndex == 1)
        routingControl.isEnabled = !hideSystemRouting
        routingControl.setEnabled(routeIndex == 0 || model.routingProcessed.enabled, forSegment: 0)
        routingControl.setEnabled(routeIndex == 1 || model.routingDirect.enabled, forSegment: 1)
        routingControl.setToolTip(model.routingProcessedHelp, forSegment: 0)
        routingControl.setAccessibilityValue(model.routingStatusText)
        routingControl.setAccessibilityHelp(model.routingProcessedHelp)
        routingControl.setToolTip(routeIndex == 1 ? "Output currently bypasses DSP." : (model.routingDirect.reason ?? "Bypass DSP using the fallback output while retaining a healthy service."), forSegment: 1)
        outputLabel.stringValue = model.systemOutputLine
        dspOutputLabel.stringValue = model.dspOutputLine
        for label in [outputLabel, dspOutputLabel] {
            label.toolTip = label.stringValue
            label.setAccessibilityLabel(label.stringValue)
        }
        dspControl.selectedSegment = dspIndex
        AudioControlStyle.setOffSelected(dspControl, selected: dspIndex == (hideSystemRouting ? 1 : 2),
                                         segment: hideSystemRouting ? 1 : 2)
        dspControl.isEnabled = true
        for index in 0..<dspControl.segmentCount { dspControl.setEnabled(true, forSegment: index) }
        dspControl.setEnabled(model.dspOn.enabled, forSegment: hideSystemRouting ? 0 : 1)
        configureGUIModeControl(installation: model.guiInstallationState)
        guiControl.selectedSegment = model.guiInstallationState == .configured ? guiIndex : -1
        AudioControlStyle.setOffSelected(guiControl, selected: model.guiInstallationState == .configured && guiIndex == 2)
        guiControl.isEnabled = model.guiControls.enabled
        guiControl.setAccessibilityHelp(model.guiControls.reason ?? guiControl.toolTip)
        openButton.isEnabled = model.openWeb.enabled
        openButton.toolTip = model.openWeb.reason ?? "Open the ready web interface in your default browser."
        restartButton.isEnabled = model.restartDSP.enabled
        restartButton.toolTip = model.restartDSP.reason ?? "Restart DSP and briefly interrupt audio."
        if let update {
            statusUpdateLabel.stringValue = "Status: " + update.text
            switch update.emphasis {
            case .error, .off: statusUpdateLabel.textColor = .systemRed
            case .transition, .bypassed: statusUpdateLabel.textColor = .systemOrange
            case .direct, .waiting: statusUpdateLabel.textColor = .systemYellow
            case .active, .neutral: statusUpdateLabel.textColor = .secondaryLabelColor
            }
            statusUpdateLabel.toolTip = update.detail
            statusUpdateLabel.setAccessibilityLabel(statusUpdateLabel.stringValue)
            statusUpdateLabel.setAccessibilityHelp(update.detail)
            statusActions = update.actions
            statusActionButton.isHidden = statusActions.isEmpty
            statusActionButton.title = statusActions.count == 1 ? statusActions[0].title : "Actions"
            statusActionButton.setAccessibilityLabel(statusActionButton.title)
            statusActionButton.toolTip = statusActions.map(\.title).joined(separator: ", ")
        }
        if geometryChanged { needsLayout = true }
        return geometryChanged
    }


    package func renderFallback(profileID: String?, preference: FallbackOutputPreference, devices: [AudioDevice], enabled: Bool,
                        automaticOutput: AudioDevice? = nil) {
        let state = FallbackRenderState(profileID: profileID, preference: preference, devices: devices,
                                        enabled: enabled, automaticOutput: automaticOutput)
        guard !fallbackMenuTracking else { pendingFallbackState = state; return }
        guard state != fallbackState else { return }
        fallbackState = state
        fallbackDevices = devices
        fallbackControl.selectedSegment = fallbackSegment(preference.mode)
        fallbackControl.isEnabled = enabled && profileID != nil
        if preference.mode == .manual {
            AudioControlStyle.setDirectSelected(fallbackControl, selected: true)
        } else {
            AudioControlStyle.setOffSelected(fallbackControl, selected: preference.mode == .off,
                                             segment: 2, retainInactiveColor: true)
        }
        let usesSavedDevice = preference.mode != .automatic && preference.outputSelection == .device
            && preference.outputUID != nil
        let suggestedUID = automaticOutput.flatMap { suggestion in
            devices.contains { $0.uid == suggestion.uid } ? suggestion.uid : nil
        }
        let selectedUID = usesSavedDevice ? preference.outputUID : suggestedUID
        let unavailable = usesSavedDevice && selectedUID != nil
            && !devices.contains { $0.uid == selectedUID }
        var titles = devices.map(\.name)
        var uids: [String?] = devices.map { Optional($0.uid) }
        if unavailable {
            titles.append((preference.outputName ?? "Saved Output") + " (Unavailable)")
            uids.append(selectedUID)
        } else if selectedUID == nil || titles.isEmpty {
            titles.insert(devices.isEmpty ? "No Outputs Available" : "Choose Output", at: 0)
            uids.insert(nil, at: 0)
        }
        let currentUIDs = fallbackPicker.itemArray.map { $0.representedObject as? String }
        if fallbackPicker.itemTitles != titles || currentUIDs != uids {
            fallbackPicker.removeAllItems()
            for (title, uid) in zip(titles, uids) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = uid
                fallbackPicker.menu?.addItem(item)
            }
        }
        fallbackPicker.menu?.autoenablesItems = false
        for item in fallbackPicker.itemArray {
            let uid = item.representedObject as? String
            item.isEnabled = uid != nil && devices.contains { $0.uid == uid }
            item.toolTip = item.title
            item.setAccessibilityHelp(item.isEnabled ? item.title : "Select an available output device.")
        }
        if let selected = uids.firstIndex(of: selectedUID) { fallbackPicker.selectItem(at: selected) }
        fallbackPicker.isEnabled = enabled && profileID != nil && preference.mode != .automatic && !devices.isEmpty
        fallbackPicker.toolTip = preference.mode == .automatic
            ? "Automatically chosen output. Select Force or Off to choose a device."
            : (unavailable ? "Saved output is unavailable. Choose an available device."
                          : "Used by Bypassed routing and by Force after disconnection or reconnection.")
        fallbackPicker.setAccessibilityHelp(fallbackPicker.toolTip)
    }

    /// Resolve hidden stack members and wrapped text at the document width before
    /// reading its natural height. A second pass resolves constraints changed by
    /// the first layout, independently of the previous popover height.
    package func measureNaturalSize() -> NSSize {
        let initialSize = NSSize(width: 388, height: max(220, frame.height))
        if frame.size != initialSize { setFrameSize(initialSize) }
        for _ in 0..<2 {
            needsLayout = true
            stack.needsLayout = true
            layoutSubtreeIfNeeded()
            let height = ceil(stack.fittingSize.height + 32)
            let size = NSSize(width: 388, height: max(220, height))
            if frame.size != size { setFrameSize(size) }
        }
        layoutSubtreeIfNeeded()
        return NSSize(width: 388, height: max(220, ceil(stack.fittingSize.height + 32)))
    }

    func restoreObservedRoutingSelection(_ model: MenuBarPresentation) {
        switch model.routingControlSelection {
        case .processed: routingControl.selectedSegment = 0
        case .direct: routingControl.selectedSegment = 1
        case .pending, .unknown: routingControl.selectedSegment = -1
        }
    }

    package override func cancelOperation(_ sender: Any?) { onClose?() }

    @objc private func profileChanged() {
        let index = profilePicker.indexOfSelectedItem
        if profileIDs.indices.contains(index), let id = profileIDs[index] { onProfile?(id) }
    }
    @objc private func dspChanged() { if dspControl.selectedSegment >= 0 { onDSPMode?(dspControl.selectedSegment) } }
    @objc private func routingChanged() {
        let requested = routingControl.selectedSegment
        routingControl.selectedSegment = observedRoutingSegment
        guard requested != observedRoutingSegment, routingActionAvailability.indices.contains(requested),
              routingActionAvailability[requested] else { return }
        onRouting?(requested)
    }
    @objc package func fallbackModeChanged() {
        guard fallbackControl.isEnabled, let state = fallbackState, let profileID = state.profileID else { return }
        let requested: FallbackOutputMode
        switch fallbackControl.selectedSegment {
        case 0: requested = .automatic
        case 1: requested = .manual
        case 2: requested = .off
        default: return
        }
        fallbackControl.selectedSegment = fallbackSegment(state.preference.mode)
        guard requested != state.preference.mode else { return }
        onFallbackMode?(profileID, requested)
    }
    @objc package func fallbackOutputChanged() {
        guard fallbackPicker.isEnabled, let item = fallbackPicker.selectedItem, item.isEnabled,
              let state = fallbackState, state.preference.mode != .automatic, let profileID = state.profileID,
              let uid = item.representedObject as? String,
              let device = fallbackDevices.first(where: { $0.uid == uid }) else { return }
        // A same-profile switch to Auto can arrive while the native menu still
        // displays Force or Off. Do not permit a stale menu to mutate Auto's choice.
        if let pending = pendingFallbackState, pending.profileID == profileID,
           pending.preference.mode == .automatic { return }
        guard state.preference.outputSelection != .device || uid != state.preference.outputUID else { return }
        let displayedUID = state.preference.outputSelection == .device && state.preference.outputUID != nil
            ? state.preference.outputUID : state.automaticOutput?.uid
        // Display only the persisted or observational choice until saving succeeds.
        if let saved = fallbackPicker.itemArray.first(where: {
            ($0.representedObject as? String) == displayedUID
        }) { fallbackPicker.select(saved) }
        onFallbackOutput?(profileID, device)
    }
    @objc private func guiChanged() {
        guard renderedGUIInstallation == .configured, guiControl.isEnabled, guiControl.segmentCount == 3,
              guiControl.selectedSegment >= 0 else { return }
        onGUIMode?(guiControl.selectedSegment)
    }
    @objc private func openPressed() { onOpen?() }
    @objc private func restartPressed() { onRestart?() }
    @objc package func statusActionPressed() {
        if statusActions.count == 1 { performStatusAction(statusActions[0]); return }
        guard !statusActions.isEmpty else { return }
        let menu = makeStatusActionsMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: statusActionButton.bounds.maxY), in: statusActionButton)
    }
    package func makeStatusActionsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        for action in statusActions {
            let item = NSMenuItem(title: action.title, action: #selector(statusMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action
            menu.addItem(item)
        }
        return menu
    }
    @objc package func statusMenuAction(_ item: NSMenuItem) {
        guard let action = item.representedObject as? MenuPanelStatusAction else { return }
        performStatusAction(action)
    }
    private func performStatusAction(_ action: MenuPanelStatusAction) {
        // Pushed state may change while the native menu is tracking.
        guard statusActions.contains(action) else { return }
        switch action {
        case .resumeDSP, .retryDSP: onDSPContext?()
        case .retryGUI: onGUIContext?()
        case .dismiss: onDismissError?()
        }
    }
    @objc private func morePressed() { onMore?(moreButton) }
    @objc private func presetChanged() {
        guard !updatingPresets, presetPicker.isEnabled, presetPicker.selectedItem?.isEnabled == true,
              let id = presetPicker.selectedItem?.representedObject as? String else { return }
        onPreset?(id)
    }


}

/// The document keeps its natural height; the viewport alone is capped to the screen.
package struct PanelViewportLayout {
    package let documentSize: NSSize
    package let viewportSize: NSSize
    package var requiresScrolling: Bool { documentSize.height > viewportSize.height }
    package init(naturalSize: NSSize, screenHeight: CGFloat) {
        let height = max(220, ceil(naturalSize.height))
        let available = max(220, floor(screenHeight - 80))
        documentSize = NSSize(width: 388, height: height)
        viewportSize = NSSize(width: 388, height: min(height, available))
    }
}
