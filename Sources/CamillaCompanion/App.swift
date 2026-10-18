import Foundation
import AppKit
import Darwin
import AutoAudioCore
import AutoAudioPlatform

@main
@MainActor
enum Application {
    static var previewHUD: FeedbackHUD?
    static var session: InteractiveSession?
    static var previewMenu: MenuBarController?
    static var setupWindow: SetupWindowController?
    static let applicationDelegate = ApplicationReopenDelegate()

    static func main() {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            if ApplicationEntry.usesNativeLaunch(arguments: args, bundleURL: Bundle.main.bundleURL,
                packageType: Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String) {
                args = ["--app-launch"]
            }
            let command = args.isEmpty ? "help" : args.removeFirst()
            switch command {
            case "setup", "launch", "--app-launch":
                try openApplication(arguments: args, setupOnly: command == "setup")
            case "version", "--version":
                guard args.isEmpty else { throw SwitcherError.message("version takes no arguments.") }
                print("\(ApplicationMetadata.name) \(ApplicationMetadata.version) (\(ApplicationMetadata.buildIdentifier))")
            case "help", "--help", "-h": print(usage)
            case "devices":
                guard args.isEmpty else { throw SwitcherError.message("devices takes no arguments.") }
                let snapshot = try CoreAudioManager().snapshot()
                for device in snapshot.devices {
                    let flags = [device.hasOutput ? "output" : "input-only", device.isBuiltIn ? "built-in" : "",
                                 snapshot.outputUID == device.uid ? "default" : "",
                                 snapshot.alertUID == device.uid ? "alerts" : ""].filter { !$0.isEmpty }
                    print("\(device.name) [\(flags.joined(separator: ", "))]\n  UID: \(device.uid)")
                }
            case "preview-hud":
                let options = try Options(args)
                let config = try ConfigurationLoader.load(from: options.configURL)
                NSApplication.shared.setActivationPolicy(.accessory)
                let hud = FeedbackHUD(settings: config.feedback ?? FeedbackSettings())
                previewHUD = hud
                Task { @MainActor in
                    hud.preview()
                    try? await Task.sleep(nanoseconds: UInt64(((config.feedback?.durationSeconds ?? 4) + 1) * 1_000_000_000))
                    hud.stop(); exit(EXIT_SUCCESS)
                }
                NSApplication.shared.run()
            case "status", "profiles", "show", "auto", "on", "off", "retry", "resume", "release", "reconnect", "presets", "preset":
                let request = try ControllerArguments(command: command, arguments: args)
                try printControllerReply(ControllerCommandClient.send(request.request, stateURL: request.stateURL))
            case "preview-menu", "--menu-preview":
                NSApplication.shared.delegate = applicationDelegate
                let show = args.contains("--show")
                let hiddenIcon = args.contains("--hidden-icon")
                args.removeAll { $0 == "--show" || $0 == "--hidden-icon" }
                if args.first == "--scenario" { args.removeFirst() }
                let scenario = args.first ?? "active"
                guard args.count <= 1 else { throw SwitcherError.message("Use preview-menu [--scenario NAME] [--show] [--hidden-icon]") }
                let presentation = try menuPreview(scenario)
                NSApplication.shared.setActivationPolicy(.accessory)
                let menu = MenuBarController(command: { _ in ControllerReply(error: "Preview controls are inert") },
                    guiCommand: { _ in GUIReply(error: "Preview controls are inert") }, quit: { exit(EXIT_SUCCESS) }, openURL: { _ in false })
                previewMenu = menu
                var previewPreferences = UIPreferences()
                previewPreferences.showMenuBarIcon = !hiddenIcon
                // Preview appearance is in memory only. It never adopts or
                // writes the installed controller's preferences or audio policy.
                menu.setUIPreferences(previewPreferences, save: { _ in })
                menu.update(presentation)
                let auxPreview = menuAuxPreview(scenario)
                menu.updateAux(auxPreview)
                menu.setAuxHandlers(refresh: { }, volume: { _, _, _ in
                    var snapshot = auxPreview; snapshot.error = "Preview controls are inert"
                    menu.updateAux(snapshot)
                }, mute: { _, _, _ in
                    var snapshot = auxPreview; snapshot.error = "Preview controls are inert"
                    menu.updateAux(snapshot)
                }, preferences: { _ in throw SwitcherError.message("Preview controls are inert") })
                if show { menu.show() }
                NSApplication.shared.run()
            case "gui":
                let request = try GUIArguments(args)
                let reply = try GUICommandClient.send(request.request, stateURL: request.stateURL)
                try printGUIReply(reply, command: request.request.command)
            case "validate":
                let options = try Options(args)
                let config = try ConfigurationLoader.load(from: options.configURL)
                print("Configuration valid: \(config.profiles.count) profile(s).")
                print("This checks the file format, not connected hardware or DSP readiness.")
            case "run":
                NSApplication.shared.delegate = applicationDelegate
                let options = try Options(args)
                let config = try ConfigurationLoader.load(from: options.configURL)
                if let id = options.profileID, !config.profiles.contains(where: { $0.id == id }) {
                    throw SwitcherError.message("Unknown profile: \(id)")
                }
                guard options.mode != .forceOn || options.profileID != nil else {
                    throw SwitcherError.message("--mode force-on requires --profile ID.")
                }
                let live = try InteractiveSession(configuration: config, options: options)
                session = live
                Task { await live.start() }
                if options.menuBar || (config.feedback?.mode != nil && config.feedback?.mode != .off) {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    NSApplication.shared.run()
                } else { RunLoop.main.run() }
            default: throw SwitcherError.message("Unknown command: \(command). Use --help.")
            }
        } catch {
            writeError(error.localizedDescription)
            exit(EXIT_FAILURE)
        }
    }

    static let usage = """
    CamillaCompanion development CLI (macOS 13+)

      camillacompanion preview-hud --config PATH
      camillacompanion preview-menu [--scenario active|disconnected|recovering|failed|released|no-gui|multiple|aux|aux-linked|aux-hidden|aux-empty] [--show] [--hidden-icon]
      camillacompanion status|profiles|auto|on|off|retry|resume|release|reconnect [--profile ID] [--state PATH]
      camillacompanion presets [--profile ID] [--state PATH]
      camillacompanion preset --file PATH [--profile ID] [--state PATH]
      camillacompanion devices
      camillacompanion setup [--config PATH] [--state PATH]
      camillacompanion launch [--config PATH] [--state PATH]
      camillacompanion show [--state PATH]
      camillacompanion version
      camillacompanion validate --config PATH
      camillacompanion gui start|stop|auto|retry|status --profile ID [--state PATH]
      camillacompanion run --config PATH [--profile ID] [--mode auto|force-on|force-off] [--state PATH] [--menu-bar true|false]

    devices and validate do not change audio or services.
    run manages configured services; Automatic Switching also manages audio outputs.
    With switching disabled, saved companion intent applies unless launch options override it.
    While running, enter: status, profiles, auto [ID], on ID, off, retry, resume, release, reconnect [ID], quit.
    Ctrl-C and quit restore owned routes and stop managed DSP where possible.
    Menu bar is optional (--menu-bar true) and shares the existing controller.
    Release restores output while keeping a healthy DSP running in Auto or On.
    Resume reacquires DSP routing. Off stops DSP; bypass does not mute it.
    Reconnect intentionally restarts DSP only and interrupts audio; it does not reset USB.
    GUI mode overrides apply to this controller session only.
    Commands return accepted/current state; completion and failure appear in controller logs.
    No idle polling. Optional Live Levels reads only while enabled and the menu is open.
    Failure recovery checks are bounded to 30 seconds.
    """
}

struct Options {
    let configURL: URL
    var profileID: String?
    var mode: AutomationMode = .automatic
    var modeWasSpecified = false
    var menuBar = false
    var stateURL: URL

    init(_ arguments: [String]) throws {
        var config: String?
        var explicitStateURL: URL?
        var args = arguments.makeIterator()
        var seen = Set<String>()
        while let flag = args.next() {
            guard seen.insert(flag).inserted, let value = args.next() else {
                throw SwitcherError.message("Missing value or repeated option: \(flag)")
            }
            switch flag {
            case "--config": config = value
            case "--profile": profileID = value
            case "--state": explicitStateURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--menu-bar":
                guard value == "true" || value == "false" else { throw SwitcherError.message("--menu-bar requires true or false") }
                menuBar = value == "true"
            case "--mode":
                modeWasSpecified = true
                switch value {
                case "auto": mode = .automatic
                case "force-on": mode = .forceOn
                case "force-off": mode = .forceOff
                default: throw SwitcherError.message("Mode must be auto, force-on, or force-off.")
                }
            default: throw SwitcherError.message("Unknown option: \(flag)")
            }
        }
        guard let config else { throw SwitcherError.message("--config PATH is required.") }
        configURL = URL(fileURLWithPath: (config as NSString).expandingTildeInPath)
        stateURL = explicitStateURL ?? ApplicationSupportPaths.select(homeDirectory: URL(fileURLWithPath: NSHomeDirectory())).runtimeStateURL
    }
}

@MainActor
final class InteractiveSession {
    private let hud: FeedbackHUD
    private let uiPreferencesStore: JSONUIPreferencesStore
    private let fallbackPreferencesStore: JSONFallbackPreferencesStore
    private var fallbackPreferencesError: String?
    private var uiPreferences = UIPreferences()
    private var uiPreferencesError: String?
    private var confirmedGUIAbsentProfiles = Set<String>()
    private let gui: GUIController
    private let aux: AuxController
    private let presets: PresetController
    private var commandServer: GUICommandServer?
    private var menuBar: MenuBarController?
    private var latestSnapshot: AudioSnapshot?
    private var auxTargetID: String?
    private var auxTargetReady = false
    private let engine: Reconciler
    private let configuration: Configuration
    private let options: Options
    private var signalSources: [DispatchSourceSignal] = []
    private var inputBuffer = Data()
    private var shuttingDown = false
    private var panelRequested = false
    private var instanceLock: ControllerInstanceLock?
    private let timings = SessionTransitionTimings()
    private var wasRecovering = false
    private var lastCommandError: String?

    init(configuration: Configuration, options: Options, instanceLock: ControllerInstanceLock? = nil) throws {
        self.configuration = configuration
        self.options = options
        self.instanceLock = try instanceLock ?? ControllerInstanceLock(stateURL: options.stateURL)
        do {
            confirmedGUIAbsentProfiles = Set(try SetupReceipt.load(configurationURL: options.configURL).confirmedGUIAbsentProfileIDs)
        } catch { log("Could not load setup information: " + error.localizedDescription) }
        hud = FeedbackHUD(settings: configuration.feedback ?? FeedbackSettings())
        uiPreferencesStore = JSONUIPreferencesStore(runtimeStateURL: options.stateURL)
        fallbackPreferencesStore = JSONFallbackPreferencesStore(runtimeStateURL: options.stateURL)
        var fallbackPreferences = FallbackOutputPreferences()
        do { fallbackPreferences = try fallbackPreferencesStore.load() }
        catch {
            let message = "Could not load fallback outputs: " + error.localizedDescription
            fallbackPreferencesError = message
            log(message)
        }
        gui = GUIController(profiles: configuration.profiles,
                            service: LaunchdGUIManager(directory: options.stateURL.deletingLastPathComponent().appendingPathComponent("GUIJobs")))
        let auxStore = JSONAuxPreferencesStore(url: URL(fileURLWithPath: options.stateURL.path + ".aux-preferences.json"))
        aux = AuxController(transport: CamillaAuxDSPTransport(),
                            loadPreferences: { try auxStore.load(profileID: $0) },
                            savePreferences: { try auxStore.save($1, profileID: $0) })
        presets = PresetController(transport: CamillaPresetDSPTransport())
        do { uiPreferences = try uiPreferencesStore.load() }
        catch {
            uiPreferencesError = "Could not load Settings: " + error.localizedDescription
            log(uiPreferencesError!)
        }
        engine = Reconciler(profiles: configuration.profiles, audio: CoreAudioManager(),
                            dsp: LaunchdDSPManager(log: log), store: JSONRouteStore(url: options.stateURL),
                            fallbackPreferences: fallbackPreferences,
                            automaticSwitching: uiPreferences.automaticSwitching,
                            companionMode: uiPreferences.companionDSPMode,
                            companionProfileID: uiPreferences.companionProfileID, log: log)
        hud.setSilentMode(uiPreferences.silentMode)

        engine.onExternalOutputSelection = { [weak self] profileID, device in
            guard let self, !self.shuttingDown, self.uiPreferences.followMacOSOutput else { return }
            do {
                if let error = self.fallbackPreferencesError { throw SwitcherError.message(error) }
                let previous = self.engine.fallbackPreference(profileID: profileID)
                var preference = previous
                preference.outputSelection = .device
                preference.outputUID = device.uid; preference.outputName = device.name
                guard preference != previous else { return }
                try self.engine.validateFallbackPreference(preference, profileID: profileID)
                var preferences = self.engine.fallbackPreferences
                preferences.profiles[profileID] = preference
                try self.fallbackPreferencesStore.save(preferences)
                try self.engine.setFallbackPreference(preference, profileID: profileID)
                log("Saved macOS output selection for \(profileID): \(device.name)")
            } catch {
                let message = "Could not save macOS output selection: " + error.localizedDescription
                self.lastCommandError = message
                self.menuBar?.reportOutputTargetError(message)
                log(message)
            }
        }

        gui.onFeedback = { [weak hud] in hud?.receive($0) }
        engine.onFeedback = { [weak hud] in hud?.receive($0) }

        engine.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.latestSnapshot = snapshot
            self.hud.seedOutput(snapshot.outputUID); self.gui.receive(snapshot)
            self.publishStatus()
        }
        engine.onStateChange = { [weak self] state in
            log("State: \(state)")
            self?.recordDSPTiming(state)
            if case .failed(let reason) = state { self?.hud.receive(.failure(source: "dsp", message: reason)) }
            self?.publishStatus()
        }
        engine.onControlChange = { [weak self] in
            self?.recordControlTiming()
            self?.publishStatus()
        }
        gui.onLog = log
        gui.onStatusChange = { [weak self] status in
            self?.recordGUITiming(status)
            self?.publishStatus()
        }
        aux.onChange = { [weak self] snapshot in self?.menuBar?.updateAux(snapshot) }
        presets.onChange = { [weak self] snapshot in self?.menuBar?.updatePresets(snapshot) }
    }

    func start() async {
        do {
            // One startup inspection; never a periodic service check.
            try await rejectLegacyWatcher()
            installSignalHandlers()
            if engine.automaticSwitching {
                engine.setMode(options.mode, profileID: options.profileID)
            } else if options.modeWasSpecified || options.profileID != nil {
                // Explicit launch arguments remain session overrides; default
                // launches retain the saved companion selection and enabled intent.
                engine.setMode(options.modeWasSpecified ? options.mode : engine.mode, profileID: options.profileID)
            }
            try engine.start()
            if options.menuBar {
                menuBar = MenuBarController(command: { [weak self] request in
                    guard let self else { return ControllerReply(error: "Controller shutting down") }
                    return await self.execute(request)
                }, guiCommand: { [weak self] request in
                    guard let self, !self.shuttingDown else { return GUIReply(error: "Controller shutting down") }
                    do { return GUIReply(status: try await self.gui.command(request.command, profileID: request.profileID)) }
                    catch { return GUIReply(error: error.localizedDescription) }
                }, quit: { [weak self] in Task { await self?.stop(code: EXIT_SUCCESS) } })
                menuBar?.setSetupAndStartup(loginItemManager: LoginItemManager(
                    executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
                    configURL: options.configURL, stateURL: options.stateURL), setup: {
                    [configurationURL = options.configURL, stateURL = options.stateURL] in
                    Application.showSetup(configurationURL: configurationURL, runtimeStateURL: stateURL)
                })
                menuBar?.setSettingsDirectory(options.stateURL.deletingLastPathComponent())
                menuBar?.setDiagnosticsProvider { [weak self] in
                    self?.diagnosticReport() ?? "Controller unavailable."
                }
                menuBar?.setFallbackHandler { [weak self] profileID, preference in
                    guard let self, !self.shuttingDown,
                          self.controllerStatus().selectedProfileID == profileID else {
                        throw SwitcherError.message("Audio profile changed before saving fallback output.")
                    }
                    guard self.fallbackPreferencesError == nil else {
                        throw SwitcherError.message(self.fallbackPreferencesError!)
                    }
                    try self.engine.validateFallbackPreference(preference, profileID: profileID)
                    let previous = self.engine.fallbackPreference(profileID: profileID)
                    if preference.outputSelection == .device,
                       preference.outputUID != previous.outputUID || previous.outputSelection != .device,
                       let uid = preference.outputUID {
                        guard try self.engine.eligibleFallbackOutputs().contains(where: { $0.uid == uid }) else {
                            throw SwitcherError.message("Selected fallback output is no longer available.")
                        }
                    }
                    var preferences = self.engine.fallbackPreferences
                    preferences.profiles[profileID] = preference
                    try self.fallbackPreferencesStore.save(preferences)
                    try self.engine.setFallbackPreference(preference, profileID: profileID)
                    self.publishStatus()
                }
                menuBar?.setAuxHandlers(refresh: { [weak self] in
                    guard let self, self.auxControlsAllowed else { throw SwitcherError.message("DSP is unavailable for Aux refresh.") }
                    try await self.aux.refreshForUser()
                }, volume: { [weak self] id, value, intent in
                    guard let self, self.auxControlsAllowed else { throw SwitcherError.message("DSP is unavailable for Aux level changes.") }
                    try await self.aux.changeVolumeForUser(id: id, db: value, intent: intent)
                }, mute: { [weak self] id, value, intent in
                    guard let self, self.auxControlsAllowed else { throw SwitcherError.message("DSP is unavailable for Aux mute changes.") }
                    try await self.aux.setMuteForUser(id: id, muted: value, intent: intent)
                }, preferences: { [weak self] preferences in
                    guard let self, !self.shuttingDown else { throw SwitcherError.message("Controller shutting down") }
                    try self.aux.setPreferences(preferences)
                })
                menuBar?.setAuxPreciseHandlers(prepare: { [weak self] id, value in
                    guard let self, self.auxControlsAllowed else { throw SwitcherError.message("DSP is unavailable for precise Aux values.") }
                    return try await self.aux.prepareVolumeChange(id: id, db: value)
                }, apply: { [weak self] proposal, intent in
                    guard let self, self.auxControlsAllowed, self.aux.snapshot.profileID == proposal.profileID else {
                        throw SwitcherError.message("Aux profile or DSP availability changed before confirmation.")
                    }
                    return try await self.aux.applyVolumeChange(proposal: proposal, intent: intent)
                })
                menuBar?.setUIPreferences(uiPreferences, error: uiPreferencesError) { [weak self] preferences in
                    guard let self, !self.shuttingDown else { throw SwitcherError.message("Controller shutting down") }
                    guard !self.presets.snapshot.busy || preferences.presetsFolderPath == self.uiPreferences.presetsFolderPath else {
                        throw SwitcherError.message("Wait for the preset command before changing its folder.")
                    }
                    var preferences = preferences
                    // These fields are command intent, not Settings drafts. Keep
                    // their authoritative values when another UI preference saves.
                    preferences.companionDSPMode = self.uiPreferences.companionDSPMode
                    preferences.companionProfileID = self.uiPreferences.companionProfileID
                    if !preferences.automaticSwitching, preferences.companionProfileID == nil {
                        preferences.companionProfileID = self.controllerStatus().selectedProfileID
                            ?? (self.configuration.profiles.count == 1 ? self.configuration.profiles.first?.id : nil)
                        // First entry preserves the current enabled/disabled intent.
                        // Later entries restore the independent saved companion intent.
                        if self.uiPreferences.automaticSwitching { preferences.companionDSPMode = self.engine.mode }
                    }
                    if let id = preferences.companionProfileID,
                       !self.configuration.profiles.contains(where: { $0.id == id }) {
                        throw SwitcherError.message("Choose a configured companion profile.")
                    }
                    do { try self.uiPreferencesStore.save(preferences) }
                    catch { self.uiPreferencesError = error.localizedDescription; log("Could not save Settings: " + error.localizedDescription); throw error }
                    self.uiPreferences = preferences; self.uiPreferencesError = nil
                    try self.engine.setAutomaticSwitching(preferences.automaticSwitching,
                        companionMode: preferences.companionDSPMode, profileID: preferences.companionProfileID)
                    self.hud.setSilentMode(preferences.silentMode)
                    self.publishStatus()
                    let silent = preferences.silentMode ? "on" : "off"
                    let metering = preferences.liveLevels ? "on" : "off"
                    let colors = preferences.keepActiveColors ? "on" : "off"
                    log("Settings: Silent Mode \(silent); Live Metering \(metering); Keep Active Colors \(colors)")
                }
                menuBar?.setAuxDragHandlers(begin: { [weak self] id, profile, intent in
                    guard let self, self.auxControlsAllowed, self.aux.snapshot.profileID == profile else { return false }
                    return self.aux.beginVolumeDrag(id: id, intent: intent)
                }, update: { [weak self] id, value, profile in
                    guard let self, self.auxControlsAllowed, self.aux.snapshot.profileID == profile else {
                        self?.aux.cancelVolumeDrag(); return
                    }
                    self.aux.updateVolumeDrag(id: id, db: value)
                }, end: { [weak self] id, value, profile in
                    guard let self, self.auxControlsAllowed, self.aux.snapshot.profileID == profile else {
                        self?.aux.cancelVolumeDrag(); return
                    }
                    self.aux.endVolumeDrag(id: id, db: value)
                }, cancel: { [weak self] in self?.aux.cancelVolumeDrag() })
                publishStatus()
            }
            let server = GUICommandServer(stateURL: options.stateURL, controllerHandler: { [weak self] request in
                guard let self else { return ControllerReply(error: "Controller shutting down") }
                return await self.execute(request)
            }) { [weak self] request in
                guard let self, !self.shuttingDown else { return GUIReply(error: "Controller shutting down") }
                do { return GUIReply(status: try await self.gui.command(request.command, profileID: request.profileID)) }
                catch { return GUIReply(error: error.localizedDescription) }
            }
            try server.start(); commandServer = server
            if panelRequested { showPanel() }
            log("Controller started. Enter status, profiles, auto [ID], on ID, off, retry, resume, release, reconnect [ID], gui start|stop|auto|retry|status --profile ID, or quit. Controls also work from another terminal.")
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor in self?.receive(data) }
            }
        } catch {
            writeError(error.localizedDescription)
            await stop(code: EXIT_FAILURE)
        }
    }

    func showPanel() {
        panelRequested = menuBar == nil
        menuBar?.show()
    }

    private func receive(_ data: Data) {
        guard !shuttingDown else { return }
        inputBuffer.append(data)
        while let newline = inputBuffer.firstIndex(of: 10) {
            let line = String(decoding: inputBuffer[..<newline], as: UTF8.self)
            inputBuffer.removeSubrange(...newline)
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let command = words.first else { continue }
            if command == "gui" {
                do {
                    let request = try GUIArguments(Array(words.dropFirst())).request
                    Task {
                        do { try printGUIReply(GUIReply(status: try await gui.command(request.command, profileID: request.profileID)), command: request.command) }
                        catch { writeError(error.localizedDescription) }
                    }
                } catch { writeError(error.localizedDescription) }
                continue
            }
            if command == "quit", words.count == 1 { Task { await stop(code: EXIT_SUCCESS) }; continue }
            if command == "preset" || command == "presets" {
                do {
                    let request = try ControllerArguments(command: command, arguments: Array(words.dropFirst())).request
                    Task { do { try printControllerReply(await self.execute(request)) } catch { writeError(error.localizedDescription) } }
                } catch { writeError(error.localizedDescription) }
                continue
            }
            guard let choice = ControllerCommand(rawValue: command), words.count <= 2 else {
                log("Invalid command. Use status, profiles, auto [ID], on ID, off, retry, resume, release, reconnect [ID], quit."); continue
            }
            let request = ControllerRequest(command: choice, profileID: words.count == 2 ? words[1] : nil)
            Task { do { try printControllerReply(await self.execute(request)) } catch { writeError(error.localizedDescription) } }
        }
        if inputBuffer.count > 8192 { inputBuffer.removeAll(); log("Discarded oversized input line.") }
    }

    private func setDSPMode(_ mode: AutomationMode, profileID: String?) throws {
        if let profileID, !configuration.profiles.contains(where: { $0.id == profileID }) {
            throw SwitcherError.message("Unknown profile: \(profileID)")
        }
        if !engine.automaticSwitching {
            var preferences = uiPreferences
            preferences.companionDSPMode = mode
            preferences.companionProfileID = profileID ?? engine.selectedID
            try uiPreferencesStore.save(preferences)
            uiPreferences = preferences
        }
        engine.setMode(mode, profileID: profileID)
    }

    private func controllerStatus() -> ControllerStatus {
        let snapshot = latestSnapshot
        let activeID: String?
        switch engine.state { case .active(let id), .starting(let id), .stopping(let id): activeID = id; default: activeID = nil }
        let selected = engine.selectedID ?? activeID
        let entries = configuration.profiles.map { profile in
            let outputs = Set(snapshot?.devices.filter(\.hasOutput).map(\.uid) ?? [])
            let available = outputs.contains(profile.captureUID) && outputs.contains(profile.playbackUID)
            let reason: String?
            let installation: GUIInstallationState
            if let config = profile.gui {
                let present = FileManager.default.isExecutableFile(atPath: config.executablePath)
                    && FileManager.default.isReadableFile(atPath: config.configPath)
                installation = present ? .configured : .notFound
                reason = present ? nil : "CamillaGUI executable or configuration not found. Check its setup location."
            } else {
                installation = confirmedGUIAbsentProfiles.contains(profile.id) ? .uninstalled : .notConfigured
                reason = installation == .uninstalled ? "CamillaGUI is not installed." : "CamillaGUI is not configured."
            }
            return ControllerProfile(id: profile.id, name: profile.name, available: available,
                                     guiUnavailableReason: reason, gui: try? gui.status(profileID: profile.id),
                                     captureUID: profile.captureUID, guiInstallationState: installation)
        }
        // Active lifecycle state follows finite configuration/readiness verification.
        // Resolve its playback UID from the existing event snapshot, without a poll.
        let playbackProfile: Profile?
        if case .active(let id) = engine.state, engine.permitsDSPControls(profileID: id) {
            playbackProfile = configuration.profiles.first { $0.id == id }
        } else { playbackProfile = nil }
        let playbackDevice = snapshot?.devices.first { $0.uid == playbackProfile?.playbackUID && $0.hasOutput }
        return ControllerStatus(mode: engine.mode.rawValue, selectedProfileID: selected,
            dspState: String(describing: engine.state), outputName: snapshot?.devices.first { $0.uid == snapshot?.outputUID }?.name,
            outputUID: snapshot?.outputUID, suspended: engine.suspended, profiles: entries, released: engine.released, recovering: engine.recovering,
            routingRestoring: engine.routingRestoring, routingError: engine.routingError,
            dspPlaybackUID: playbackDevice?.uid, dspPlaybackName: playbackDevice?.name,
            automaticSwitching: engine.automaticSwitching)
    }
    private var auxControlsAllowed: Bool {
        guard !shuttingDown, let id = aux.snapshot.profileID else { return false }
        return engine.permitsDSPControls(profileID: id)
    }
    private func publishStatus() {
        let status = controllerStatus()
        let presentation = MenuBarPresentation(mode: engine.mode, state: engine.state, preferredProfileID: engine.selectedID,
            outputName: status.outputName, suspended: engine.suspended, released: engine.released, recovering: engine.recovering, profiles: status.profiles,
            outputUID: status.outputUID, routingRestoring: engine.routingRestoring, routingError: engine.routingError,
            dspPlaybackUID: status.dspPlaybackUID, dspPlaybackName: status.dspPlaybackName,
            reconfiguringAudio: engine.processingReconfiguration, automaticSwitching: engine.automaticSwitching)
        menuBar?.update(presentation)
        let captureUIDs = Set(configuration.profiles.map(\.captureUID))
        let fallbackDevices = latestSnapshot?.devices.filter { $0.hasOutput && !captureUIDs.contains($0.uid) } ?? []
        let automaticOutput = presentation.selectedProfileID.flatMap { id in
            latestSnapshot.flatMap { engine.suggestedAutomaticFallbackOutput(profileID: id, snapshot: $0) }
        }
        menuBar?.updateFallback(profileID: presentation.selectedProfileID,
            preference: presentation.selectedProfileID.map { engine.fallbackPreference(profileID: $0) } ?? .init(),
            devices: fallbackDevices, automaticOutput: automaticOutput, error: fallbackPreferencesError)
        if !engine.dspControlBusy {
            let profile = configuration.profiles.first { $0.id == presentation.selectedProfileID }
            let ready = profile.map { engine.permitsDSPControls(profileID: $0.id) && presentation.selectedProfile?.available == true } ?? false
            presets.activate(profile: profile, ready: ready, folderPath: uiPreferences.presetsFolderPath)
        }
        if menuBar != nil {
            let profile = configuration.profiles.first { $0.id == presentation.selectedProfileID }
            let ready = profile.map { engine.permitsDSPControls(profileID: $0.id) && presentation.selectedProfile?.available == true } ?? false
            let becameReady = ready && (!auxTargetReady || auxTargetID != profile?.id)
            auxTargetID = profile?.id; auxTargetReady = ready
            menuBar?.updateSignalTarget(profile: profile, ready: ready)
            aux.activate(profile: profile, ready: ready)
            menuBar?.updateAux(aux.snapshot)
            if becameReady, menuBar?.isShown == true {
                Task { [weak self] in await self?.aux.refresh() }
            }
        }
    }

    private func recordDSPTiming(_ state: RuntimeState) {
        switch state {
        case .starting(let id): timings.begin("dsp", label: "DSP startup (\(id))")
        case .stopping(let id): timings.begin("dsp", label: "DSP shutdown (\(id))")
        case .active: timings.finish("dsp", outcome: "ready")
        case .failed: timings.finish("dsp", outcome: "failed")
        case .idle, .suspended, .needsSelection: timings.finish("dsp", outcome: "settled")
        }
    }

    private func recordControlTiming() {
        if engine.routingRestoring {
            timings.begin("routing", label: engine.released ? "Restore output" : "Resume routing")
        } else {
            timings.finish("routing", outcome: engine.routingError == nil ? (engine.released ? "direct" : "settled") : "failed")
        }
        if engine.recovering && !wasRecovering { timings.begin("recovery", label: "DSP recovery") }
        if !engine.recovering && wasRecovering { timings.finish("recovery", outcome: "ended") }
        wasRecovering = engine.recovering
    }

    private func recordGUITiming(_ status: GUIStatus) {
        let key = "gui:" + status.profileID
        switch status.observed {
        case .starting: timings.begin(key, label: "GUI startup (\(status.profileID))")
        case .stopping: timings.begin(key, label: "GUI shutdown (\(status.profileID))")
        case .running: timings.finish(key, outcome: "ready")
        case .stopped: timings.finish(key, outcome: "stopped")
        case .failed: timings.finish(key, outcome: "failed")
        }
    }

    private func diagnosticReport() -> String {
        let status = controllerStatus()
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        var lines = ["\(ApplicationMetadata.name) \(ApplicationMetadata.version) (\(ApplicationMetadata.buildIdentifier))",
                     ApplicationMetadata.copyright, ProcessInfo.processInfo.operatingSystemVersionString,
                     "Architecture: \(architecture)", "", "DSP: \(status.dspState)",
                     "Policy: \(status.mode); Automatic Switching: \(engine.automaticSwitching)", "Selected profile: \(status.selectedProfileID ?? "automatic")",
                     "Routing bypassed: \(engine.released); restoring: \(engine.routingRestoring); suspended: \(engine.suspended)",
                     "Recovering: \(engine.recovering)", "System Output: \(status.outputName ?? "Unavailable") [\(status.outputUID ?? "none")]",
                     "Config: \(options.configURL.path)", "Runtime state: \(options.stateURL.path)",
                     "Silent Mode: \(uiPreferences.silentMode)", "Keep Active Colors: \(uiPreferences.keepActiveColors)", "Follow macOS Output: \(uiPreferences.followMacOSOutput)", "Live Metering enabled: \(uiPreferences.liveLevels) (reads only with the menu open)",
                     "Meter peak hold: \(uiPreferences.meterOptions.peakHoldMilliseconds) ms; falloff: \(uiPreferences.meterOptions.falloffDBPerSecond) dB/s; target: \(uiPreferences.meterOptions.refreshHz) Hz",
                     "Meter display range: \(uiPreferences.meterOptions.minimumDB) to \(uiPreferences.meterOptions.maximumDB) dBFS; numeric modes Realtime / unlimited Peak Hold",
                     "DSP Output: \(status.dspPlaybackName ?? "Unavailable") [\(status.dspPlaybackUID ?? "none")]"]
        if let error = uiPreferencesError { lines.append("Settings error: " + error) }
        let mainRange = uiPreferences.mainSliderRange(profileID: status.selectedProfileID)
        lines.append("Main slider travel: \(mainRange.minimumDB) to \(mainRange.maximumDB) dB (constrained by DSP limits)")
        if let error = engine.routingError { lines.append("Routing error: " + error) }
        if let error = lastCommandError { lines.append("Last command error: " + error) }
        lines.append("Presets folder: " + (uiPreferences.presetsFolderPath ?? "not selected"))
        lines.append("Preset: \(presets.snapshot.activeTitle ?? "unknown"); path \(presets.snapshot.activePath ?? "external or unknown"); verified \(presets.snapshot.ready); busy \(presets.snapshot.busy)")
        if let error = presets.snapshot.error { lines.append("Preset error: " + error) }
        for profile in status.profiles {
            lines += ["", "Profile: \(profile.name) [\(profile.id)]; devices \(profile.available ? "available" : "unavailable")"]
            if let configuration = configuration.profiles.first(where: { $0.id == profile.id }) {
                lines.append("DSP endpoint: " + configuration.websocketURL)
            }
            if let gui = profile.gui {
                lines.append("GUI: \(gui.observed.rawValue); policy \(gui.policy.rawValue); desired \(gui.desiredRunning ? "running" : "stopped")")
                lines.append("GUI endpoint: " + gui.url)
                if let error = gui.lastError { lines.append("GUI error: " + error) }
            }
            if let reason = profile.guiUnavailableReason { lines.append(reason) }
        }
        let auxState = aux.snapshot
        if let main = auxState.main {
            lines.append("Main Volume: \(String(format: "%.1f", main.volumeDB)) dB; muted \(main.muted); maximum \(String(format: "%.1f", main.maximumDB)) dB; values verified \(auxState.ready)")
        } else { lines.append("Main Volume: unavailable") }
        lines += ["", "Aux profile: \(auxState.profileID ?? "none"); ready \(auxState.ready); busy \(auxState.busy)",
                  "Visible Aux: \(auxState.preferences.visibleIDs.map(String.init).joined(separator: ", "))",
                  "Level groups: \(auxState.preferences.linkGroups); linked mute \(auxState.preferences.linkMutes)",
                  "Aux slider minimum: \(auxState.preferences.sliderMinimumDB) dB"]
        for fader in auxState.faders {
            lines.append("Aux \(fader.id) (\(fader.name)): \(String(format: "%.1f", fader.volumeDB)) dB; muted \(fader.muted); limit \(String(format: "%.1f", fader.maximumDB)) dB")
        }
        if let error = auxState.error { lines.append("Aux error: " + error) }
        if let duration = aux.lastDragTransactionDuration {
            lines.append("Last live Aux transaction: \(String(format: "%.3f", duration)) s (read/write/read, excluding spacing)")
        }
        lines += ["", "Session transition timings", timings.diagnosticText]
        return lines.joined(separator: "\n")
    }

    private func execute(_ request: ControllerRequest) async -> ControllerReply {
        guard !shuttingDown else { return ControllerReply(error: "Controller shutting down") }
        // Opening the panel is a presentation-only request. Do not clear a
        // surfaced error or alter the retained DSP policy when reopening the app.
        if request.command == .show {
            guard request.profileID == nil, request.presetPath == nil, request.presetImpact == nil else {
                return ControllerReply(error: "show takes no profile or preset")
            }
            guard let menuBar else { return ControllerReply(error: "This controller has no menu panel.") }
            menuBar.show()
            return ControllerReply(status: controllerStatus())
        }
        do {
            if let id = request.profileID, !configuration.profiles.contains(where: { $0.id == id }) {
                throw SwitcherError.message("Unknown profile: " + id)
            }
            if request.command == .preset || request.command == .presets {
                guard let id = request.profileID ?? controllerStatus().selectedProfileID,
                      let profile = configuration.profiles.first(where: { $0.id == id }),
                      engine.permitsDSPControls(profileID: id) else {
                    throw SwitcherError.message("Presets require a ready DSP profile and no active DSP change.")
                }
                presets.activate(profile: profile, ready: true, folderPath: uiPreferences.presetsFolderPath)
                if request.command == .presets {
                    guard request.presetPath == nil && request.presetImpact == nil else { throw SwitcherError.message("presets takes no file or impact") }
                    try await presets.refreshForUser()
                    guard engine.permitsDSPControls(profileID: id) else { throw CancellationError() }
                } else {
                    guard let path = request.presetPath else { throw SwitcherError.message("preset requires --file PATH") }
                    // CLI requests classify once before mutation. Menu requests
                    // carry the impact displayed to the user and may not silently
                    // acquire a different restart implication.
                    // CamillaGUI may have changed the configuration since the
                    // popup opened. Reclassify this explicit request against a
                    // fresh read before acquiring mutation authority.
                    try await presets.refreshForUser()
                    guard engine.permitsDSPControls(profileID: id) else { throw CancellationError() }
                    let impact = try presets.selectionImpact(path: path)
                    guard request.presetImpact == nil || request.presetImpact == impact else {
                        throw SwitcherError.message("Preset settings changed since the menu was read. Reopen presets and select again.")
                    }
                    log("Preset requested: " + path + (impact.requiresAudioRestart ? "; restarting audio; " + impact.settingChanges.joined(separator: "; ") : "; compatible audio settings"))
                    try await engine.performDSPControl(profileID: id, allowsProcessingRestart: impact.requiresAudioRestart) { [self] in
                        await aux.drainForDSPChange()
                        try Task.checkCancellation()
                        try await presets.selectForUser(path: path)
                    }
                    guard engine.permitsDSPControls(profileID: id) else { throw CancellationError() }
                    // The lease publishes readiness again before returning.
                    // Re-read assignments and limits, never replay old fader values.
                    if auxControlsAllowed { try await aux.refreshForUser() }
                    log("Preset activated: " + path)
                }
                lastCommandError = nil
                publishStatus()
                return ControllerReply(status: controllerStatus(), presets: presets.snapshot)
            }
            guard request.presetPath == nil && request.presetImpact == nil else { throw SwitcherError.message("Only preset accepts a file or impact") }
            switch request.command {
            case .status, .profiles, .show:
                guard request.profileID == nil else { throw SwitcherError.message("status/profiles takes no profile") }
            case .auto: try setDSPMode(.automatic, profileID: request.profileID)
            case .on:
                guard let id = request.profileID else { throw SwitcherError.message("on requires --profile ID") }
                try setDSPMode(.forceOn, profileID: id)
            case .off: try setDSPMode(.forceOff, profileID: request.profileID)
            case .resume:
                guard request.profileID == nil else { throw SwitcherError.message("resume takes no profile") }
                try engine.resume()
            case .retry, .release:
                guard request.profileID == nil else { throw SwitcherError.message("retry/release takes no profile") }
                if request.command == .retry { engine.retry() } else { engine.release() }
            case .reconnect:
                guard let id = request.profileID ?? controllerStatus().selectedProfileID else { throw SwitcherError.message("Select a profile before reconnecting") }
                try engine.reconnect(profileID: id)
            case .preset, .presets: break
            }
            lastCommandError = nil
            publishStatus()
            return ControllerReply(status: controllerStatus())
        } catch {
            lastCommandError = error.localizedDescription
            if request.command == .preset || request.command == .presets {
                if let failure = error as? DSPFailure, let id = request.profileID ?? controllerStatus().selectedProfileID {
                    engine.reportDSPFailure(profileID: id, reason: failure.localizedDescription)
                }
                publishStatus()
                if auxControlsAllowed { try? await aux.refreshForUser() }
                let message = String(error.localizedDescription.prefix(2000))
                log("Preset command failed: " + message)
                return ControllerReply(status: controllerStatus(), error: message, presets: presets.snapshot)
            }
            return ControllerReply(error: error.localizedDescription)
        }
    }

    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in await self?.stop(code: EXIT_SUCCESS) } }
            signalSources.append(source)
            source.resume()
        }
    }

    private func stop(code: Int32) async {
        guard !shuttingDown else { return }
        shuttingDown = true
        presets.cancel()
        aux.activate(profile: nil)
        gui.onFeedback = nil; engine.onFeedback = nil; engine.onStateChange = { state in log("State: \(state)") }
        menuBar?.stop(); menuBar = nil
        hud.stop()
        FileHandle.standardInput.readabilityHandler = nil
        commandServer?.stop(); commandServer = nil
        // Restore audio without waiting behind a failing GUI's cleanup deadline.
        async let guiShutdown: Void = gui.shutdown()
        await engine.shutdown()
        await guiShutdown
        var result = code
        if case .failed(let reason) = engine.state { writeError(reason); result = EXIT_FAILURE }
        instanceLock = nil
        exit(result)
    }

    private func rejectLegacyWatcher() async throws {
        let result = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", "gui/\(getuid())/com.edek.clarett-watcher"])
        if result.status == 0 {
            throw SwitcherError.message("The original clarett-watcher LaunchAgent is loaded. Stop it before running this controller so they cannot change the same audio route.")
        }
        guard result.status == 113, result.stderr.contains("Could not find service") else {
            throw SwitcherError.message("Cannot determine whether the original watcher is loaded: \(result.stderr)")
        }
    }
}

private let loggingOrigin = ProcessInfo.processInfo.systemUptime

private func log(_ message: String) {
    let origin = loggingOrigin
    let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - origin)
    print("[\(ISO8601DateFormatter().string(from: Date())) +\(elapsed)s] \(message)")
    fflush(stdout)
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
}

private struct GUIArguments {
    let request: GUIRequest
    let stateURL: URL
    init(_ arguments: [String]) throws {
        var args = arguments
        guard !args.isEmpty, let command = GUICommand(rawValue: args.removeFirst()) else {
            throw SwitcherError.message("Use gui start|stop|auto|retry|status --profile ID [--state PATH].")
        }
        var profile: String?
        var state: URL?
        var seen = Set<String>()
        while !args.isEmpty {
            let flag = args.removeFirst()
            guard seen.insert(flag).inserted, !args.isEmpty else { throw SwitcherError.message("Missing value or repeated GUI option: \(flag)") }
            let value = args.removeFirst()
            switch flag {
            case "--profile": profile = value
            case "--state": state = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            default: throw SwitcherError.message("Unknown GUI option: \(flag)")
            }
        }
        guard let profile, !profile.isEmpty else { throw SwitcherError.message("gui requires --profile ID") }
        request = GUIRequest(command: command, profileID: profile)
        stateURL = state ?? ApplicationSupportPaths.select(homeDirectory: URL(fileURLWithPath: NSHomeDirectory())).runtimeStateURL
    }
}
private func printGUIReply(_ reply: GUIReply, command: GUICommand) throws {
    if let error = reply.error { throw SwitcherError.message(error) }
    guard let status = reply.status else { throw SwitcherError.message("Invalid GUI command response") }
    print("GUI \(status.profileID): policy=\(status.policy.rawValue) autoStart=\(status.autoStart) desired=\(status.desiredRunning ? "running" : "stopped") observed=\(status.observed.rawValue)")
    print("URL: \(status.url) (\(status.observed == .running ? "HTTP ready" : "not ready"))")
    if let error = status.lastError {
        print("Last error: \(error)")
    }
}

private struct ControllerArguments {
    let request: ControllerRequest
    let stateURL: URL
    init(command: String, arguments: [String]) throws {
        var profile: String?
        var presetPath: String?
        var state: URL?
        var args = arguments.makeIterator(); var seen = Set<String>()
        while let flag = args.next() {
            guard seen.insert(flag).inserted, let value = args.next() else { throw SwitcherError.message("Missing value or repeated option: " + flag) }
            switch flag {
            case "--profile": profile = value
            case "--state": state = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--file": presetPath = (value as NSString).expandingTildeInPath
            default: throw SwitcherError.message("Unknown option: " + flag)
            }
        }
        guard command == "preset" || presetPath == nil else { throw SwitcherError.message("Only preset accepts --file") }
        guard command != "preset" || presetPath != nil else { throw SwitcherError.message("preset requires --file PATH") }
        request = ControllerRequest(command: ControllerCommand(rawValue: command)!, profileID: profile, presetPath: presetPath)
        stateURL = state ?? ApplicationSupportPaths.select(homeDirectory: URL(fileURLWithPath: NSHomeDirectory())).runtimeStateURL
    }
}
private func printControllerReply(_ reply: ControllerReply) throws {
    if let error = reply.error { throw SwitcherError.message(error) }
    guard let status = reply.status else { throw SwitcherError.message("Invalid controller response") }
    if let presets = reply.presets {
        print("Preset: \(presets.activeTitle ?? "External or unknown"); busy=\(presets.busy)")
        for entry in presets.entries {
            let state = !entry.available ? "Unavailable" : entry.requiresAudioRestart ? "Available (restarts audio)" : "Available"
            let details = entry.reason ?? (entry.settingChanges.isEmpty ? nil : entry.settingChanges.joined(separator: "; "))
            print("\(state): \(entry.title) [\(entry.path)]\(details.map { " · " + $0 } ?? "")")
        }
    }
    print("DSP: \(status.dspState); mode=\(status.mode); selected=\(status.selectedProfileID ?? "automatic selection"); suspended=\(status.suspended)")
    print("Output: \(status.outputName ?? "Unavailable") [\(status.outputUID ?? "none")]")
    print("Routing: \(status.automaticSwitching == false ? "companion" : status.routingRestoring == true ? "changing" : status.released == true ? "bypassed" : "managed"); recovering=\(status.recovering == true)")
    if let error = status.routingError { print("Routing error: " + error) }
    for profile in status.profiles {
        print("\(profile.id): \(profile.name); devices=\(profile.available ? "available" : "unavailable")")
        if let gui = profile.gui { print("  GUI policy=\(gui.policy.rawValue) observed=\(gui.observed.rawValue) URL=\(gui.url)") }
        if let reason = profile.guiUnavailableReason { print("  " + reason) }
    }
}

private func menuPreview(_ scenario: String) throws -> MenuBarPresentation {
    guard ["active", "disconnected", "recovering", "failed", "released", "no-gui", "multiple", "aux", "aux-linked", "aux-hidden", "aux-empty"].contains(scenario) else {
        throw SwitcherError.message("Unknown menu preview scenario: " + scenario)
    }
    let gui = scenario == "no-gui" ? nil : GUIStatus(profileID: "demo", policy: .automatic, autoStart: true, desiredRunning: scenario != "disconnected",
        observed: scenario == "disconnected" ? .stopped : scenario == "failed" ? .failed : scenario == "recovering" ? .starting : .running,
        url: "http://localhost:5005", lastError: scenario == "failed" ? "Preview GUI could not become ready" : nil, recovering: scenario == "recovering")
    var profiles = [ControllerProfile(id: "demo", name: "Studio Speakers", available: scenario != "disconnected",
        guiUnavailableReason: scenario == "no-gui" ? "GUI not configured for this profile" : nil, gui: gui, captureUID: "preview-blackhole")]
    if scenario == "multiple" { profiles.append(ControllerProfile(id: "headphones", name: "Headphones", available: true, guiUnavailableReason: "GUI not configured for this profile", gui: nil)) }
    let state: RuntimeState = scenario == "disconnected" ? .idle : scenario == "recovering" ? .starting("demo") : scenario == "failed" ? .failed("Preview DSP recovery exhausted") : .active("demo")
    return MenuBarPresentation(mode: .automatic, state: state, preferredProfileID: "demo", outputName: scenario == "released" || scenario == "disconnected" ? "Mac Speakers" : "BlackHole",
        suspended: false, released: scenario == "released", recovering: scenario == "recovering", profiles: profiles,
        outputUID: scenario == "released" || scenario == "disconnected" ? "preview-speakers" : "preview-blackhole")
}

private func menuAuxPreview(_ scenario: String) -> AuxFaderSnapshot {
    guard scenario.hasPrefix("aux") else { return AuxFaderSnapshot(profileID: "demo") }
    let faders: [AuxFader] = scenario == "aux-empty" ? [] : [
        AuxFader(id: 1, name: "Left", volumeDB: -3, muted: false, maximumDB: 0),
        AuxFader(id: 2, name: "Right", volumeDB: -6, muted: scenario == "aux-linked", maximumDB: 0),
        AuxFader(id: 3, name: "Sub", volumeDB: -9, muted: false, maximumDB: 0)
    ]
    return AuxFaderSnapshot(profileID: "demo", faders: faders,
        preferences: AuxPreferences(visibleIDs: scenario == "aux-hidden" ? [] : faders.map(\.id),
                                    labels: ["1": "Left", "2": "Right", "3": "Sub"],
                                    linkGroups: scenario == "aux-linked" ? [[1, 2]] : []), ready: true)
}
