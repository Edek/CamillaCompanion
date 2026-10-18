import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class PresetWireFixture {
    var current: [String: Any]
    var target: [String: Any]
    var configurationsByPath: [String: [String: Any]] = [:]
    var path = "/previous.yaml"
    var commands: [String] = []
    var writes: [String] = []
    var ignoreForward = false
    var corruptForward = false
    var ignoreRecovery = false
    var holdForward = false
    var pointerFailuresAfterForward = 0
    var pointerFailures = 0
    var stateFailuresAfterForward = 0
    var stateFailures = 0
    var stateSequenceAfterForward: [String] = []
    var states: [String] = []
    var editActiveAfterValidation = false
    var continuation: CheckedContinuation<Void, Never>?
    let faders: [[String: Any]] = (0...4).map { ["volume": Double(-12 + $0), "mute": $0 == 2] }
    init() {
        current = ["title": "Original", "devices": ["samplerate": 48000, "chunksize": 1024,
            "capture": ["type": "CoreAudio", "device": "capture", "channels": 2],
            "playback": ["type": "CoreAudio", "device": "playback", "channels": 2]],
            "pipeline": [["type": "Filter", "names": ["gain"]]],
            "filters": ["gain": ["type": "Gain", "parameters": ["gain": -1.0]]]]
        target = current; target["title"] = "Listening"; target["filters"] = ["gain": ["type": "Gain", "parameters": ["gain": -10.0]]]
    }
    func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    func reply(_ name: String, _ value: Any? = nil) throws -> Data {
        var body: [String: Any] = ["result": "Ok"]
        if let value { body["value"] = value }
        return try JSONSerialization.data(withJSONObject: [name: body], options: [.sortedKeys])
    }
    func exchange(_ url: URL, _ input: [String]) async throws -> [Data] {
        var replies: [Data] = []
        for text in input {
            let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            let mapping = decoded as? [String: Any]
            let name = decoded as? String ?? mapping!.keys.first!
            let value = mapping?[name]
            commands.append(name)
            switch name {
            case "GetState":
                if stateFailures > 0 { stateFailures -= 1; throw URLError(.networkConnectionLost) }
                let state = states.isEmpty ? "Running" : states.removeFirst()
                replies.append(try reply(name, state))
            case "GetConfigJson": replies.append(try reply(name, json(current)))
            case "GetConfigFilePath": replies.append(try reply(name, path))
            case "GetFaders": replies.append(try reply(name, faders))
            case "ReadConfigFile": replies.append(try reply(name, json(configurationsByPath[value as? String ?? ""] ?? target)))
            case "ReadConfigJson", "ValidateConfigJson":
                if name == "ValidateConfigJson", editActiveAfterValidation { current["title"] = "External edit" }
                replies.append(try reply(name, value))
            case "SetConfigJson":
                writes.append(name)
                let incoming = try JSONSerialization.jsonObject(with: Data((value as! String).utf8)) as! [String: Any]
                let forward = incoming["title"] as? String == "Listening"
                if forward && holdForward {
                    await withCheckedContinuation { continuation = $0 }
                    try Task.checkCancellation()
                }
                if !(forward && ignoreForward) && !(!forward && ignoreRecovery) {
                    current = incoming
                    if forward && corruptForward { current["title"] = "Corrupted" }
                }
                if forward {
                    pointerFailures = pointerFailuresAfterForward
                    stateFailures = stateFailuresAfterForward
                    states = stateSequenceAfterForward
                }
                replies.append(try reply(name))
            case "SetConfigFilePath":
                if pointerFailures > 0 { pointerFailures -= 1; throw URLError(.cannotConnectToHost) }
                writes.append(name); path = value as! String; replies.append(try reply(name))
            default: throw CheckFailure.failed("Unexpected preset fixture command: \(name)")
            }
        }
        return replies
    }
}

@MainActor func runPresetPlatformChecks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preset-platform-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("listening.yaml")
    try "title: Local file\ndevices: {}\npipeline: []\n".write(to: file, atomically: true, encoding: .utf8)
    let profile = Profile(id: "preset-wire", name: "Preset wire", triggerUID: "trigger", captureUID: "capture", playbackUID: "playback",
        launchAgentLabel: "unused", launchAgentPath: "/unused", websocketURL: "ws://127.0.0.1:1234",
        expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
    func transport(_ fixture: PresetWireFixture, timeout: TimeInterval = 3) -> CamillaPresetDSPTransport {
        CamillaPresetDSPTransport(timeout: timeout, transaction: { url, commands in try await fixture.exchange(url, commands) })
    }
    let success = PresetWireFixture()
    let successful = try await transport(success).apply(path: file.path, profile: profile)
    try check(successful.activePath == file.path && successful.activeTitle == "Listening", "Preset success requires actual JSON and path readback")
    try check(success.writes == ["SetConfigJson", "SetConfigFilePath"] && !success.commands.contains("Reload"),
              "Preset applies immutable validated JSON and preserves faders without reload or replay")
    let mismatch = PresetWireFixture()
    var devices = mismatch.target["devices"] as! [String: Any]; devices["chunksize"] = 2048; mismatch.target["devices"] = devices
    let reference = directory.appendingPathComponent("previous.yaml")
    try "title: Previous\ndevices: {}\npipeline: []\n".write(to: reference, atomically: true, encoding: .utf8)
    mismatch.configurationsByPath[reference.path] = mismatch.current
    let bufferingTransport = transport(mismatch)
    let buffering = try await bufferingTransport.inspect(profile: profile, paths: [file.path, reference.path])
    try check(buffering.entries.first?.available == true && buffering.entries.first?.requiresAudioRestart == true &&
        buffering.entries.first?.settingChanges == ["chunksize: 1024 → 2048 frames"],
        "Supported buffering changes remain selectable with exact processing restart impact")
    let readsBeforeBuffering = mismatch.commands.filter { $0 == "ReadConfigFile" }.count
    let buffered = try await bufferingTransport.apply(path: file.path, profile: profile, expectedImpact: buffering.entries[0].impact)
    let appliedDevices = mismatch.current["devices"] as! [String: Any]
    try check(appliedDevices["chunksize"] as? Int == 2048 && mismatch.writes == ["SetConfigJson", "SetConfigFilePath"],
        "Restart preset applies its complete intended devices block without forcing a process restart")
    try check(buffered.entries[0].requiresAudioRestart == false && buffered.entries[0].settingChanges.isEmpty &&
        buffered.entries[1].requiresAudioRestart && buffered.entries[1].settingChanges == ["chunksize: 2048 → 1024 frames"],
        "Confirmed timing switch immediately reclassifies selected and other inspected presets against new active devices")
    try check(mismatch.commands.filter { $0 == "ReadConfigFile" }.count == readsBeforeBuffering + 1,
        "Post-switch impact reclassification adds no catalog network reads")
    let rateAdjustment = PresetWireFixture()
    devices = rateAdjustment.current["devices"] as! [String: Any]; devices["adjust_period"] = 1; rateAdjustment.current["devices"] = devices
    devices["adjust_period"] = 2; rateAdjustment.target["devices"] = devices
    rateAdjustment.pointerFailuresAfterForward = 2
    rateAdjustment.stateFailuresAfterForward = 2
    rateAdjustment.stateSequenceAfterForward = ["Starting", "Starting", "Paused"]
    let rateCatalog = try await transport(rateAdjustment).inspect(profile: profile, paths: [file.path])
    try check(rateCatalog.entries[0].settingChanges == ["adjust_period: 1 → 2 seconds"] && rateCatalog.entries[0].requiresAudioRestart,
        "Adjustment period 1 versus 2 is classified as supported audio reconfiguration")
    _ = try await transport(rateAdjustment).apply(path: file.path, profile: profile, expectedImpact: rateCatalog.entries[0].impact)
    try check(rateAdjustment.writes == ["SetConfigJson", "SetConfigFilePath"] && rateAdjustment.pointerFailures == 0 && rateAdjustment.stateFailures == 0,
        "Expected Starting and temporary API interruptions are retried finitely without replaying config or faders")
    let changedImpact = PresetWireFixture()
    let displayed = try await transport(changedImpact).inspect(profile: profile, paths: [file.path])
    devices = changedImpact.target["devices"] as! [String: Any]; devices["adjust_period"] = 2; changedImpact.target["devices"] = devices
    var rejected = false
    do { _ = try await transport(changedImpact).apply(path: file.path, profile: profile, expectedImpact: displayed.entries[0].impact) } catch { rejected = true }
    try check(rejected && changedImpact.writes.isEmpty, "Changed displayed interruption impact rejects before mutation")
    let externalEdit = PresetWireFixture(); externalEdit.editActiveAfterValidation = true
    rejected = false
    do { _ = try await transport(externalEdit).apply(path: file.path, profile: profile) } catch { rejected = true }
    try check(rejected && externalEdit.writes.isEmpty, "External active configuration edits invalidate preflight before mutation")
    let selectors = PresetWireFixture()
    devices = selectors.target["devices"] as! [String: Any]; devices["capture"] = ["type": "CoreAudio", "device": "other", "channels": 2]; selectors.target["devices"] = devices
    rejected = false
    do { _ = try await transport(selectors).apply(path: file.path, profile: profile) } catch { rejected = true }
    try check(rejected && selectors.writes.isEmpty, "Preset CoreAudio selectors require exact matches")
    let lowLimit = PresetWireFixture()
    lowLimit.target["filters"] = ["gain": ["type": "Volume", "parameters": ["fader": "Aux1", "limit": -30.0]]]
    rejected = false
    do { _ = try await transport(lowLimit).apply(path: file.path, profile: profile) } catch { rejected = true }
    try check(rejected && lowLimit.writes.isEmpty, "Current Aux trim above preset limit rejects before mutation")
    let unchanged = PresetWireFixture(); unchanged.ignoreForward = true
    devices = unchanged.current["devices"] as! [String: Any]; devices["adjust_period"] = 1; unchanged.current["devices"] = devices
    devices["adjust_period"] = 2; unchanged.target["devices"] = devices
    let rollbackTransport = transport(unchanged)
    let rollbackCatalog = try await rollbackTransport.inspect(profile: profile, paths: [file.path])
    let originalJSON = try unchanged.json(unchanged.current)
    rejected = false
    var recoveredState: PresetDSPState?
    do { _ = try await rollbackTransport.apply(path: file.path, profile: profile, expectedImpact: rollbackCatalog.entries[0].impact) }
    catch PresetFailure.restored(_, let state) { rejected = true; recoveredState = state }
    let restoredJSON = try unchanged.json(unchanged.current)
    try check(rejected && unchanged.path == "/previous.yaml" && restoredJSON == originalJSON,
              "Acknowledged but unapplied preset restores actual previous JSON and file path")
    try check(unchanged.writes == ["SetConfigJson", "SetConfigFilePath", "SetConfigJson", "SetConfigFilePath"],
              "Preset rollback never replays gain or mute commands")
    try check(recoveredState?.activePath == "/previous.yaml" && recoveredState?.activeTitle == "Original",
              "Verified recovery returns the actual previous state through a typed failure")
    try check(recoveredState?.entries.first?.requiresAudioRestart == true &&
        recoveredState?.entries.first?.settingChanges == ["adjust_period: 1 → 2 seconds"],
        "Verified rollback returns catalog impacts relative to the restored actual configuration")
    let unsafe = PresetWireFixture(); unsafe.corruptForward = true; unsafe.ignoreRecovery = true
    var unavailable = false
    do { _ = try await transport(unsafe, timeout: 4).apply(path: file.path, profile: profile) }
    catch DSPFailure.unavailable { unavailable = true }
    try check(unavailable, "Unverified recovery reports unavailable DSP authority")
    let external = PresetWireFixture(); external.path = file.path
    let inspection = try await transport(external).inspect(profile: profile, paths: [file.path])
    try check(inspection.activePath == nil && inspection.activeTitle == "Original" && inspection.entries.first?.available == true,
              "An unsaved external config change cannot claim the filename preset is active")
    let canceled = PresetWireFixture(); canceled.holdForward = true
    let cancellationTransport = transport(canceled)
    let pending = Task { try await cancellationTransport.apply(path: file.path, profile: profile) }
    try await eventually("Preset cancellation fixture never reached mutation") { canceled.continuation != nil }
    cancellationTransport.cancel()
    canceled.continuation?.resume(); canceled.continuation = nil
    do { _ = try await pending.value; throw CheckFailure.failed("Canceled preset accepted") } catch is CancellationError {}
    try check(canceled.writes == ["SetConfigJson"], "Lifecycle cancellation prevents stale file-pointer writes and rollback")
    let hanging = PresetWireFixture(); hanging.holdForward = true
    let bounded = transport(hanging, timeout: 0.12)
    rejected = false
    let start = ProcessInfo.processInfo.systemUptime
    do { _ = try await bounded.apply(path: file.path, profile: profile) } catch { rejected = true }
    hanging.continuation?.resume(); hanging.continuation = nil
    try check(rejected && ProcessInfo.processInfo.systemUptime - start < 0.5,
              "Injected transaction shares a bounded deadline including rollback")
    let nonlocal = PresetWireFixture()
    var remoteProfile = profile; remoteProfile.websocketURL = "ws://example.com:1234"
    rejected = false
    do { _ = try await transport(nonlocal).apply(path: file.path, profile: remoteProfile) } catch { rejected = true }
    try check(rejected && nonlocal.commands.isEmpty, "Preset transport rejects nonlocal endpoints before any command")
}
