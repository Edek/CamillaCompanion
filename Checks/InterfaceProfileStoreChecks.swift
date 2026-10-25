import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runInterfaceProfileStoreChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("interface-profile-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let binary = root.appendingPathComponent("camilladsp")
    try Data("fixture".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let yaml = root.appendingPathComponent("interface.yml")
    let yamlBytes = Data("devices:\n  capture:\n    type: CoreAudio\n    channels: 2\n    device: capture\n  playback:\n    type: CoreAudio\n    channels: 2\n    device: playback\n".utf8)
    try yamlBytes.write(to: yaml)

    let jobURL = root.appendingPathComponent("legacy.plist")
    let job: [String: Any] = ["Label": "legacy.dsp", "ProgramArguments": [binary.path, "-a", "127.0.0.1", "-p", "1234", yaml.path]]
    try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: jobURL)
    let gui = GUIConfiguration(executablePath: "/Applications/CamillaGUI", configPath: "/tmp/gui.yml",
                               url: "http://127.0.0.1:5001")
    let first = Profile(id: "first", name: "First", triggerUID: "virtual", captureUID: "capture",
        playbackUID: "playback", launchAgentLabel: "legacy.dsp", launchAgentPath: jobURL.path,
        websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback", gui: gui)
    let secondURL = root.appendingPathComponent("second.plist")
    let secondState = root.appendingPathComponent("second-state/state.yml")
    try FileManager.default.createDirectory(at: secondState.deletingLastPathComponent(), withIntermediateDirectories: true)
    let secondStateBytes = Data("config_path: \(yaml.path)\nmute: [false, false]\nvolume: [0, 0]\n".utf8)
    try secondStateBytes.write(to: secondState)
    let secondJob: [String: Any] = ["Label": "second.dsp", "ProgramArguments": [binary.path, "-s", secondState.path,
        "-a127.0.0.1", "-p2234", "-o", root.appendingPathComponent("second.log").path,
        "--log_rotate_size", "2000000", "--log_keep_nbr", "3"],
        "WorkingDirectory": root.path, "RunAtLoad": true, "KeepAlive": true]
    try PropertyListSerialization.data(fromPropertyList: secondJob, format: .xml, options: 0).write(to: secondURL)
    let second = Profile(id: "second", name: "Second", triggerUID: "virtual", captureUID: "capture",
        playbackUID: "playback", launchAgentLabel: "second.dsp", launchAgentPath: secondURL.path,
        websocketURL: "ws://127.0.0.1:2234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback",
        autoActivate: false)
    let configURL = root.appendingPathComponent("config.json")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("DSPJobs"), withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var configRaw = try JSONSerialization.jsonObject(with: encoder.encode(Configuration(profiles: [first, second]))) as! [String: Any]
    configRaw["unrelatedSetting"] = ["keep": true]
    var rawProfiles = configRaw["profiles"] as! [[String: Any]]
    rawProfiles[0]["unknownAutomationField"] = ["keep": "exactly"]
    configRaw["profiles"] = rawProfiles
    try JSONSerialization.data(withJSONObject: configRaw).write(to: configURL)

    var calls = 0
    var validatedPaths: [String] = []
    let runner: InterfaceProfileStore.CommandRunner = { executable, arguments in
        calls += 1
        try check(executable == binary.path && arguments.count == 2 && arguments.first == "--check",
                  "store validates YAML with the selected DSP executable")
        validatedPaths.append(arguments[1])
        return ProcessResult(status: 0, stdout: "", stderr: "")
    }
    let devices = [AudioDevice(uid: "virtual", name: "Virtual", inputChannels: 0, outputChannels: 2),
                   AudioDevice(uid: "capture", name: "Capture", inputChannels: 2, outputChannels: 2),
                   AudioDevice(uid: "playback", name: "Playback", inputChannels: 0, outputChannels: 2),
                   AudioDevice(uid: "input-only", name: "Input only", inputChannels: 1, outputChannels: 0),
                   AudioDevice(uid: "duplex", name: "Duplex", inputChannels: 2, outputChannels: 2)]
    let store = InterfaceProfileStore(configurationURL: configURL, commandRunner: runner)
    let state = try store.snapshot(devices: devices, activeProfileID: "first")
    try check(state.profiles.count == 2 && state.activeProfileID == "first" && state.profiles[0].configurationPath == yaml.path,
              "snapshot reads interface settings and current profile identity")
    try check(state.profiles[1].configurationPath == yaml.path && state.profiles[1].websocketPort == 2234 && state.profileIssues.isEmpty,
              "state-backed auto-start job exposes its exact YAML and port while accepting logging arguments")
    try check(state.profiles[1].loadedConfigurationPath == yaml.path,
              "state-backed editor draft retains a non-persisted YAML reference for stale-editor checks")
    func expectUnsupportedJob(_ url: URL, label: String, message: String) throws {
        do { _ = try DSPJobConfiguration.read(path: url.path, configuredLabel: label); throw CheckFailure.failed(message) }
        catch is CheckFailure { throw CheckFailure.failed(message) }
        catch { }
    }
    func writeJob(_ url: URL, label: String, arguments: [String], workingDirectory: Any? = nil) throws {
        var plist: [String: Any] = ["Label": label, "ProgramArguments": arguments]
        if let workingDirectory { plist["WorkingDirectory"] = workingDirectory }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }
    let relativeYAMLJob = root.appendingPathComponent("relative-yaml.plist")
    try writeJob(relativeYAMLJob, label: "relative.yaml", arguments: [binary.path, "-a", "127.0.0.1", "-p", "2240", "relative.yml"])
    try expectUnsupportedJob(relativeYAMLJob, label: "relative.yaml", message: "relative YAML without WorkingDirectory was guessed")
    let relativeStateJob = root.appendingPathComponent("relative-state.plist")
    try writeJob(relativeStateJob, label: "relative.state", arguments: [binary.path, "-s", "state.yml", "-a", "127.0.0.1", "-p", "2241"])
    try expectUnsupportedJob(relativeStateJob, label: "relative.state", message: "relative state path without WorkingDirectory was guessed")
    let relativeStateConfig = root.appendingPathComponent("relative-config-state.yml")
    try Data("config_path: relative.yml\n".utf8).write(to: relativeStateConfig)
    let relativeConfigJob = root.appendingPathComponent("relative-config.plist")
    try writeJob(relativeConfigJob, label: "relative.config", arguments: [binary.path, "-s", relativeStateConfig.path,
        "-a", "127.0.0.1", "-p", "2242"])
    try expectUnsupportedJob(relativeConfigJob, label: "relative.config", message: "relative state config_path without WorkingDirectory was guessed")
    let relativeWorkingJob = root.appendingPathComponent("relative-working.plist")
    try writeJob(relativeWorkingJob, label: "relative.working", arguments: [binary.path, "-a", "127.0.0.1", "-p", "2243", yaml.path],
        workingDirectory: "relative-directory")
    try expectUnsupportedJob(relativeWorkingJob, label: "relative.working", message: "relative LaunchAgent WorkingDirectory was accepted")
    let rootedState = root.appendingPathComponent("rooted-state.yml")
    try Data("config_path: interface.yml\n".utf8).write(to: rootedState)
    let rootedJob = root.appendingPathComponent("rooted-relative.plist")
    try writeJob(rootedJob, label: "rooted.relative", arguments: [binary.path, "-s", "rooted-state.yml",
        "-a", "127.0.0.1", "-p", "2244"], workingDirectory: root.path)
    let rootedDetails = try DSPJobConfiguration.read(path: rootedJob.path, configuredLabel: "rooted.relative")
    try check(rootedDetails.configurationPath == yaml.path, "relative state and YAML paths resolve only from explicit absolute WorkingDirectory")
    let presetB = root.appendingPathComponent("preset-b.yml")
    try yamlBytes.write(to: presetB)
    let explicitState = root.appendingPathComponent("explicit-state.yml")
    try Data("config_path: \(presetB.path)\nmute: [false, false]\nvolume: [0, 0]\n".utf8).write(to: explicitState)
    let explicitJob = root.appendingPathComponent("explicit-config.plist")
    try writeJob(explicitJob, label: "explicit.config", arguments: [binary.path, "-s", explicitState.path,
        "-a", "127.0.0.1", "-p", "2245", yaml.path])
    let explicitDetails = try DSPJobConfiguration.read(path: explicitJob.path, configuredLabel: "explicit.config")
    try check(explicitDetails.configurationPath == yaml.path,
              "explicit YAML argument wins over a different state-file preset at startup")
    try Data("config_path: /tmp/other-preset.yml\nmute: [true, false]\nvolume: [-10, 0]\n".utf8).write(to: explicitState)
    try explicitDetails.verifyStateConfigurationReference()
    let originalJobBytes = try Data(contentsOf: jobURL)
    let originalYAMLBytes = try Data(contentsOf: yaml)
    var wrongUID = state.profiles[0]; wrongUID.captureUID = "other"; wrongUID.managedFeedUID = "other"
    let devicesWithOther = devices + [AudioDevice(uid: "other", name: "Other", hasOutput: true)]
    do { _ = try await store.save(wrongUID, devices: devicesWithOther); throw CheckFailure.failed("wrong connected UID was accepted") }
    catch is CheckFailure { throw CheckFailure.failed("wrong connected UID was accepted") }
    catch { }

    let namedYAML = root.appendingPathComponent("named.yml")
    try Data("devices:\n  capture:\n    type: CoreAudio\n    channels: 2\n    device: Capture\n  playback:\n    type: CoreAudio\n    channels: 2\n    device: Playback\n".utf8).write(to: namedYAML)
    let duplicateName = InterfaceProfileDraft(name: "Duplicate", executablePath: binary.path,
        configurationPath: namedYAML.path, triggerUID: "virtual", captureUID: "capture", playbackUID: "playback",
        websocketPort: 3334, autoActivate: false)
    let duplicateDevices = devices + [AudioDevice(uid: "capture2", name: "Capture", inputChannels: 2, outputChannels: 0)]
    do { _ = try await store.save(duplicateName, devices: duplicateDevices); throw CheckFailure.failed("ambiguous device name was accepted") }
    catch is CheckFailure { throw CheckFailure.failed("ambiguous device name was accepted") }
    catch { }
    try check(calls == 0, "selector failures stop before invoking CamillaDSP validation")
    let duplicateSuggestion = try ProfileDeviceMapping.suggestions(configurationPath: namedYAML.path, devices: duplicateDevices)
    if case .ambiguous = duplicateSuggestion.capture.resolution {} else {
        throw CheckFailure.failed("duplicate YAML device names were treated as an unambiguous direction-specific match")
    }
    let missingYAML = root.appendingPathComponent("missing-device.yml")
    try Data("devices:\n  capture:\n    type: CoreAudio\n    device: Disconnected source\n  playback:\n    type: CoreAudio\n    device: Playback\n".utf8).write(to: missingYAML)
    let missingSuggestion = try ProfileDeviceMapping.suggestions(configurationPath: missingYAML.path, devices: devices)
    if case .missing = missingSuggestion.capture.resolution {} else {
        throw CheckFailure.failed("missing YAML device selector was assigned a connected device")
    }
    let duplicateUIDDevices = devices + [AudioDevice(uid: "capture", name: "Capture alias", inputChannels: 2, outputChannels: 2)]
    let duplicateUIDSuggestion = try ProfileDeviceMapping.suggestions(configurationPath: yaml.path, devices: duplicateUIDDevices)
    if case .ambiguous = duplicateUIDSuggestion.capture.resolution {} else {
        throw CheckFailure.failed("duplicate CoreAudio UIDs were treated as an exact mapping")
    }

    let suggestions = try ProfileDeviceMapping.suggestions(configurationPath: namedYAML.path, devices: devices)
    try check(suggestions.capture.suggestedUID == "capture" && suggestions.playback.suggestedUID == "playback" &&
              suggestions.managedFeed.suggestedUID == "capture",
              "YAML mapping suggestions honor separate input/output capabilities and infer only the matching duplex feed")
    var reviewDraft = state.profiles[0]
    reviewDraft.playbackUID = "duplex"
    try check(ProfileDeviceMapping.review(reviewDraft, suggestions: suggestions, devices: devices)
        .contains(where: { $0.contains("DSP output differs") }), "editor review identifies a device/YAML mismatch before Save")
    try check(ProfileDeviceMapping.savedDSPPaths(profiles: [reviewDraft], activeProfileID: reviewDraft.id)?.executablePath == binary.path,
              "new-profile DSP defaults come from an existing saved executable")
    let shortChannels = root.appendingPathComponent("short-channels.yml")
    try Data("devices:\n  capture:\n    type: CoreAudio\n    channels: 3\n    device: Input only\n  playback:\n    type: CoreAudio\n    device: Playback\n".utf8).write(to: shortChannels)
    let shortSuggestion = try ProfileDeviceMapping.suggestions(configurationPath: shortChannels.path, devices: devices)
    if case .unsupported = shortSuggestion.capture.resolution {} else {
        throw CheckFailure.failed("a YAML channel requirement beyond the selected input capability was suggested")
    }
    let nonCoreAudio = root.appendingPathComponent("network-capture.yml")
    try Data("devices:\n  capture:\n    type: File\n    device: source.wav\n  playback:\n    type: CoreAudio\n    device: Playback\n".utf8).write(to: nonCoreAudio)
    let nonCoreAudioSuggestion = try ProfileDeviceMapping.suggestions(configurationPath: nonCoreAudio.path, devices: devices)
    if case .unsupported = nonCoreAudioSuggestion.capture.resolution {} else {
        throw CheckFailure.failed("non-CoreAudio capture was offered as a CoreAudio device mapping")
    }

    let filesBeforeFailure = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("DSPJobs").path)
    let failingStore = InterfaceProfileStore(configurationURL: configURL, commandRunner: { _, _ in
        ProcessResult(status: 1, stdout: "", stderr: "invalid filters")
    })
    let failedDraft = InterfaceProfileDraft(name: "Rejected", executablePath: binary.path, configurationPath: yaml.path,
        triggerUID: "virtual", captureUID: "capture", playbackUID: "playback", websocketPort: 3335, autoActivate: false)
    let configBeforeFailure = try Data(contentsOf: configURL)
    do { _ = try await failingStore.save(failedDraft, devices: devices); throw CheckFailure.failed("failed YAML validation was accepted") }
    catch is CheckFailure { throw CheckFailure.failed("failed YAML validation was accepted") }
    catch { }
    let configAfterFailure = try Data(contentsOf: configURL)
    let filesAfterFailure = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("DSPJobs").path)
    try check(configAfterFailure == configBeforeFailure && filesAfterFailure == filesBeforeFailure,
              "failed validation leaves configuration and job folder unchanged")

    var updatedDraft = state.profiles[0]; updatedDraft.name = "First renamed"
    let updated = try await store.save(updatedDraft, devices: devices)
    try check(updated.profiles[0].name == "First renamed" && updated.profiles[0].launchAgentPath == jobURL.path &&
              updated.profiles[0].gui == gui, "name edit preserves existing job and GUI configuration")
    let upgradedRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
    try check(updated.version == 2 && upgradedRaw["version"] as? Int == 2,
              "the first profile save upgrades the document to schema version 2")
    let savedJobBytes = try Data(contentsOf: jobURL)
    let savedYAMLBytes = try Data(contentsOf: yaml)
    try check(savedJobBytes == originalJobBytes && savedYAMLBytes == originalYAMLBytes,
              "name edit leaves external job and YAML files unchanged")
    let stateBackedJobBytes = try Data(contentsOf: secondURL)
    var secondDraft = state.profiles[1]; secondDraft.name = "Second renamed"
    _ = try await store.save(secondDraft, devices: devices)
    let stateBackedSavedJob = try PropertyListSerialization.propertyList(from: Data(contentsOf: secondURL), format: nil) as! [String: Any]
    let savedStateBackedJobBytes = try Data(contentsOf: secondURL)
    let savedStateBytes = try Data(contentsOf: secondState)
    try check(savedStateBackedJobBytes == stateBackedJobBytes && savedStateBytes == secondStateBytes &&
              stateBackedSavedJob["RunAtLoad"] as? Bool == true && stateBackedSavedJob["KeepAlive"] as? Bool == true,
              "name edit preserves state-backed job bytes and its auto-start/KeepAlive policy")

    let afterRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
    try check((afterRaw["unrelatedSetting"] as? [String: Any])?["keep"] as? Bool == true,
              "profile edit preserves unrelated configuration fields")

    var added = InterfaceProfileDraft(name: "Third", executablePath: binary.path, configurationPath: yaml.path,
        triggerUID: "virtual", captureUID: "capture", playbackUID: "playback", websocketPort: 3234, autoActivate: false)
    added.routeAlerts = true
    let before = Set((try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("DSPJobs").path)))
    let withAdded = try await store.save(added, devices: devices)
    let managed = withAdded.profiles.first(where: { $0.id == added.id })!
    try check(managed.launchAgentLabel.contains(added.id) && managed.launchAgentPath.hasSuffix(".plist") &&
              FileManager.default.fileExists(atPath: managed.launchAgentPath) && managed.routeAlerts,
              "new profile gets an owned, uniquely named job")
    let newlyWrittenJob = try DSPJobConfiguration.read(path: managed.launchAgentPath, configuredLabel: managed.launchAgentLabel)
    try check(newlyWrittenJob.configurationPath == yaml.path && newlyWrittenJob.stateFilePath != nil,
              "a new job remains inspectable before CamillaDSP first creates its state file")
    let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("DSPJobs").path))
    try check(after.count == before.count + 1, "new profile writes only its job and reserves a distinct state path")

    let inputOnlyYAML = root.appendingPathComponent("input-only.yml")
    try Data("devices:\n  capture:\n    type: CoreAudio\n    channels: 1\n    device: input-only\n  playback:\n    type: CoreAudio\n    channels: 2\n    device: playback\n".utf8).write(to: inputOnlyYAML)
    let inputOnlyDraft = InterfaceProfileDraft(name: "Input only", executablePath: binary.path,
        configurationPath: inputOnlyYAML.path, triggerUID: "virtual", captureUID: "input-only",
        managedFeedUID: nil, playbackUID: "playback", websocketPort: 6234, autoActivate: false)
    let withInputOnly = try await store.save(inputOnlyDraft, devices: devices)
    try check(withInputOnly.profiles.first(where: { $0.id == inputOnlyDraft.id })?.managedFeedUID == nil,
              "input-only DSP capture can be saved for Companion Mode without a system feed")
    let inputOnlyRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
    let inputOnlyRawProfile = (inputOnlyRaw["profiles"] as! [[String: Any]]).first { $0["id"] as? String == inputOnlyDraft.id }
    let roundTripped = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
    try check(inputOnlyRaw["version"] as? Int == 2 && inputOnlyRawProfile?["managedFeedUID"] is NSNull &&
              roundTripped.profiles.first(where: { $0.id == inputOnlyDraft.id })?.managedFeedUID == nil,
              "explicit Companion-only nil feed survives version 2 JSON round-trip")

    let duplexYAML = root.appendingPathComponent("duplex.yml")
    try Data("devices:\n  capture:\n    type: CoreAudio\n    channels: 2\n    device: duplex\n  playback:\n    type: CoreAudio\n    channels: 2\n    device: duplex\n".utf8).write(to: duplexYAML)
    let duplexDraft = InterfaceProfileDraft(name: "Duplex", executablePath: binary.path,
        configurationPath: duplexYAML.path, triggerUID: "virtual", captureUID: "duplex",
        managedFeedUID: nil, playbackUID: "duplex", websocketPort: 6235, autoActivate: false)
    let withDuplex = try await store.save(duplexDraft, devices: devices)
    let savedDuplex = withDuplex.profiles.first(where: { $0.id == duplexDraft.id })
    try check(savedDuplex?.captureUID == "duplex" && savedDuplex?.playbackUID == "duplex" && savedDuplex?.managedFeedUID == nil,
              "same-device input and output can be saved as a Companion-only duplex profile")

    let offline = InterfaceProfileDraft(name: "Offline", executablePath: binary.path, configurationPath: yaml.path,
        triggerUID: "offline-trigger", captureUID: "offline-capture", playbackUID: "offline-playback", websocketPort: 4234)
    let withOffline = try await store.save(offline, devices: devices)
    try check(withOffline.profiles.contains(where: { $0.id == offline.id }), "disconnected device UIDs remain valid profile selections")

    var replacementDraft = InterfaceProfileDraft(name: "Replacement", executablePath: binary.path,
        configurationPath: yaml.path, triggerUID: "virtual", captureUID: "capture", playbackUID: "playback",
        websocketPort: 3336, autoActivate: true)
    let bytesBeforeUnconfirmedReplacement = try Data(contentsOf: configURL)
    let callsBeforeUnconfirmedReplacement = calls
    do {
        _ = try await store.save(replacementDraft, devices: devices)
        throw CheckFailure.failed("auto-activation replacement saved without confirmation")
    } catch is CheckFailure { throw CheckFailure.failed("auto-activation replacement saved without confirmation") }
    catch { }
    let bytesAfterUnconfirmedReplacement = try Data(contentsOf: configURL)
    try check(bytesAfterUnconfirmedReplacement == bytesBeforeUnconfirmedReplacement && calls == callsBeforeUnconfirmedReplacement,
              "missing replacement confirmation refuses before validation or file writes")

    replacementDraft.confirmedAutoActivationReplacementIDs = ["first", "second"]
    do {
        _ = try await store.save(replacementDraft, devices: devices)
        throw CheckFailure.failed("stale extra replacement confirmation was accepted")
    } catch is CheckFailure { throw CheckFailure.failed("stale extra replacement confirmation was accepted") }
    catch { }
    let bytesAfterExtraConfirmation = try Data(contentsOf: configURL)
    try check(bytesAfterExtraConfirmation == bytesBeforeUnconfirmedReplacement && calls == callsBeforeUnconfirmedReplacement,
              "replacement confirmation must exactly match same-trigger auto profiles")

    replacementDraft.confirmedAutoActivationReplacementIDs = ["first"]
    let failingReplacementStore = InterfaceProfileStore(configurationURL: configURL, commandRunner: { _, _ in
        ProcessResult(status: 1, stdout: "", stderr: "invalid filters")
    })
    do {
        _ = try await failingReplacementStore.save(replacementDraft, devices: devices)
        throw CheckFailure.failed("failed validation partially applied auto-activation replacement")
    } catch is CheckFailure { throw CheckFailure.failed("failed validation partially applied auto-activation replacement") }
    catch { }
    let bytesAfterFailedReplacement = try Data(contentsOf: configURL)
    try check(bytesAfterFailedReplacement == bytesBeforeUnconfirmedReplacement,
              "failed replacement validation leaves every profile flag and JSON field unchanged")

    let withReplacement = try await store.save(replacementDraft, devices: devices)
    let firstAfterReplacement = withReplacement.profiles.first(where: { $0.id == "first" })
    let secondAfterReplacement = withReplacement.profiles.first(where: { $0.id == "second" })
    let offlineAfterReplacement = withReplacement.profiles.first(where: { $0.id == offline.id })
    let replacementRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
    let replacementRawProfiles = replacementRaw["profiles"] as! [[String: Any]]
    let firstRawAfterReplacement = replacementRawProfiles.first { $0["id"] as? String == "first" }
    try check(firstAfterReplacement?.autoActivate == false && secondAfterReplacement?.autoActivate == false &&
              withReplacement.profiles.first(where: { $0.id == replacementDraft.id })?.autoActivate == true &&
              offlineAfterReplacement?.autoActivate == true,
              "confirmed auto-activation transfer disables only same-trigger profiles")
    try check(firstRawAfterReplacement?["unknownAutomationField"] as? [String: String] == ["keep": "exactly"] &&
              (replacementRaw["unrelatedSetting"] as? [String: Any])?["keep"] as? Bool == true,
              "confirmed replacement preserves unknown profile and configuration fields")

    // CamillaDSP legitimately rewrites fader state while it runs. A name-only edit
    // must remain valid when those controls change, because config_path is unchanged.
    let alternativeYAML = root.appendingPathComponent("alternative.yml")
    try yamlBytes.write(to: alternativeYAML)
    let controlOnlyStateStore = InterfaceProfileStore(configurationURL: configURL, commandRunner: { _, _ in
        try Data("config_path: \(yaml.path)\nmute: [true, false]\nvolume: [-12, -6]\n".utf8).write(to: secondState)
        return ProcessResult(status: 0, stdout: "", stderr: "")
    })
    var controlOnlyDraft = state.profiles[1]
    controlOnlyDraft.name = "Second with changed controls"
    _ = try await controlOnlyStateStore.save(controlOnlyDraft, devices: devices)
    let controlOnlyBytes = try Data(contentsOf: secondState)
    try check(controlOnlyBytes.contains(Data("volume: [-12, -6]".utf8)),
              "mutable state-file volume changes do not block a profile save")

    // But changing the YAML reference after the editor opened must be reviewed.
    try Data("config_path: \(alternativeYAML.path)\nmute: [false, false]\nvolume: [0, 0]\n".utf8).write(to: secondState)
    var staleStateDraft = state.profiles[1]
    staleStateDraft.name = "Stale state reference"
    let callsBeforeStale = calls
    do { _ = try await controlOnlyStateStore.save(staleStateDraft, devices: devices); throw CheckFailure.failed("a state YAML reference changed before Save was accepted") }
    catch is CheckFailure { throw CheckFailure.failed("a state YAML reference changed before Save was accepted") }
    catch { }
    try check(calls == callsBeforeStale, "stale state YAML reference is rejected before invoking CamillaDSP validation")

    // Also catch a path change that races with CamillaDSP validation. State values
    // are otherwise mutable, so this guard intentionally compares only config_path.
    try secondStateBytes.write(to: secondState)
    let stateRaceStore = InterfaceProfileStore(configurationURL: configURL, commandRunner: { _, _ in
        try Data("config_path: \(alternativeYAML.path)\nmute: [false, false]\nvolume: [0, 0]\n".utf8).write(to: secondState)
        return ProcessResult(status: 0, stdout: "", stderr: "")
    })
    do { _ = try await stateRaceStore.save(secondDraft, devices: devices); throw CheckFailure.failed("state YAML reference changed during validation was accepted") }
    catch is CheckFailure { throw CheckFailure.failed("state YAML reference changed during validation was accepted") }
    catch { }
    try secondStateBytes.write(to: secondState)

    let yamlBeforeRace = try Data(contentsOf: yaml)
    let filesBeforeYAMLRace = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("DSPJobs").path)
    let yamlRaceStore = InterfaceProfileStore(configurationURL: configURL, commandRunner: { _, _ in
        try Data("devices: {}\n".utf8).write(to: yaml)
        return ProcessResult(status: 0, stdout: "", stderr: "")
    })
    let yamlRaceDraft = InterfaceProfileDraft(name: "YAML race", executablePath: binary.path, configurationPath: yaml.path,
        triggerUID: "yaml-race-trigger", captureUID: "capture", playbackUID: "playback", websocketPort: 5235)
    do { _ = try await yamlRaceStore.save(yamlRaceDraft, devices: devices); throw CheckFailure.failed("YAML edit during validation was accepted") }
    catch is CheckFailure { throw CheckFailure.failed("YAML edit during validation was accepted") }
    catch { }
    try yamlBeforeRace.write(to: yaml)
    let filesAfterYAMLRace = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("DSPJobs").path)
    try check(filesAfterYAMLRace == filesBeforeYAMLRace, "YAML edits during validation create no profile job")

    let singleConfig = root.appendingPathComponent("single.json")
    try encoder.encode(Configuration(profiles: [first])).write(to: singleConfig)
    let singleStore = InterfaceProfileStore(configurationURL: singleConfig, commandRunner: runner)
    do { _ = try singleStore.remove(id: "first"); throw CheckFailure.failed("last profile was removed") }
    catch is CheckFailure { throw CheckFailure.failed("last profile was removed") }
    catch { }
    try check(FileManager.default.fileExists(atPath: jobURL.path), "profile removal leaves its external DSP job untouched")
    var mismatchedLabel = first; mismatchedLabel.launchAgentLabel = "another.service"
    try encoder.encode(Configuration(profiles: [mismatchedLabel])).write(to: singleConfig)
    let mismatchedStore = InterfaceProfileStore(configurationURL: singleConfig, commandRunner: runner)
    let mismatchedState = try mismatchedStore.snapshot(devices: devices, activeProfileID: nil)
    try check(mismatchedState.profiles.count == 1 && mismatchedState.profileIssues["first"] != nil &&
              mismatchedState.profiles[0].executablePath.isEmpty && mismatchedState.profiles[0].configurationPath.isEmpty,
              "unsupported job remains visible with a row-specific issue and blank editable paths")

    let bytesBeforeRace = try Data(contentsOf: configURL)
    var raceEdit = try JSONSerialization.jsonObject(with: bytesBeforeRace) as! [String: Any]
    let profilesBeforeRace = try JSONSerialization.data(withJSONObject: raceEdit["profiles"]!, options: [.sortedKeys])
    let raceStore = InterfaceProfileStore(configurationURL: configURL, commandRunner: { _, _ in
        raceEdit["editedDuringValidation"] = true
        try JSONSerialization.data(withJSONObject: raceEdit).write(to: configURL)
        return ProcessResult(status: 0, stdout: "", stderr: "")
    })
    let raceDraft = InterfaceProfileDraft(name: "Race", executablePath: binary.path, configurationPath: yaml.path,
        triggerUID: "race-trigger", captureUID: "capture", playbackUID: "playback", websocketPort: 5234)
    do { _ = try await raceStore.save(raceDraft, devices: devices); throw CheckFailure.failed("external config edit during validation was overwritten") }
    catch is CheckFailure { throw CheckFailure.failed("external config edit during validation was overwritten") }
    catch { }
    let racedConfiguration = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
    let profilesAfterRace = try JSONSerialization.data(withJSONObject: racedConfiguration["profiles"]!, options: [.sortedKeys])
    try check(racedConfiguration["editedDuringValidation"] as? Bool == true,
              "concurrent config edits are preserved and rejected")
    try check(profilesAfterRace == profilesBeforeRace,
              "stale configuration rejection leaves the entire profile set, including auto-activation, unchanged")

    let external = InterfaceProfileStore(configurationURL: configURL, commandRunner: runner)
    _ = try external.snapshot(devices: devices, activeProfileID: nil)
    var externallyEdited = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
    externallyEdited["externalEdit"] = true
    try JSONSerialization.data(withJSONObject: externallyEdited).write(to: configURL)
    do { _ = try external.remove(id: "second"); throw CheckFailure.failed("external config change was overwritten") }
    catch is CheckFailure { throw CheckFailure.failed("external config change was overwritten") }
    catch { }
    weak var validatingStore: InterfaceProfileStore?
    var concurrentRemovalRejected = false
    let concurrentStore = InterfaceProfileStore(configurationURL: configURL, commandRunner: { _, _ in
        do { _ = try validatingStore?.remove(id: "second") }
        catch { concurrentRemovalRejected = true }
        return ProcessResult(status: 0, stdout: "", stderr: "")
    })
    validatingStore = concurrentStore
    var concurrentDraft = updatedDraft; concurrentDraft.autoActivate = false
    let concurrentResult = try await concurrentStore.save(concurrentDraft, devices: devices)
    try check(concurrentRemovalRejected && concurrentResult.profiles.contains(where: { $0.id == "second" }),
              "a reentrant mutation cannot overwrite a profile save during validation")
    print("Interface profile store checks passed: exact mapping, atomic saves, preserved files, offline UIDs, edit races and serialized mutations")
    try check(calls == 7 && validatedPaths == [yaml.path, yaml.path, yaml.path, inputOnlyYAML.path, duplexYAML.path, yaml.path, yaml.path],
              "validation runs exactly once with each selected YAML for every selector-valid save")
}
