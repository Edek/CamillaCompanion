import AppKit
import AutoAudioCore

/// Preserve the controller command contract independently of UI state.
public enum MenuBarCommandRequest {
    public static func make(command: ControllerCommand, profileID: String?) -> ControllerRequest {
        switch command {
        case .auto, .on, .off, .reconnect, .preset, .presets: return .init(command: command, profileID: profileID)
        case .status, .profiles, .show, .retry, .release, .resume: return .init(command: command)
        }
    }
}

/// A persistent native panel driven solely by controller snapshots.
@MainActor public final class MenuBarController: NSObject, NSPopoverDelegate {
    package let item: NSStatusItem
    package let popover = NSPopover()
    package let panel = AudioControlPanel()
    private let command: (ControllerRequest) async -> ControllerReply
    package var presetSnapshot: PresetSnapshot? { presetRequests.snapshot }
    package var presetRequestInFlight: Bool { presetRequests.inFlight }
    package var presetRequestTask: Task<Void, Never>? { presetRequests.task }
    package var presetRefreshPending: Bool { presetRequests.refreshPending }
    private lazy var presetRequests = PresetRequestCoordinator(
        context: { [weak self] in
            .init(profileID: self?.presentation?.selectedProfileID,
                  folderConfigured: self?.uiPreferences.presetsFolderPath != nil,
                  commandAvailable: self?.presentation?.refreshAux.enabled == true,
                  panelVisible: self?.panelVisible == true, panelClosing: self?.panelClosing != false,
                  applicationHidden: self?.applicationHidden != false,
                  targetReady: self?.levelsReady == true, targetProfileID: self?.levelsProfile?.id)
        }, beginFeedback: { [weak self] in
            guard let self else { return nil }
            self.commandRequestGeneration += 1
            self.commandError = nil
            return self.commandRequestGeneration
        }, reportFeedback: { [weak self] generation, error in
            guard let self, generation == self.commandRequestGeneration, let error else { return }
            self.commandError = error
        }, onChange: { [weak self] in self?.refresh() }, perform: { [weak self] request, completion in
            guard let self else { return }
            let reply = await self.command(request)
            withExtendedLifetime(self) { completion(reply) }
        })
    private let guiCommand: (GUIRequest) async -> GUIReply
    private let quit: () -> Void
    private let openURL: (URL) -> Bool
    package let liveLevels = SignalLevelsController(transport: CamillaSignalLevelsTransport())
    private var levelsProfile: Profile?
    private var levelsReady = false
    package var panelVisible = false
    package var panelClosing = false
    package private(set) var pinned = false
    private var childTrackingDepth = 0
    package var applicationHidden = false
    private var presentation: MenuBarPresentation?
    package private(set) var auxSnapshot: AuxFaderSnapshot?
    private var auxRefresh: (() async throws -> Void)?
    private var auxVolume: ((Int, Double, AuxVolumeIntent) async throws -> Void)?
    private var auxMute: ((Int, Bool, AuxVolumeIntent) async throws -> Void)?
    private var preparePreciseVolume: ((Int, Double) async throws -> AuxVolumeProposal)?
    private var applyPreciseVolume: ((AuxVolumeProposal, AuxVolumeIntent) async throws -> AuxVolumeProposal?)?
    private var preciseAlert: NSAlert?
    private var auxPreferences: ((AuxPreferences) async throws -> Void)?
    private var auxGeneration = 0
    package var auxError: String?
    package private(set) var auxRefreshError: String?
    private var auxRefreshInFlightGeneration: Int?
    private let scrollView = NSScrollView()
    private var guiRequestGeneration = 0
    package private(set) var commandError: String?
    private var commandRequestGeneration = 0
    private var dismissedErrors: Set<String> = []
    private var renderedAux: AuxFaderSnapshot?
    private var hasRenderedAux = false
    private var measuredScreenHeight: CGFloat?
    private var aboutAfterMenu = false
    private var settingsAfterMenu = false
    package var settingsWindow: NativeSettingsWindow?
    private var interfaceProfilesHandlers: InterfaceProfilesHandlers?

    public func updateInterfaceDevices(snapshot: AudioSnapshot?) {
        settingsWindow?.updateInterfaceDevices(snapshot?.devices ?? [])
    }

    public func setInterfaceProfilesHandlers(_ handlers: InterfaceProfilesHandlers) {
        interfaceProfilesHandlers = handlers
    }
    private var loginItemManager: LoginItemManager?
    private var setupHandler: (() -> Void)?
    private var settingsDirectoryURL: URL?
    private var panelOpeningTask: Task<Void, Never>?
    private var panelOpeningGeneration = 0
    private var reopenAfterClosing = false

    public func setSettingsDirectory(_ url: URL) { settingsDirectoryURL = url }

    public func setSetupAndStartup(loginItemManager: LoginItemManager, setup: @escaping () -> Void) {
        self.loginItemManager = loginItemManager
        self.setupHandler = setup
    }
    private var uiPreferences = UIPreferences()
    private var uiPreferencesError: String?
    private var saveUIPreferences: ((UIPreferences) throws -> Void)?
    private var fallbackProfileID: String?
    private var fallbackPreference = FallbackOutputPreference()
    private var fallbackDevices: [AudioDevice] = []
    private var fallbackError: String?
    private var saveFallbackPreference: ((String, FallbackOutputPreference) throws -> Void)?
    private var fallbackAutomaticOutput: AudioDevice?
    private var aboutWindow: AboutDiagnosticsWindow?
    private var diagnosticsProvider: (() -> String)?
    private var dspVersionProvider: () -> String = { "Unavailable" }
    private var statusAccessibilityLabel: String?
    package private(set) var iconDimmed: Bool?
    private let waveformIcon = MenuBarController.makeWaveformIcon(opacity: 1)
    private let dimmedWaveformIcon = MenuBarController.makeWaveformIcon(opacity: 0.5)

    private static func makeWaveformIcon(opacity: CGFloat) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil),
              symbol.size.width > 0, symbol.size.height > 0 else { return nil }
        // Native symbols have alignment metrics that plain dimmed images lack.
        // Bake both variants into the same canvas, without symbol-specific sizing.
        let scale = min(16 / symbol.size.width, 16 / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let drawingRect = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                     width: size.width, height: size.height)
            symbol.draw(in: drawingRect, from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = ApplicationMetadata.name
        return image
    }

    public init(command: @escaping (ControllerRequest) async -> ControllerReply,
                guiCommand: @escaping (GUIRequest) async -> GUIReply,
                quit: @escaping () -> Void,
                openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        // Bright symbols and their dimmed raster must share an invariant anchor.
        // Automatic sizing can shift the icon and its attached popover on bypass.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.command = command; self.guiCommand = guiCommand; self.quit = quit; self.openURL = openURL
        super.init()
        item.button?.image = waveformIcon
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel(ApplicationMetadata.name + ", starting")
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = NSViewController()
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = panel
        controller.view = scrollView
        popover.contentViewController = controller
        panel.onClose = { [weak self] in self?.dismissPanel() }
        panel.onPin = { [weak self] pinned in self?.setPinned(pinned) }
        panel.onLayout = { [weak self] in self?.refresh(forceLayout: true) }
        panel.onChildMenuTracking = { [weak self] tracking in self?.setChildMenuTracking(tracking) }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillHide), name: NSApplication.willHideNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidUnhide), name: NSApplication.didUnhideNotification, object: NSApp)
        panel.onDSPMode = { [weak self] index in self?.chooseDSPMode(index) }
        panel.onGUIMode = { [weak self] index in self?.chooseGUIMode(index) }
        panel.onFallbackMode = { [weak self] profileID, mode in
            guard let self, profileID == self.fallbackProfileID,
                  profileID == self.presentation?.selectedProfileID else { return }
            var preference = self.fallbackPreference
            if mode == .manual,
               preference.outputSelection == .automatic || preference.outputUID == nil {
                guard let device = self.fallbackAutomaticOutput else {
                    self.commandError = "Choose an output before enabling Force fallback."
                    self.refresh()
                    return
                }
                preference.outputSelection = .device
                preference.outputUID = device.uid; preference.outputName = device.name
            }
            preference.mode = mode
            self.changeFallbackPreference(preference)
        }
        panel.onFallbackOutput = { [weak self] profileID, device in
            guard let self, profileID == self.fallbackProfileID,
                  profileID == self.presentation?.selectedProfileID,
                  self.fallbackPreference.mode != .automatic else { return }
            var preference = self.fallbackPreference
            preference.outputSelection = .device
            preference.outputUID = device.uid; preference.outputName = device.name
            self.changeFallbackPreference(preference)
        }
        panel.onRouting = { [weak self] index in
            guard let self, let model = self.presentation else { return }
            self.panel.restoreObservedRoutingSelection(model)
            let availability = index == 0 ? model.routingProcessed : model.routingDirect
            guard availability.enabled else { self.refresh(); return }
            self.send(index == 0 ? .resume : .release)
        }
        panel.onProfile = { [weak self] id in self?.chooseProfile(id) }
        panel.onOpen = { [weak self] in self?.openInterface() }
        panel.onRestart = { [weak self] in self?.send(.reconnect) }
        panel.onDSPContext = { [weak self] in
            guard let self, let action = self.presentation?.contextualDSPAction else { return }
            self.send(action)
        }
        panel.onGUIContext = { [weak self] in self?.sendGUI(.retry) }
        panel.onDismissError = { [weak self] in
            guard let self else { return }
            self.commandError = nil
            self.auxError = nil
            self.auxRefreshError = nil
            if let error = self.auxSnapshot?.error { self.dismissedErrors.insert(error) }
            if let error = self.presentation?.dspError { self.dismissedErrors.insert(error) }
            if let error = self.presentation?.routingError { self.dismissedErrors.insert(error) }
            if let error = self.presentation?.guiError { self.dismissedErrors.insert(error) }
            self.refresh()
        }
        for faders in [panel.mainPanel, panel.auxPanel] {
        faders.onLayout = { [weak self] in self?.refresh(forceLayout: true) }
        faders.onExpand = { [weak self] in self?.requestAuxRefresh() }
        faders.onVolume = { [weak self] id, db, profile, intent in self?.writeAux(id: id, db: db, muted: nil, profile: profile, intent: intent) }
        faders.onMute = { [weak self] id, muted, profile, intent in self?.writeAux(id: id, db: nil, muted: muted, profile: profile, intent: intent) }
        faders.onPreciseVolume = { [weak self] id, db, profile in self?.enterPreciseVolume(id: id, db: db, profile: profile) }
        }
        liveLevels.onChange = { [weak self] value in
            self?.renderMeterSnapshot(value)
        }
        panel.metersPanel.onNumericModeChange = { [weak self] mode in self?.changeMeterNumericMode(mode) }
        panel.metersPanel.onToggle = { [weak self] enabled in self?.toggleLiveLevels(enabled) }
        panel.metersPanel.onRetry = { [weak self] in self?.liveLevels.retry() }
        panel.metersPanel.render(liveLevels.snapshot)
        panel.onMore = { [weak self] button in self?.showMore(button) }
        panel.onPreset = { [weak self] path in self?.requestPresetChange(path) }
        panel.onPreparePresetMenu = { [weak self] in
            guard let self else { return false }
            return await self.presetRequests.prepareMenu()
        }
        refresh()
    }

    public func update(_ presentation: MenuBarPresentation) {
        if self.presentation?.selectedProfileID != presentation.selectedProfileID {
            presetRequests.invalidate()
        }
        if self.presentation?.selectedProfileID != presentation.selectedProfileID {
            cancelPreciseConfirmation()
            guiRequestGeneration += 1
            auxGeneration += 1
            auxSnapshot = nil
            auxError = nil
            auxRefreshError = nil
            commandError = nil
            commandRequestGeneration += 1
            panel.cancelPresetOpening()
        }
        self.presentation = presentation
        settingsWindow?.updateProfile(id: presentation.selectedProfileID, name: presentation.selectedProfile?.name)
        let verifiedActiveID: String?
        if case .active(let id) = presentation.state { verifiedActiveID = id } else { verifiedActiveID = nil }
        settingsWindow?.updateInterfaceRuntime(activeID: verifiedActiveID, selectedID: presentation.selectedProfileID)
        settingsWindow?.updateAuxSnapshot(auxSnapshot)
        updateMainSliderRange()
        if iconDimmed != presentation.statusIconDimmed {
            iconDimmed = presentation.statusIconDimmed
            item.button?.image = presentation.statusIconDimmed ? dimmedWaveformIcon : waveformIcon
        }
        let liveErrors = Set([presentation.dspError, presentation.routingError, presentation.guiError, auxSnapshot?.error].compactMap { $0 })
        dismissedErrors.formIntersection(liveErrors)
        let accessibilityLabel = "\(ApplicationMetadata.name), \(presentation.statusLine), \(presentation.routingStatusText), \(presentation.systemOutputLine), \(presentation.dspOutputLine)"
        if accessibilityLabel != statusAccessibilityLabel {
            statusAccessibilityLabel = accessibilityLabel
            item.button?.setAccessibilityLabel(accessibilityLabel)
        }
        refresh()
    }

    public var isShown: Bool { popover.isShown }

    public func setFallbackHandler(_ save: @escaping (String, FallbackOutputPreference) throws -> Void) {
        saveFallbackPreference = save
    }

    public func reportOutputTargetError(_ message: String) {
        commandRequestGeneration += 1
        commandError = message
        refresh()
    }

    public func updateFallback(profileID: String?, preference: FallbackOutputPreference,
                               devices: [AudioDevice], automaticOutput: AudioDevice? = nil, error: String? = nil) {
        fallbackProfileID = profileID; fallbackPreference = preference
        fallbackDevices = devices; fallbackError = error
        fallbackAutomaticOutput = automaticOutput
        panel.renderFallback(profileID: profileID, preference: preference, devices: devices,
                             enabled: profileID != nil && saveFallbackPreference != nil && error == nil,
                             automaticOutput: automaticOutput)
        refresh()
    }

    private func changeFallbackPreference(_ preference: FallbackOutputPreference) {
        guard let profileID = fallbackProfileID, profileID == presentation?.selectedProfileID,
              fallbackError == nil, let save = saveFallbackPreference else { return }
        do {
            try save(profileID, preference)
            fallbackPreference = preference
        } catch { commandError = "Could not save fallback output: " + error.localizedDescription }
        panel.renderFallback(profileID: fallbackProfileID, preference: fallbackPreference,
                             devices: fallbackDevices, enabled: fallbackError == nil,
                             automaticOutput: fallbackAutomaticOutput)
        refresh()
    }

    public func show() { show(refreshLevels: true) }

    private func show(refreshLevels: Bool) {
        if NSApp.isHidden { NSApp.unhide(nil) }
        applicationHidden = false
        if panelClosing { reopenAfterClosing = true; return }
        if popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            updateMeterReader()
            return
        }
        guard panelOpeningTask == nil else { return }
        // A hidden status item needs one run-loop turn to regain its menu-bar
        // anchor. Keep the same popover and expose the icon only while open.
        item.isVisible = true
        panelClosing = false
        panelOpeningGeneration += 1
        let generation = panelOpeningGeneration
        panelOpeningTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer {
                if generation == self.panelOpeningGeneration { self.panelOpeningTask = nil }
            }
            for attempt in 0..<5 {
                guard !Task.isCancelled, generation == self.panelOpeningGeneration else { return }
                if self.item.button?.window != nil {
                    self.showAnchoredPanel(refreshLevels: refreshLevels)
                    if self.popover.isShown { return }
                }
                if attempt < 4 { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
            guard generation == self.panelOpeningGeneration else { return }
            if !self.uiPreferences.showMenuBarIcon { self.item.isVisible = false }
            self.commandError = "Could not open the menu bar panel. Try opening the app again."
        }
    }

    private func showAnchoredPanel(refreshLevels: Bool) {
        guard let button = item.button else { return }
        if !popover.isShown {
            panelClosing = false
            popover.animates = uiPreferences.showMenuBarIcon
            restorePopoverBehavior()
            panel.metersPanel.render(liveLevels.snapshot)
            refresh(forceLayout: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            // Pointer opening needs no control focus halo. Keyboard opening keeps
            // the actionable initial focus and normal keyboard traversal.
            let keyboardOpening = NSApp.currentEvent?.type == .keyDown
            popover.contentViewController?.view.window?.makeFirstResponder(keyboardOpening ? panel.dspControl : nil)
            panelVisible = popover.isShown; updateMeterReader()
            if refreshLevels { requestAuxRefresh() }
            requestPresetRefresh()
        }
    }

    @objc package func togglePanel() {
        if popover.isShown || panelVisible || panelOpeningTask != nil { dismissPanel() } else { show() }
    }

    private func dismissPanel() {
        reopenAfterClosing = false
        panelOpeningGeneration += 1
        panelOpeningTask?.cancel(); panelOpeningTask = nil
        if !popover.isShown, !uiPreferences.showMenuBarIcon { item.isVisible = false }
        guard popover.isShown || panelVisible else { return }
        beginPanelClose()
        popover.performClose(nil)
    }

    private func applyMenuBarVisibility() {
        // A temporary anchor must be retired in the same close transaction.
        // Animated close can leave AppKit's isShown/didClose pending after its
        // window is already hidden. Restore normal animation on the next
        // ordinary (persistently visible icon) opening.
        if !uiPreferences.showMenuBarIcon { popover.animates = false }
        item.isVisible = uiPreferences.showMenuBarIcon || popover.isShown || panelOpeningTask != nil
    }

    private func refresh(forceLayout: Bool = false) {
        guard !panelClosing else { return }
        renderPresets()
        settingsWindow?.updateFaderRefreshAvailability(reason: auxRefreshUnavailableReason)
        let panelGeometryChanged = panel.render(presentation, error: visibleError)
        var aux = auxSnapshot
        if let error = auxError { aux?.error = error }
        if let error = aux?.error, dismissedErrors.contains(error) { aux?.error = nil }
        var auxGeometryChanged = false
        if !hasRenderedAux || renderedAux != aux {
            hasRenderedAux = true
            renderedAux = aux
            auxGeometryChanged = panel.auxPanel.render(aux)
            auxGeometryChanged = panel.mainPanel.render(aux) || auxGeometryChanged
        }
        let screenHeight = item.button?.window?.screen?.visibleFrame.height ?? 800
        guard forceLayout || panelGeometryChanged || auxGeometryChanged || measuredScreenHeight != screenHeight else { return }
        measuredScreenHeight = screenHeight
        let scrollOrigin = scrollView.contentView.bounds.origin
        let layout = PanelViewportLayout(naturalSize: panel.measureNaturalSize(), screenHeight: screenHeight)
        // Disable the overlay scroller entirely when all content fits. Autohiding alone
        // still lets AppKit flash it during document-size changes.
        if scrollView.hasVerticalScroller != layout.requiresScrolling {
            scrollView.hasVerticalScroller = layout.requiresScrolling
        }
        if panel.frame.size != layout.documentSize { panel.setFrameSize(layout.documentSize) }
        if popover.contentSize != layout.viewportSize { popover.contentSize = layout.viewportSize }
        scrollView.layoutSubtreeIfNeeded()
        panel.layoutSubtreeIfNeeded()
        let origin = NSPoint(x: 0, y: min(max(0, scrollOrigin.y), max(0, layout.documentSize.height - layout.viewportSize.height)))
        if scrollView.contentView.bounds.origin != origin {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    package var visibleError: String? {
        if let commandError { return commandError }
        if let auxError { return auxError }
        if let auxRefreshError { return auxRefreshError }
        if let error = auxSnapshot?.error, !dismissedErrors.contains(error) { return error }
        guard let presentation else { return nil }
        return [presentation.dspError, presentation.routingError, presentation.guiError].compactMap { $0 }
            .first { !dismissedErrors.contains($0) }
    }

    private func chooseDSPMode(_ index: Int) {
        guard let presentation else { return }
        let choice: ControllerCommand
        let current: Int
        if presentation.companionMode {
            guard (0..<2).contains(index) else { return }
            choice = index == 0 ? .on : .off
            switch presentation.mode {
            case .automatic, .forceOn: current = 0
            case .forceOff: current = 1
            }
        } else {
            guard (0..<3).contains(index) else { return }
            choice = [.auto, .on, .off][index]
            switch presentation.mode { case .automatic: current = 0; case .forceOn: current = 1; case .forceOff: current = 2 }
        }
        guard index != current || (presentation.companionMode && presentation.mode == .automatic) else { return }
        send(choice)
    }

    private func chooseProfile(_ id: String) {
        guard let presentation, id != presentation.selectedProfileID else { return }
        let choice: ControllerCommand
        switch presentation.mode { case .automatic: choice = .auto; case .forceOn: choice = .on; case .forceOff: choice = .off }
        send(choice, profileID: id)
    }

    private func chooseGUIMode(_ index: Int) {
        guard let presentation else { return }
        let current: Int
        switch presentation.guiPolicy { case .automatic: current = 0; case .manualOn: current = 1; case .manualOff: current = 2 }
        guard index != current else { return }
        sendGUI([.auto, .start, .stop][index])
    }

    @discardableResult package func send(_ action: ControllerCommand, profileID: String? = nil) -> Task<Void, Never> {
        commandRequestGeneration += 1
        let generation = commandRequestGeneration
        commandError = nil
        let request = MenuBarCommandRequest.make(command: action, profileID: profileID ?? presentation?.selectedProfileID)
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.command(request)
            guard generation == self.commandRequestGeneration else { return }
            if let error = reply.error { self.commandError = error }
            self.refresh()
        }
    }

    public func updatePresets(_ snapshot: PresetSnapshot) {
        presetRequests.updateSnapshot(snapshot)
    }

    private func renderPresets() {
        guard let value = presetSnapshot, value.profileID == presentation?.selectedProfileID else {
            let canRefresh = uiPreferences.presetsFolderPath != nil && presentation?.refreshAux.enabled == true
                && !presetRequestInFlight
            panel.setPresetChoices([], selectedID: nil, enabled: canRefresh,
                reason: uiPreferences.presetsFolderPath == nil ? "Choose a presets folder in Settings." : "Click to read presets.",
                allowsRefresh: canRefresh)
            return
        }
        let unavailable = Dictionary(value.entries.filter { !$0.available }.map { ($0.path, $0.reason ?? "Incompatible preset.") }, uniquingKeysWith: { first, _ in first })
        let restarting = Dictionary(value.entries.filter { $0.available && $0.requiresAudioRestart }.map {
            ($0.path, (["Restarts audio"] + $0.settingChanges).joined(separator: "\n"))
        }, uniquingKeysWith: { first, _ in first })
        let external = value.activeTitle.map { "External: " + $0 } ?? (value.ready ? "External preset" : "Presets…")
        let eligibility = presentation?.refreshAux
        panel.setPresetChoices(value.entries.map { (id: $0.path, title: $0.title) }, selectedID: value.activePath,
            enabled: !value.busy && !presetRequestInFlight && eligibility?.enabled == true,
            reason: value.busy || presetRequestInFlight ? "Reading or changing preset…"
                : value.error ?? (eligibility?.enabled == true ? nil : eligibility?.reason),
            unavailableIDs: unavailable, restartingIDs: restarting, placeholderTitle: external,
            allowsRefresh: uiPreferences.presetsFolderPath != nil)
    }

    package func requestPresetRefresh() { presetRequests.requestRefresh() }

    package func requestPresetChange(_ path: String) {
        if !presetRequests.requestChange(path) { renderPresets() }
    }

    private func sendGUI(_ action: GUICommand) {
        guard let id = presentation?.selectedProfileID else { return }
        commandRequestGeneration += 1
        let feedbackGeneration = commandRequestGeneration
        commandError = nil
        guiRequestGeneration += 1
        let generation = guiRequestGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.guiCommand(.init(command: action, profileID: id))
            guard generation == self.guiRequestGeneration, self.presentation?.selectedProfileID == id else { return }
            if feedbackGeneration == self.commandRequestGeneration, let error = reply.error { self.commandError = error }
            self.refresh()
        }
    }

    private func openInterface() {
        guard let gui = presentation?.selectedProfile?.gui,
              let url = URL(string: gui.url), openURL(url) else {
            commandError = "Could not open the web interface. Check your default browser and try again."
            refresh()
            return
        }
        commandError = nil
        refresh()
    }

    private final class MenuAction {
        let perform: () -> Void
        init(_ perform: @escaping () -> Void) { self.perform = perform }
    }

    package func makeMoreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, help: String? = nil, action: @escaping () -> Void) {
            let entry = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = MenuAction(action); entry.toolTip = help
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        add("Settings") { [weak self] in self?.settingsAfterMenu = true }
        let folder = presetsFolderAvailability
        add("Open Presets Folder", enabled: folder.url != nil, help: folder.reason ?? "Open the configured presets folder in Finder.") { [weak self] in
            self?.openPresetsFolder()
        }
        add("About & Diagnostics") { [weak self] in self?.aboutAfterMenu = true }
        menu.addItem(.separator())
        add("Quit and Restore Output", help: "Stop DSP and GUI, restore output, and quit.") { [weak self] in
            guard let self else { return }
            self.dismissPanel()
            self.quit()
        }
        menu.items.last?.attributedTitle = NSAttributedString(string: "Quit and Restore Output", attributes: [.foregroundColor: NSColor.systemRed])
        return menu
    }

    private var presetsFolderAvailability: (url: URL?, reason: String?) {
        guard let path = uiPreferences.presetsFolderPath, !path.isEmpty else {
            return (nil, "Choose a presets folder in Settings first.")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return (nil, "Choose an absolute presets folder path in Settings.") }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (nil, "The configured presets folder is missing or is not a directory. Choose an existing folder in Settings.")
        }
        return (url, nil)
    }
    private func openPresetsFolder() {
        let folder = presetsFolderAvailability
        guard let url = folder.url else { commandError = folder.reason; refresh(); return }
        guard openURL(url) else {
            commandError = "Could not open the presets folder: " + url.path
            refresh(); return
        }
    }

    private func showMore(_ button: NSButton) {
        let menu = makeMoreMenu()
        // Keep the panel open while its child menu tracks. Present About only
        // after tracking returns so dismissal does not compete with its window.
        setChildMenuTracking(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        setChildMenuTracking(false)
        if settingsAfterMenu { settingsAfterMenu = false; showSettings() }
        if aboutAfterMenu {
            aboutAfterMenu = false
            showDiagnostics()
        }
    }

    package func setPinned(_ value: Bool) {
        pinned = value
        panel.setPinned(value)
        restorePopoverBehavior()
    }

    private func restorePopoverBehavior() {
        popover.behavior = pinned || childTrackingDepth > 0 ? .applicationDefined : .transient
    }

    package func setChildMenuTracking(_ tracking: Bool) {
        childTrackingDepth = max(0, childTrackingDepth + (tracking ? 1 : -1))
        restorePopoverBehavior()
    }

    @objc package func applicationWillHide(_ notification: Notification) {
        applicationHidden = true
        reopenAfterClosing = false
        panelOpeningGeneration += 1
        panelOpeningTask?.cancel(); panelOpeningTask = nil
        applyMenuBarVisibility()
        panel.cancelPresetOpening()
        presetRequests.discardQueuedRefresh()
        updateMeterReader()
    }

    @objc package func applicationDidUnhide(_ notification: Notification) {
        applicationHidden = false
        updateMeterReader()
    }

    package var meterReaderVisible: Bool { panelVisible && !panelClosing && !applicationHidden && !NSApp.isHidden }

    @objc package func menuAction(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.perform() }

    public func setDiagnosticsProvider(_ provider: @escaping () -> String,
                                       dspVersion: @escaping () -> String = { "Unavailable" }) {
        diagnosticsProvider = provider
        dspVersionProvider = dspVersion
    }

    private func diagnosticText() -> String {
        if let diagnosticsProvider {
            let levels = liveLevels.snapshot
            let meterStatus = "\n\nLive Metering: enabled \(levels.enabled); reading \(levels.reading); panel open \(panelVisible); input channels \(levels.levels?.input.count ?? 0); output channels \(levels.levels?.output.count ?? 0)"
            let localErrors = [commandError, auxError, auxRefreshError, levels.error].compactMap { $0 }
            return diagnosticsProvider() + meterStatus + "\n\n" + levels.diagnostics.report + (localErrors.isEmpty ? "" : "\n\nMenu errors:\n" + localErrors.joined(separator: "\n"))
        }
        return [ApplicationMetadata.name + " " + ApplicationMetadata.version,
                ApplicationMetadata.buildIdentifier, ApplicationMetadata.copyright,
                presentation?.dspStatusText, presentation?.routingStatusText, presentation?.guiStatusText,
                presentation?.outputLine, presentation?.context, presentation?.dspError, presentation?.routingError,
                presentation?.guiError, commandError, auxSnapshot?.error, auxError, auxRefreshError, liveLevels.snapshot.error,
                liveLevels.snapshot.diagnostics.report]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Owned windows preserve an explicit Pin choice; transient panels dismiss.
    package func prepareForOwnedWindow() {
        if !pinned { dismissPanel() }
    }

    private func showDiagnostics() {
        if aboutWindow == nil {
            aboutWindow = AboutDiagnosticsWindow(provider: { [weak self] in self?.diagnosticText() ?? "Diagnostics unavailable" },
                dspVersion: { [weak self] in self?.dspVersionProvider() ?? "Unavailable" })
        }
        prepareForOwnedWindow()
        aboutWindow?.show()
    }

    public func setAuxDragHandlers(begin: @escaping (Int, String?, AuxVolumeIntent) -> Bool,
                                  update: @escaping (Int, Double, String?) -> Void,
                                  end: @escaping (Int, Double, String?) -> Void,
                                  cancel: @escaping () -> Void) {
        for faders in [panel.mainPanel, panel.auxPanel] {
        faders.onVolumeDragBegin = begin
        faders.onVolumeDragUpdate = update
        faders.onVolumeDragEnd = end
        faders.onVolumeDragCancel = cancel
        }
    }

    public func setAuxHandlers(refresh: @escaping () async throws -> Void,
                               volume: @escaping (Int, Double, AuxVolumeIntent) async throws -> Void,
                               mute: @escaping (Int, Bool, AuxVolumeIntent) async throws -> Void,
                               preferences: @escaping (AuxPreferences) async throws -> Void) {
        auxRefresh = refresh; auxVolume = volume; auxMute = mute; auxPreferences = preferences
        self.refresh()
    }

    public func updateAux(_ snapshot: AuxFaderSnapshot?) {
        if auxSnapshot?.profileID != snapshot?.profileID { auxGeneration += 1; auxError = nil; auxRefreshError = nil }
        else if auxSnapshot?.ready == true && snapshot?.ready != true { auxGeneration += 1 }
        // Only fresh readback completion retires a failed/declined read. Failed
        // writes remain in auxError even when an unrelated refresh succeeds.
        if snapshot?.ready == true, snapshot?.busy == false, snapshot?.error == nil,
           auxSnapshot?.ready != true || auxSnapshot?.busy == true {
            auxRefreshError = nil
            settingsWindow?.updateFaderRefreshResult(error: nil)
        }
        if auxSnapshot?.profileID != snapshot?.profileID || snapshot?.ready != true { cancelPreciseConfirmation() }
        auxSnapshot = snapshot
        settingsWindow?.updateAuxSnapshot(snapshot)
        refresh()
    }

    private var auxRefreshUnavailableReason: String? {
        guard auxRefresh != nil else { return "Fader refresh is unavailable." }
        guard let presentation, presentation.refreshAux.enabled else {
            return presentation?.refreshAux.reason ?? "DSP is unavailable."
        }
        guard auxSnapshot?.profileID == presentation.selectedProfileID else { return "Aux profile is changing." }
        if auxSnapshot?.busy == true { return "Finish the Aux edit before refreshing levels." }
        if auxRefreshInFlightGeneration == auxGeneration { return "Reading fader values…" }
        return nil
    }

    package func requestAuxRefresh() {
        guard let operation = auxRefresh else {
            settingsWindow?.updateFaderRefreshResult(error: "Fader refresh is unavailable.")
            return
        }
        if let reason = auxRefreshUnavailableReason {
            auxRefreshError = reason; settingsWindow?.updateFaderRefreshResult(error: reason); refresh(); return
        }
        let generation = auxGeneration
        let profileID = presentation?.selectedProfileID
        auxRefreshInFlightGeneration = generation
        refresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.auxRefreshInFlightGeneration == generation { self.auxRefreshInFlightGeneration = nil }
                self.refresh()
            }
            guard generation == self.auxGeneration, self.presentation?.selectedProfileID == profileID,
                  self.auxSnapshot?.profileID == profileID else { return }
            guard self.presentation?.refreshAux.enabled == true, self.auxSnapshot?.busy != true else {
                let reason = self.presentation?.refreshAux.reason ?? "Finish the Aux edit before refreshing levels."
                self.auxRefreshError = reason
                self.settingsWindow?.updateFaderRefreshResult(error: reason)
                return
            }
            do {
                try await operation()
                if generation == self.auxGeneration {
                    self.auxRefreshError = nil; self.settingsWindow?.updateFaderRefreshResult(error: nil)
                }
            } catch {
                // Failed reads can invalidate readiness while publishing this same
                // error; retain that current result, but discard stale profile work.
                let currentReadFailure = self.presentation?.selectedProfileID == profileID
                    && self.auxSnapshot?.profileID == profileID
                    && self.auxSnapshot?.error == error.localizedDescription
                if generation == self.auxGeneration || currentReadFailure {
                    self.auxRefreshError = error.localizedDescription
                    self.settingsWindow?.updateFaderRefreshResult(error: error.localizedDescription)
                }
            }
        }
    }

    private func writeAux(id: Int, db: Double?, muted: Bool?, profile: String?, intent: AuxVolumeIntent) {
        guard let snapshot = auxSnapshot, snapshot.profileID == profile,
              presentation?.selectedProfileID == profile, snapshot.ready, !snapshot.busy else {
            rejectAuxCommand("Aux change was not accepted. Finish the current edit or refresh when DSP is ready."); return
        }
        let generation = auxGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.auxGeneration, self.auxSnapshot?.profileID == profile,
                  self.presentation?.selectedProfileID == profile,
                  self.auxSnapshot?.ready == true, self.auxSnapshot?.busy == false else {
                if let self, generation == self.auxGeneration {
                    self.rejectAuxCommand("Aux availability changed before the command could start.")
                }
                return
            }
            do {
                if let db, let operation = self.auxVolume { try await operation(id, db, intent) }
                if let muted, let operation = self.auxMute { try await operation(id, muted, intent) }
                self.panel.auxPanel.commandRejected()
                self.panel.mainPanel.commandRejected()
                self.auxError = nil
            } catch { if generation == self.auxGeneration { self.rejectAuxCommand(error.localizedDescription) } }
            self.refresh()
        }
    }

    package func rejectAuxCommand(_ reason: String) {
        panel.auxPanel.commandRejected()
        panel.mainPanel.commandRejected()
        auxError = reason
        refresh()
    }

    public func setUIPreferences(_ preferences: UIPreferences, error: String? = nil,
                                 save: @escaping (UIPreferences) throws -> Void) {
        if uiPreferences.presetsFolderPath != preferences.presetsFolderPath {
            presetRequests.invalidate()
        }
        uiPreferences = preferences; uiPreferencesError = error; saveUIPreferences = save
        applyMenuBarVisibility()
        AudioControlStyle.keepActiveColors = preferences.keepActiveColors
        panel.refreshSelectionAppearance()
        settingsWindow?.updatePreferences(preferences, error: error, preserveNumericDrafts: true)
        updateMainSliderRange()
        updateMeterReader()
    }

    public func updateSignalTarget(profile: Profile?, ready: Bool) {
        let becameReady = ready && (!levelsReady || levelsProfile != profile)
        levelsProfile = profile; levelsReady = ready
        updateMeterReader()
        presetRequests.readinessChanged(becameReady: becameReady)
    }
    package func renderMeterSnapshot(_ value: SignalLevelsSnapshot) {
        guard !panelClosing else { return }
        if panel.metersPanel.render(value) { refresh(forceLayout: true) }
    }

    private func changeMeterNumericMode(_ mode: SignalMeterNumericMode) {
        guard let save = saveUIPreferences else {
            commandError = "Settings are unavailable."; refresh(); return
        }
        var next = uiPreferences; next.meterNumericMode = mode
        do {
            try save(next)
            uiPreferences = next; uiPreferencesError = nil
            settingsWindow?.updatePreferences(next, preserveNumericDrafts: true)
            panel.metersPanel.setNumericMode(mode)
            if commandError?.hasPrefix("Could not save meter mode:") == true { commandError = nil; refresh() }
        } catch {
            commandError = "Could not save meter mode: " + error.localizedDescription
            refresh()
        }
    }

    private func updateMeterReader() {
        panel.metersPanel.setNumericMode(uiPreferences.meterNumericMode)
        panel.metersPanel.setReadingContext(profileID: levelsProfile?.id, ready: levelsReady,
                                           refreshInteraction: !panelClosing)
        if !panelClosing {
            panel.metersPanel.setDisplayRange(minimumDB: uiPreferences.meterOptions.minimumDB,
                                             maximumDB: uiPreferences.meterOptions.maximumDB)
        }
        liveLevels.update(enabled: uiPreferences.liveLevels, visible: meterReaderVisible, profile: levelsProfile, ready: levelsReady,
                          options: uiPreferences.meterOptions)
    }
    private func updateMainSliderRange() {
        let range = uiPreferences.mainSliderRange(profileID: presentation?.selectedProfileID)
        panel.mainPanel.setMainSliderRange(minimumDB: range.minimumDB, maximumDB: range.maximumDB)
        refresh()
    }
    private func toggleLiveLevels(_ enabled: Bool) {
        guard let save = saveUIPreferences else { commandError = "Settings are unavailable."; panel.metersPanel.render(liveLevels.snapshot); refresh(); return }
        var next = uiPreferences; next.liveLevels = enabled
        do {
            try save(next); uiPreferences = next; uiPreferencesError = nil
            settingsWindow?.updatePreferences(next, preserveNumericDrafts: true); updateMeterReader()
        } catch {
            commandError = "Could not save Live Metering: " + error.localizedDescription
            panel.metersPanel.render(liveLevels.snapshot); refresh()
        }
    }

    package func makeSettingsWindow() -> NativeSettingsWindow {
        let window = NativeSettingsWindow(preferences: uiPreferences, error: uiPreferencesError,
            profileID: presentation?.selectedProfileID, profileName: presentation?.selectedProfile?.name,
            auxSnapshot: auxSnapshot, loginItemManager: loginItemManager, onSetup: setupHandler,
            settingsDirectoryURL: settingsDirectoryURL,
            onSaveAux: { [weak self] profile, preferences in
                guard let self, let operation = self.auxPreferences,
                      self.auxSnapshot?.profileID == profile,
                      self.presentation?.selectedProfileID == profile,
                      self.auxSnapshot?.preferencesEditable == true else {
                    throw SwitcherError.message("Aux settings are unavailable for this profile. Select it again to edit its settings.")
                }
                try await operation(preferences)
            }, onRefreshFaders: { [weak self] in self?.requestAuxRefresh() },
            interfaceProfiles: interfaceProfilesHandlers) { [weak self] next in
            guard let self, let save = self.saveUIPreferences else { throw SwitcherError.message("Settings are unavailable.") }
            try save(next)
            if self.uiPreferences.presetsFolderPath != next.presetsFolderPath {
                self.presetRequests.invalidate()
            }
            self.uiPreferences = next; self.uiPreferencesError = nil
            self.applyMenuBarVisibility()
            AudioControlStyle.keepActiveColors = next.keepActiveColors
            self.panel.refreshSelectionAppearance()
            self.updateMainSliderRange()
            self.updateMeterReader()
        }
        window.updateFaderRefreshAvailability(reason: auxRefreshUnavailableReason)
        return window
    }
    private func showSettings(tab: SettingsTab? = nil) {
        prepareForOwnedWindow()
        // Keep profile-bound unfinished edits when the Settings window is reopened.
        if settingsWindow == nil { settingsWindow = makeSettingsWindow() }
        settingsWindow?.show(tab: tab)
    }

    public func setAuxPreciseHandlers(prepare: @escaping (Int, Double) async throws -> AuxVolumeProposal,
                                      apply: @escaping (AuxVolumeProposal, AuxVolumeIntent) async throws -> AuxVolumeProposal?) {
        preparePreciseVolume = prepare; applyPreciseVolume = apply
    }

    private func faderPanel(_ id: Int) -> AuxFaderPanel { id == 0 ? panel.mainPanel : panel.auxPanel }

    private func enterPreciseVolume(id: Int, db: Double, profile: String?) {
        guard let prepare = preparePreciseVolume, let apply = applyPreciseVolume,
              auxSnapshot?.profileID == profile, presentation?.selectedProfileID == profile,
              auxSnapshot?.ready == true, auxSnapshot?.busy == false else {
            rejectAuxCommand("Aux value is unavailable. Refresh when DSP is ready."); return
        }
        let generation = auxGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var proposal = try await prepare(id, db)
                var requireConfirmation = proposal.linked
                while generation == self.auxGeneration, self.presentation?.selectedProfileID == profile {
                    guard self.popover.isShown else { self.faderPanel(id).restorePreciseValue(id: id); return }
                    if !proposal.changed { self.faderPanel(id).restorePreciseValue(id: id); return }
                    let intent: AuxVolumeIntent
                    if requireConfirmation {
                        guard let choice = await self.confirmPreciseVolume(proposal) else {
                            self.faderPanel(id).restorePreciseValue(id: id); return
                        }
                        intent = choice
                    } else { intent = .individual }
                    guard generation == self.auxGeneration, self.presentation?.selectedProfileID == profile else {
                        throw SwitcherError.message("Aux profile changed while confirming the value.")
                    }
                    if let updated = try await apply(proposal, intent) {
                        proposal = updated
                        requireConfirmation = true
                    } else { self.auxError = nil; self.refresh(); return }
                }
                throw SwitcherError.message("Aux profile changed before the value could be applied.")
            } catch {
                if generation == self.auxGeneration { self.rejectAuxCommand(error.localizedDescription) }
            }
        }
    }

    private func confirmPreciseVolume(_ proposal: AuxVolumeProposal) async -> AuxVolumeIntent? {
        func levels(_ candidate: AuxVolumeCandidate) -> String {
            candidate.faders.map { "\($0.name): \(String(format: "%.1f", $0.volumeDB)) dB" }.joined(separator: ", ")
        }
        let alert = NSAlert()
        alert.messageText = proposal.linked ? "Apply to Group or Trim This Fader?" : "Confirm Aux Value"
        var lines: [String] = []
        if proposal.requestedDB != proposal.effectiveDB {
            lines.append("Entered \(proposal.requestedDB) dB; minimum permitted value is \(proposal.effectiveDB) dB.")
        }
        lines.append("Current: " + proposal.members.map { "\($0.name): \(String(format: "%.1f", $0.volumeDB)) dB" }.joined(separator: ", "))
        if proposal.linked {
            lines.append("Group: " + levels(proposal.group))
            if let reason = proposal.group.reason { lines.append(reason) }
            lines.append("Trim This Fader: " + levels(proposal.individual) + ". Other members keep their current values above. The link group remains intact.")
        } else { lines.append("Result: " + levels(proposal.individual)) }
        if let reason = proposal.individual.reason { lines.append(reason) }
        alert.informativeText = lines.joined(separator: "\n\n")
        if proposal.linked {
            alert.addButton(withTitle: "Group").isEnabled = proposal.group.available
            alert.addButton(withTitle: "Trim This Fader").isEnabled = proposal.individual.available
        } else { alert.addButton(withTitle: "Apply").isEnabled = proposal.individual.available }
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.buttons.first?.keyEquivalent = "\r"
        preciseAlert = alert
        setChildMenuTracking(true)
        defer { preciseAlert = nil; setChildMenuTracking(false) }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            presentAuxAlert(alert) { continuation.resume(returning: $0) }
        }
        if response == .alertFirstButtonReturn { return proposal.linked ? .group : .individual }
        if proposal.linked && response == .alertSecondButtonReturn { return .individual }
        return nil
    }

    private func presentAuxAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if popover.isShown, let window = popover.contentViewController?.view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else { completion(.abort) }
    }

    private func cancelPreciseConfirmation() {
        guard let alert = preciseAlert, let parent = alert.window.sheetParent else { return }
        parent.endSheet(alert.window, returnCode: .abort)
    }

    public func popoverWillClose(_ notification: Notification) { beginPanelClose() }

    package func beginPanelClose() {
        panelOpeningGeneration += 1
        panelOpeningTask?.cancel(); panelOpeningTask = nil
        // Cancel reads before changing presentation. Keep the last geometry and
        // pixels intact until AppKit completes its closing animation.
        panelClosing = true
        panel.cancelPresetOpening()
        presetRequests.discardQueuedRefresh()
        panelVisible = false; updateMeterReader()
        cancelPreciseConfirmation()
        panel.auxPanel.cancelVolumeDrag()
        panel.mainPanel.cancelVolumeDrag()
    }

    public func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown, !panelVisible, panelClosing else { return }
        panelClosing = false
        applyMenuBarVisibility()
        panel.metersPanel.render(liveLevels.snapshot)
        refresh(forceLayout: true)
        if reopenAfterClosing { reopenAfterClosing = false; show() }
    }

    public func stop() {
        reopenAfterClosing = false
        panelOpeningGeneration += 1
        panelOpeningTask?.cancel(); panelOpeningTask = nil
        NotificationCenter.default.removeObserver(self)
        presetRequests.discardQueuedRefresh()
        panelClosing = true
        panelVisible = false; liveLevels.stop()
        aboutWindow?.close()
        settingsWindow?.close()
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
    }

}
