import AppKit
import Darwin
import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class SetupConflictAudio: AudioManaging {
    var value: AudioSnapshot
    var writes: [String] = []
    init(devices: [AudioDevice]) { value = .init(devices: devices, outputUID: "physical-uid", alertUID: "physical-uid") }
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws { writes.append("output:" + uid); value.outputUID = uid }
    func setAlertOutput(uid: String) throws { writes.append("alert:" + uid); value.alertUID = uid }
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws { }
    func stopMonitoring() { }
}

@MainActor private final class SetupConflictRouteStore: RouteStoring {
    var record: RouteRecord?
    func load() throws -> RouteRecord? { record }
    func save(_ record: RouteRecord?) throws { self.record = record }
}

@MainActor private final class SetupConflictSleeper: TransitionSleeping {
    func sleep(milliseconds: Int) async throws {
        try Task.checkCancellation()
        if milliseconds >= 10_000 { try await Task.sleep(nanoseconds: 60_000_000_000) }
        else { await Task.yield(); try Task.checkCancellation() }
    }
}

@MainActor private func checkSetupRefusedActivationCleanup(profile: Profile, devices: [AudioDevice],
                                                          loadedJob: String, originalJobData: Data) async throws {
    for automaticSwitching in [false, true] {
        let audio = SetupConflictAudio(devices: devices)
        let store = SetupConflictRouteStore()
        var launchCommands: [[String]] = []
        var activationChecks = 0
        let conflictRunner: SetupCommandRunner = { command, arguments in
            if command == "/bin/launchctl" {
                try check(arguments.first == "print", "Setup conflict preflight performs only launchctl inspection")
                return .init(status: 0, stdout: loadedJob, stderr: "")
            }
            try check(command == "/bin/ps", "Setup conflict preflight performs only process inspection")
            return .init(status: 0, stdout: "123 /owned/camilladsp\n456 /external/camilladsp\n", stderr: "")
        }
        let dsp = LaunchdDSPManager(runCommand: { arguments in
            launchCommands.append(arguments)
            return .init(status: 0, stdout: loadedJob, stderr: "")
        }, sleep: { _ in await Task.yield() }, activationCheck: { checkedProfile in
            activationChecks += 1
            try await SetupConfigurationService.checkForConflictingDSP(profile: checkedProfile, commandRunner: conflictRunner)
        })
        let engine = Reconciler(profiles: [profile], audio: audio, dsp: dsp, store: store,
                                sleeper: SetupConflictSleeper(), automaticSwitching: automaticSwitching,
                                companionMode: .forceOn, companionProfileID: profile.id)
        try engine.start()
        for _ in 0..<500 { await Task.yield() }
        guard case .failed = engine.state else {
            await engine.shutdown()
            throw CheckFailure.failed("External DSP conflict did not fail the setup-owned activation")
        }
        try check(activationChecks == 1 && launchCommands.isEmpty,
                  "Reconciler failure cleanup does not stop, bootstrap or kickstart an unadopted setup DSP job")
        engine.retry()
        for _ in 0..<500 { await Task.yield() }
        guard case .failed = engine.state else {
            await engine.shutdown()
            throw CheckFailure.failed("Reattempt bypassed the external DSP activation guard")
        }
        try check(activationChecks == 2 && launchCommands.isEmpty,
                  "An explicit reattempt repeats preflight without mutating either DSP instance")
        await engine.shutdown()
        let finalJobData = try Data(contentsOf: URL(fileURLWithPath: profile.launchAgentPath))
        try check(launchCommands.isEmpty && audio.writes.isEmpty && store.record == nil &&
                    audio.value.outputUID == "physical-uid" && audio.value.alertUID == "physical-uid" && finalJobData == originalJobData,
                  "Conflict cleanup and shutdown preserve job bytes and both macOS outputs in automatic and Companion modes")
    }
}

@MainActor func runSetupChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("camillacompanion-setup-checks-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let binary = root.appendingPathComponent("camilladsp")
    try Data("fixture, never executed".utf8).write(to: binary)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let yaml = root.appendingPathComponent("dsp.yml")
    let yamlBytes = Data("devices:\n  capture:\n    type: CoreAudio\n    device: Virtual\n  playback:\n    type: CoreAudio\n    device: Physical\n".utf8)
    try yamlBytes.write(to: yaml)
    let configuration = root.appendingPathComponent("config.json")
    let state = root.appendingPathComponent("runtime.json")
    let connected = [AudioDevice(uid: "virtual-uid", name: "Virtual", hasOutput: true),
                     AudioDevice(uid: "physical-uid", name: "Physical", hasOutput: true)]
    var commands: [(String, [String])] = []
    let validate: SetupCommandRunner = { executable, arguments in
        commands.append((executable, arguments))
        return ProcessResult(status: 0, stdout: "Configuration is valid", stderr: "")
    }
    var draft = SetupDraft(); draft.executablePath = binary.path; draft.configurationPath = yaml.path
    draft.captureUID = "virtual-uid"; draft.playbackUID = "physical-uid"; draft.confirmedGUIAbsent = true
    let prepared = try await SetupConfigurationService.prepare(draft, configurationURL: configuration, devices: connected, commandRunner: validate)
    try check(commands.count == 1 && commands[0].0 == binary.path && commands[0].1 == ["--check", yaml.path],
              "Review runs only a finite CamillaDSP configuration check")
    try check(prepared.hardwareAvailable && !prepared.preferences.automaticSwitching && prepared.preferences.companionDSPMode == .forceOn,
              "New setup defaults to Companion Mode with retained On intent")
    var switchingDraft = draft; switchingDraft.automaticSwitching = true
    let switchingSetup = try await SetupConfigurationService.prepare(switchingDraft, configurationURL: configuration,
        devices: connected, commandRunner: validate)
    try check(switchingSetup.preferences.automaticSwitching && switchingSetup.summary.contains("Mode: Automatic Switching"),
              "Choosing Automatic Switching is retained and shown in the review before activation")
    try check(!fm.fileExists(atPath: configuration.path) && !fm.fileExists(atPath: state.path),
              "Review creates no configuration, route state, service or preferences")
    let guiBackend = root.appendingPathComponent("camillagui_backend")
    try Data("fixture, never executed".utf8).write(to: guiBackend)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: guiBackend.path)
    let guiConfiguration = root.appendingPathComponent("camillagui.yml")
    let guiYAML = "# Backend YAML\nbind_address: localhost\nport: 8181\ncamilla_host: 127.0.0.1\ncamilla_port: 1234\nssl_certificate: null\nssl_private_key: ~\n"
    let guiJSON = #"{"bind_address":"127.0.0.1","port":8181,"camilla_host":"localhost","camilla_port":1234,"ssl_certificate":null}"#
    var guiDraft = draft
    guiDraft.confirmedGUIAbsent = false
    guiDraft.gui = .init(executablePath: guiBackend.path, configPath: guiConfiguration.path, url: "http://127.0.0.1:8181")
    for (name, document) in [("yaml", guiYAML), ("json", guiJSON)] {
        let bytes = Data(document.utf8)
        try bytes.write(to: guiConfiguration)
        let guiOutput = root.appendingPathComponent("gui-review-" + name + "/config.json")
        let guiState = guiOutput.deletingLastPathComponent().appendingPathComponent("runtime.json")
        let guiPrepared = try await SetupConfigurationService.prepare(guiDraft, configurationURL: guiOutput, devices: connected, commandRunner: validate)
        var published = 0
        try Data((document + "\n# edited after Review\n").utf8).write(to: guiConfiguration)
        do {
            try SetupConfigurationService.save(guiPrepared, configurationURL: guiOutput, runtimeStateURL: guiState, publishFile: { _, _ in published += 1 })
            throw CheckFailure.failed("Setup accepted GUI configuration edited after Review")
        } catch is CheckFailure { throw CheckFailure.failed("Setup accepted GUI configuration edited after Review") }
        catch { try check(error.localizedDescription.contains("changed"), "Changed GUI bytes require another Review") }
        try check(published == 0 && !fm.fileExists(atPath: guiOutput.path), "Changed GUI configuration is rejected before any setup file is published")
        try bytes.write(to: guiConfiguration)
        try SetupConfigurationService.save(guiPrepared, configurationURL: guiOutput, runtimeStateURL: guiState)
        try SetupConfigurationService.validateForActivation(guiPrepared)
        let afterSave = try Data(contentsOf: guiConfiguration)
        try check(afterSave == bytes, "Review and Save Only accept GUI YAML and JSON without editing the external configuration")
        try Data((document + "\n# changed before activation\n").utf8).write(to: guiConfiguration)
        do { try SetupConfigurationService.validateForActivation(guiPrepared); throw CheckFailure.failed("Activation accepted GUI configuration edited after Save") }
        catch is CheckFailure { throw CheckFailure.failed("Activation accepted GUI configuration edited after Save") } catch { }
    }
    for document in ["bind_address: [unclosed", "- one\n- two\n", "null",
                     guiYAML.replacingOccurrences(of: "camilla_port: 1234", with: "camilla_port: 4321"),
                     guiYAML.replacingOccurrences(of: "ssl_certificate: null", with: "ssl_certificate: cert.pem"),
                     guiYAML.replacingOccurrences(of: "port: 8181", with: "port: 8182"),
                     guiYAML + "bind_address: 0.0.0.0\n"] {
        try Data(document.utf8).write(to: guiConfiguration)
        let rejectedOutput = root.appendingPathComponent("gui-rejected/config.json")
        do { _ = try await SetupConfigurationService.prepare(guiDraft, configurationURL: rejectedOutput, devices: connected, commandRunner: validate)
            throw CheckFailure.failed("Setup Review accepted an invalid GUI configuration") }
        catch is CheckFailure { throw CheckFailure.failed("Setup Review accepted an invalid GUI configuration") } catch { }
        try check(!fm.fileExists(atPath: rejectedOutput.deletingLastPathComponent().path), "Invalid GUI Review creates no setup files")
    }
    var invalid = draft; invalid.captureUID = "physical-uid"
    do { _ = try await SetupConfigurationService.prepare(invalid, configurationURL: configuration, devices: connected, commandRunner: validate)
        throw CheckFailure.failed("Mismatched capture device accepted") }
    catch is CheckFailure { throw CheckFailure.failed("Mismatched capture device accepted") } catch { }
    do { _ = try await SetupConfigurationService.prepare(draft, configurationURL: configuration, devices: connected, commandRunner: { _, _ in .init(status: 1, stdout: "", stderr: "bad filters") })
        throw CheckFailure.failed("Invalid CamillaDSP YAML accepted") }
    catch is CheckFailure { throw CheckFailure.failed("Invalid CamillaDSP YAML accepted") } catch { }
    let offline = try await SetupConfigurationService.prepare(draft, configurationURL: configuration, devices: [], commandRunner: validate)
    try check(!offline.hardwareAvailable && offline.summary.contains("disconnected"), "Known offline UIDs can be saved without claiming readiness")
    let importedJob = root.appendingPathComponent("imported.plist")
    var importPlist: [String: Any] = ["Label": "com.example.test-dsp", "ProgramArguments": [binary.path, "-a", "127.0.0.1", "-p", "1234", yaml.path], "RunAtLoad": true]
    try PropertyListSerialization.data(fromPropertyList: importPlist, format: .xml, options: 0).write(to: importedJob)
    var importDraft = draft; importDraft.existingLaunchAgentPath = importedJob.path
    do { _ = try await SetupConfigurationService.prepare(importDraft, configurationURL: configuration, devices: connected, commandRunner: validate)
        throw CheckFailure.failed("Self-starting existing DSP job imported") }
    catch is CheckFailure { throw CheckFailure.failed("Self-starting existing DSP job imported") } catch { }
    importPlist["RunAtLoad"] = false
    try PropertyListSerialization.data(fromPropertyList: importPlist, format: .xml, options: 0).write(to: importedJob)
    let imported = try await SetupConfigurationService.prepare(importDraft, configurationURL: configuration, devices: connected, commandRunner: validate)
    try check(imported.configuration.profiles[0].requiresExclusiveDSP == true && prepared.configuration.profiles[0].requiresExclusiveDSP == true,
              "Generated and imported setup profiles retain conflict protection through saved launches and login")
    try check(imported.configuration.profiles[0].launchAgentPath == importedJob.path,
              "Compatible existing on-demand DSP job is referenced without replacement")
    var conflictCommands: [String] = []
    let missingJob: SetupCommandRunner = { path, _ in
        conflictCommands.append(path)
        if path == "/bin/launchctl" { return .init(status: 113, stdout: "", stderr: "Could not find service") }
        return .init(status: 0, stdout: "123 /usr/local/bin/camilladsp\n", stderr: "")
    }
    do { try await SetupConfigurationService.checkForConflictingDSP(prepared, commandRunner: missingJob)
        throw CheckFailure.failed("External DSP process accepted") }
    catch is CheckFailure { throw CheckFailure.failed("External DSP process accepted") } catch { }
    try check(conflictCommands == ["/bin/launchctl", "/bin/ps"], "Conflict inspection is finite and never stops another DSP")
    let noConflict: SetupCommandRunner = { path, _ in
        path == "/bin/launchctl" ? .init(status: 113, stdout: "", stderr: "Could not find service") : .init(status: 0, stdout: "123 /usr/bin/other\n", stderr: "")
    }
    try await SetupConfigurationService.checkForConflictingDSP(prepared, commandRunner: noConflict)
    let lock = Darwin.open(state.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lock >= 0 else { throw CheckFailure.failed("Cannot create setup lock fixture") }
    flock(lock, LOCK_EX | LOCK_NB)
    do { try SetupConfigurationService.save(prepared, configurationURL: configuration, runtimeStateURL: state)
        throw CheckFailure.failed("Setup wrote while another controller held the lock") }
    catch is CheckFailure { Darwin.close(lock); throw CheckFailure.failed("Setup wrote while another controller held the lock") } catch { }
    flock(lock, LOCK_UN); Darwin.close(lock)
    try check(!fm.fileExists(atPath: configuration.path), "A running controller prevents setup writes")
    var publications = 0
    do { try SetupConfigurationService.save(prepared, configurationURL: configuration, runtimeStateURL: state, publishFile: { data, url in
        publications += 1
        if publications == 2 { throw SwitcherError.message("Injected publication failure") }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
    }); throw CheckFailure.failed("Failed setup transaction succeeded") }
    catch is CheckFailure { throw CheckFailure.failed("Failed setup transaction succeeded") } catch { }
    try check(!fm.fileExists(atPath: prepared.configuration.profiles[0].launchAgentPath) && !fm.fileExists(atPath: configuration.path),
              "Failed publication rolls back files created by setup")
    let reservedState = URL(fileURLWithPath: prepared.configuration.profiles[0].launchAgentPath).deletingLastPathComponent().appendingPathComponent("default-state.yml")
    let existingStateBytes = Data("unrelated existing state".utf8)
    try existingStateBytes.write(to: reservedState)
    do { try SetupConfigurationService.save(prepared, configurationURL: configuration, runtimeStateURL: state)
        throw CheckFailure.failed("Setup accepted pre-existing DSP state") }
    catch is CheckFailure { throw CheckFailure.failed("Setup accepted pre-existing DSP state") } catch { }
    let preservedState = try Data(contentsOf: reservedState)
    try check(preservedState == existingStateBytes && !fm.fileExists(atPath: configuration.path), "Reserved DSP state is never overwritten by setup")
    try fm.removeItem(at: reservedState)
    for priorStateURL in [state, state.appendingPathExtension("aux-preferences.json"), state.appendingPathExtension("fallback-preferences.json")] {
        let priorBytes = Data("prior settings, preserved verbatim".utf8)
        try priorBytes.write(to: priorStateURL)
        do { try SetupConfigurationService.save(prepared, configurationURL: configuration, runtimeStateURL: state)
            throw CheckFailure.failed("Setup adopted pre-existing state or sidecar preferences") }
        catch is CheckFailure { throw CheckFailure.failed("Setup adopted pre-existing state or sidecar preferences") } catch { }
        let afterPriorState = try Data(contentsOf: priorStateURL)
        try check(afterPriorState == priorBytes && !fm.fileExists(atPath: configuration.path),
                  "New setup preserves prior runtime ownership and Aux/fallback preferences without publishing a configuration")
        try fm.removeItem(at: priorStateURL)
    }
    try SetupConfigurationService.save(prepared, configurationURL: configuration, runtimeStateURL: state)
    try SetupConfigurationService.validateForActivation(prepared)
    let loaded = try ConfigurationLoader.load(from: configuration)
    let preferences = try JSONUIPreferencesStore(runtimeStateURL: state).load()
    try check(loaded.profiles == prepared.configuration.profiles && preferences == prepared.preferences,
              "Save Only persists configuration and preferences without activating audio")
    let receipt = try SetupReceipt.load(configurationURL: configuration)
    try check(receipt.confirmedGUIAbsentProfileIDs == ["default"], "Confirmed missing optional GUI is stored separately from GUI policy")
    let jobData = try Data(contentsOf: URL(fileURLWithPath: loaded.profiles[0].launchAgentPath))
    let job = try PropertyListSerialization.propertyList(from: jobData, format: nil) as? [String: Any]
    try check(job?["RunAtLoad"] as? Bool == false && job?["KeepAlive"] as? Bool == false && job?["ProcessType"] as? String == "Interactive",
              "Generated DSP job is on demand and uses the required interactive process type")
    let ownedProfile = loaded.profiles[0]
    let ownedArguments = job?["ProgramArguments"] as? [String] ?? []
    let loadedJobDescription = "path = \(ownedProfile.launchAgentPath)\nprogram = \(binary.path)\narguments = {\n" + ownedArguments.joined(separator: "\n") + "\n}\npid = 123\n"
    try await checkSetupRefusedActivationCleanup(profile: ownedProfile, devices: connected,
                                               loadedJob: loadedJobDescription, originalJobData: jobData)
    var laterActivationCommands: [String] = []
    let ownedRunning: SetupCommandRunner = { command, arguments in
        laterActivationCommands.append(command + " " + arguments.joined(separator: " "))
        return command == "/bin/launchctl" ? .init(status: 0, stdout: loadedJobDescription, stderr: "") : .init(status: 0, stdout: "123 \(binary.path)\n", stderr: "")
    }
    try await SetupConfigurationService.checkForConflictingDSP(profile: ownedProfile, commandRunner: ownedRunning)
    try check(laterActivationCommands.count == 2 && laterActivationCommands[0].contains(" print ") && laterActivationCommands[1] == "/bin/ps -axo pid=,comm=",
              "Later activation adopts only the exact saved job through two bounded read-only inspections")
    let conflictingLater: SetupCommandRunner = { command, _ in
        command == "/bin/launchctl" ? .init(status: 0, stdout: loadedJobDescription, stderr: "") : .init(status: 0, stdout: "123 \(binary.path)\n456 /elsewhere/camilladsp\n", stderr: "")
    }
    do { try await SetupConfigurationService.checkForConflictingDSP(profile: ownedProfile, commandRunner: conflictingLater)
        throw CheckFailure.failed("Later activation accepted a separate running DSP") }
    catch is CheckFailure { throw CheckFailure.failed("Later activation accepted a separate running DSP") } catch { }
    let afterConflictJob = try Data(contentsOf: URL(fileURLWithPath: ownedProfile.launchAgentPath))
    try check(afterConflictJob == jobData, "Conflict rejection after Save Only never mutates the saved job")
    let mismatchedLoaded: SetupCommandRunner = { _, _ in .init(status: 0, stdout: loadedJobDescription.replacingOccurrences(of: "path = \(ownedProfile.launchAgentPath)", with: "path = /other/job.plist"), stderr: "") }
    do { try await SetupConfigurationService.checkForConflictingDSP(profile: ownedProfile, commandRunner: mismatchedLoaded)
        throw CheckFailure.failed("Later activation accepted a mismatched loaded job") }
    catch is CheckFailure { throw CheckFailure.failed("Later activation accepted a mismatched loaded job") } catch { }
    let savedJobURL = URL(fileURLWithPath: loaded.profiles[0].launchAgentPath)
    try Data("changed after Save Only".utf8).write(to: savedJobURL)
    do { try SetupConfigurationService.validateForActivation(prepared); throw CheckFailure.failed("Changed saved job accepted for activation") }
    catch is CheckFailure { throw CheckFailure.failed("Changed saved job accepted for activation") } catch { }
    try jobData.write(to: savedJobURL)
    try Data("changed YAML after Save Only".utf8).write(to: yaml)
    do { try SetupConfigurationService.validateForActivation(prepared); throw CheckFailure.failed("Changed YAML accepted for activation") }
    catch is CheckFailure { throw CheckFailure.failed("Changed YAML accepted for activation") } catch { }
    try yamlBytes.write(to: yaml)
    let savedBytes = try Data(contentsOf: configuration)
    do { try SetupConfigurationService.save(prepared, configurationURL: configuration, runtimeStateURL: state)
        throw CheckFailure.failed("Existing configuration overwritten") }
    catch is CheckFailure { throw CheckFailure.failed("Existing configuration overwritten") } catch { }
    let afterConfiguration = try Data(contentsOf: configuration)
    let afterYAML = try Data(contentsOf: yaml)
    try check(afterConfiguration == savedBytes && afterYAML == yamlBytes,
              "Existing setup and original YAML remain unchanged")
    var activationCalls = 0
    let window = SetupWindowController(configurationURL: configuration, runtimeStateURL: state, devices: { connected }, onActivate: { _ in activationCalls += 1 })
    try check(window.window?.title == "Set Up CamillaCompanion" && activationCalls == 0,
              "Opening existing setup shows a read-only summary without activation")
    window.close()
}
