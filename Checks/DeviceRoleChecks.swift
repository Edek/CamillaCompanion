import Foundation
import AutoAudioCore

@MainActor private final class DeviceRoleAudio: AudioManaging {
    var value: AudioSnapshot
    var outputWrites: [String] = []
    var alertWrites: [String] = []
    init(_ value: AudioSnapshot) { self.value = value }
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws { outputWrites.append(uid); value.outputUID = uid }
    func setAlertOutput(uid: String) throws { alertWrites.append(uid); value.alertUID = uid }
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws {}
    func stopMonitoring() {}
}

@MainActor private final class DeviceRoleDSP: DSPManaging {
    var onFailure: (@MainActor (String) -> Void)?
    var calls: [String] = []
    func start(_ profile: Profile) async throws { calls.append("start:" + profile.id) }
    func verifyReadiness(_ profile: Profile) async throws { calls.append("verify:" + profile.id) }
    func stop(_ profile: Profile) async throws { calls.append("stop:" + profile.id) }
}

@MainActor private final class DeviceRoleStore: RouteStoring {
    var record: RouteRecord?
    var saves: [RouteRecord?] = []
    func load() throws -> RouteRecord? { record }
    func save(_ record: RouteRecord?) throws { self.record = record; saves.append(record) }
}

@MainActor private final class DeviceRoleSleeper: TransitionSleeping {
    func sleep(milliseconds: Int) async throws { await Task.yield(); try Task.checkCancellation() }
}

@MainActor func runDeviceRoleChecks() async throws {
    try checkDeviceRoleCapabilitiesAndMigration()
    try await checkInputOnlyCompanionLifecycle()
    try await checkManagedActivationRejectsCompanionOnlyProfile()
    print("Device role checks passed: profile migration, device directions, duplex Companion readiness and managed-feed admission.")
}

private func checkDeviceRoleCapabilitiesAndMigration() throws {
    let inputOnly = AudioDevice(uid: "input", name: "Input", inputChannels: 2, outputChannels: 0)
    let outputOnly = AudioDevice(uid: "output", name: "Output", inputChannels: 0, outputChannels: 2)
    let duplex = AudioDevice(uid: "duplex", name: "Duplex", inputChannels: 4, outputChannels: 4)
    try check(inputOnly.hasInput && !inputOnly.hasOutput && !DeviceRole.managedFeed.accepts(inputOnly),
              "Input-only device remains a DSP input and cannot serve as a managed system feed")
    try check(!outputOnly.hasInput && outputOnly.hasOutput && !DeviceRole.dspInput.accepts(outputOnly),
              "Output-only device remains a DSP output and cannot serve as a DSP input")
    try check(DeviceRole.managedFeed.accepts(duplex) && duplex.inputChannels == 4 && duplex.outputChannels == 4,
              "Managed feed requires and reports both channel directions")

    let companionDuplex = roleProfile("duplex", trigger: "duplex", capture: "duplex", feed: nil, playback: "duplex")
    let duplexSnapshot = AudioSnapshot(devices: [duplex], outputUID: "duplex", alertUID: nil)
    try check(companionDuplex.deviceRolesAvailable(in: duplexSnapshot, automaticSwitching: false),
              "A single duplex interface can satisfy Companion DSP input and output roles")
    try check(!companionDuplex.deviceRolesAvailable(in: duplexSnapshot, automaticSwitching: true),
              "A Companion-only duplex interface cannot satisfy managed-feed readiness")
    var configuration = Configuration(version: 2, profiles: [companionDuplex])
    try ConfigurationLoader.validate(configuration)
    let missingTriggerProfile = roleProfile("missing-trigger", trigger: "gone", capture: "duplex", feed: nil, playback: "duplex")
    let missingTriggerSnapshot = AudioSnapshot(devices: [duplex], outputUID: "duplex", alertUID: nil)
    try check(missingTriggerProfile.deviceRolesAvailable(in: missingTriggerSnapshot, automaticSwitching: false,
                                                         requireTrigger: false)
              && !missingTriggerProfile.deviceRolesAvailable(in: missingTriggerSnapshot,
                                                            automaticSwitching: false, requireTrigger: true),
              "Companion Auto eligibility requires its trigger while Force On bypasses only trigger eligibility")

    let legacy = roleProfile("legacy", trigger: "trigger", capture: "capture", feed: "capture", playback: "playback")
    let original = try JSONEncoder().encode(legacy)
    var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    object.removeValue(forKey: "managedFeedUID")
    let decodedLegacy = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: object))
    try check(decodedLegacy.managedFeedUID == decodedLegacy.captureUID,
              "A v1 profile without managedFeedUID keeps the legacy capture-as-feed behavior")

    object["managedFeedUID"] = NSNull()
    let decodedCompanion = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: object))
    try check(decodedCompanion.managedFeedUID == nil,
              "An explicit null managedFeedUID remains Companion-only")
    let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decodedCompanion)) as! [String: Any]
    try check(roundTrip.keys.contains("managedFeedUID") && roundTrip["managedFeedUID"] is NSNull,
              "Encoding preserves the explicit Companion-only null instead of reverting to the legacy feed")

    var managed = legacy
    configuration = Configuration(profiles: [managed])
    try ConfigurationLoader.validate(configuration)
    managed.managedFeedUID = "physical"
    configuration.profiles = [managed]
    try checkConfigurationRejected(configuration, message: "Managed feed must match DSP capture")
    managed.managedFeedUID = managed.captureUID
    managed.triggerUID = managed.captureUID
    configuration.profiles = [managed]
    try checkConfigurationRejected(configuration, message: "Managed feed cannot also be the connection trigger")
    managed.triggerUID = "trigger"
    managed.playbackUID = managed.captureUID
    configuration.profiles = [managed]
    try checkConfigurationRejected(configuration, message: "Managed feed cannot also be the DSP output")
    configuration.profiles = [legacy]
    configuration.version = 3
    try checkConfigurationRejected(configuration, message: "Unsupported future configuration version")
    var explicitCompanionV1 = Configuration(profiles: [companionDuplex])
    try checkConfigurationRejected(explicitCompanionV1,
                                   message: "An explicit Companion-only profile cannot be written under legacy version 1")
    explicitCompanionV1.version = 2
    try ConfigurationLoader.validate(explicitCompanionV1)
}

private func checkConfigurationRejected(_ configuration: Configuration, message: String) throws {
    do { try ConfigurationLoader.validate(configuration); throw CheckFailure.failed(message) }
    catch is CheckFailure { throw CheckFailure.failed(message) }
    catch { }
}

@MainActor private func checkInputOnlyCompanionLifecycle() async throws {
    let input = AudioDevice(uid: "mic", name: "Microphone", inputChannels: 1, outputChannels: 0)
    let output = AudioDevice(uid: "speaker", name: "Speaker", inputChannels: 0, outputChannels: 2)
    let trigger = AudioDevice(uid: "trigger", name: "Trigger", inputChannels: 0, outputChannels: 0)
    let audio = DeviceRoleAudio(AudioSnapshot(devices: [input, output, trigger], outputUID: "speaker", alertUID: "speaker"))
    let dsp = DeviceRoleDSP()
    let store = DeviceRoleStore()
    let profile = roleProfile("mic-companion", trigger: "trigger", capture: "mic", feed: nil, playback: "speaker")
    let engine = Reconciler(profiles: [profile], audio: audio, dsp: dsp, store: store,
                            sleeper: DeviceRoleSleeper(), automaticSwitching: false, companionProfileID: profile.id)
    try engine.start()
    try await waitForRoleState { engine.state == .active(profile.id) }
    try check(engine.state == .active(profile.id) && dsp.calls == ["start:mic-companion", "verify:mic-companion"],
              "An input-only capture and separate output can start and verify in Companion Mode")
    try check(audio.outputWrites.isEmpty && audio.alertWrites.isEmpty && store.saves.isEmpty,
              "Companion startup leaves system output, alerts and route ownership untouched")
    await engine.shutdown()
    try check(dsp.calls == ["start:mic-companion", "verify:mic-companion", "stop:mic-companion"],
              "Stopping the input-only Companion session stops only its DSP service")
    try check(audio.outputWrites.isEmpty && audio.alertWrites.isEmpty && store.saves.isEmpty,
              "Companion shutdown does not route an input-only device into macOS output")
}

@MainActor private func checkManagedActivationRejectsCompanionOnlyProfile() async throws {
    let mic = AudioDevice(uid: "mic", name: "Microphone", inputChannels: 1, outputChannels: 0)
    let speaker = AudioDevice(uid: "speaker", name: "Speaker", inputChannels: 0, outputChannels: 2)
    let trigger = AudioDevice(uid: "trigger", name: "Trigger", inputChannels: 0, outputChannels: 0)
    let audio = DeviceRoleAudio(AudioSnapshot(devices: [mic, speaker, trigger], outputUID: "speaker", alertUID: "speaker"))
    let dsp = DeviceRoleDSP()
    let store = DeviceRoleStore()
    let profile = roleProfile("companion-only", trigger: "trigger", capture: "mic", feed: nil, playback: "speaker")
    let engine = Reconciler(profiles: [profile], audio: audio, dsp: dsp, store: store,
                            sleeper: DeviceRoleSleeper(), automaticSwitching: true)
    try engine.start()
    engine.setMode(.forceOn, profileID: profile.id)
    try await waitForRoleState { if case .failed = engine.state { return true }; return false }
    guard case .failed(let reason) = engine.state else {
        throw CheckFailure.failed("Managed activation accepted a Companion-only profile")
    }
    try check(reason.contains("Companion Mode") && reason.contains("managed feed"),
              "Managed activation explains that the selected profile is Companion-only")
    try check(engine.automaticSwitching && dsp.calls.isEmpty,
              "Rejected activation does not silently change global mode or start DSP")
    try check(audio.value.outputUID == "speaker" && audio.outputWrites.isEmpty && audio.alertWrites.isEmpty
              && store.record == nil && store.saves.isEmpty,
              "Rejected activation preserves the current system route and creates no route ownership")
    await engine.shutdown()
}

@MainActor private func waitForRoleState(_ ready: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private func roleProfile(_ id: String, trigger: String, capture: String, feed: String?, playback: String) -> Profile {
    Profile(id: id, name: id, triggerUID: trigger, captureUID: capture, managedFeedUID: feed,
            playbackUID: playback, launchAgentLabel: "com.example.\(id)", launchAgentPath: "/tmp/\(id).plist",
            websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: capture,
            expectedPlaybackDevice: playback, startupDelayMilliseconds: 0)
}
