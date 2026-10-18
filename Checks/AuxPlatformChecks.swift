import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runAuxPlatformChecks() async throws {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws { try check(condition, message); count += 1 }
    func rejects(_ message: String, _ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try expect(rejected, message)
    }
    func reply(_ command: String, _ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [command: ["result": "Ok", "value": value]])
    }
    func configuration(_ pipeline: [[String: Any]], volumeLimit: Any? = nil) throws -> Data {
        var config: [String: Any] = [
            "devices": ["capture": ["type": "CoreAudio", "device": "Virtual"],
                        "playback": ["type": "CoreAudio", "device": "Physical"]],
            "pipeline": pipeline,
            "filters": [
                "left": ["type": "Volume", "parameters": ["fader": "Aux1", "limit": -3.0]],
                "left2": ["type": "Volume", "parameters": ["fader": "Aux1", "limit": -8.0]],
                "right": ["type": "Volume", "parameters": ["fader": "Aux2", "limit": NSNull()]],
                "unused": ["type": "Volume", "parameters": ["fader": "Aux3"]],
                "bypassed": ["type": "Volume", "parameters": ["fader": "Aux4"]],
                "loudness": ["type": "Loudness", "parameters": ["fader": "Aux3"]]
            ]
        ]
        if let volumeLimit {
            var devices = config["devices"] as! [String: Any]
            devices["volume_limit"] = volumeLimit
            config["devices"] = devices
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        return try reply("GetConfigJson", json)
    }
    let config = try configuration([
        ["type": "Filter", "channels": [0], "names": ["left", "left2", "right", "loudness"]],
        ["type": "Filter", "channels": [1], "names": ["bypassed"], "bypassed": true],
        ["type": "Filter", "channels": [], "names": ["unused"]]
    ])
    let faders = try reply("GetFaders", (0...4).map { ["volume": Double(-10 - $0), "mute": $0 == 2] as [String: Any] })
    let state = try AuxDSPProtocol.state(configuration: config, faders: faders)
    try expect(state.faders.map(\.id) == [1, 2], "Only enabled pipeline Volume filters expose Aux faders; Main never appears")
    try expect(state.main?.id == 0 && state.main?.volumeDB == -10, "GetFaders exposes Main separately from filtered Aux")
    try expect(state.main?.maximumDB == 50, "Omitted Main volume_limit defaults to +50")
    let emptyState = try AuxDSPProtocol.state(configuration: configuration([], volumeLimit: -6.0), faders: faders)
    try expect(emptyState.faders.isEmpty && emptyState.main?.maximumDB == -6, "Main limit applies with an empty Aux pipeline")
    let nullLimit = try AuxDSPProtocol.state(configuration: configuration([], volumeLimit: NSNull()), faders: faders)
    try expect(nullLimit.main?.maximumDB == 50, "Null Main volume_limit defaults to +50")
    let highLimit = try AuxDSPProtocol.state(configuration: configuration([], volumeLimit: 60.0), faders: faders)
    try expect(highLimit.main?.maximumDB == 50, "Main limit respects protocol maximum")
    for limit in [true, "0", -151.0] as [Any] {
        try rejects("Reject malformed Main volume_limit") {
            _ = try AuxDSPProtocol.state(configuration: configuration([], volumeLimit: limit), faders: faders)
        }
    }
    for volume in [true, "-10", -151.0, 51.0] as [Any] {
        var values = (0...4).map { ["volume": Double(-10 - $0), "mute": false] as [String: Any] }
        values[0]["volume"] = volume
        try rejects("Reject malformed Main volume readback") {
            _ = try AuxDSPProtocol.state(configuration: config, faders: reply("GetFaders", values))
        }
    }
    var numericMute = (0...4).map { _ in ["volume": -10, "mute": false] as [String: Any] }
    numericMute[0]["mute"] = 1
    try rejects("Reject numeric Main mute readback") {
        _ = try AuxDSPProtocol.state(configuration: config, faders: reply("GetFaders", numericMute))
    }
    let mainVolume = try AuxDSPProtocol.volumeCommand(id: 0, db: -20)
    let mainMute = try AuxDSPProtocol.muteCommand(id: 0, muted: true)
    try expect(mainVolume.contains("SetFaderVolume") && mainMute.contains("SetFaderMute"), "Main uses the same acknowledged fader protocol")
    try expect(state.faders[0].maximumDB == -8, "Shared fader uses the most restrictive Volume limit")
    try expect(state.faders[1].maximumDB == 50 && state.faders[1].muted, "Null limit defaults to +50 and fader mute decodes")
    try expect(state.faders[0].volumeDB == -11, "Fader index 1 corresponds to Aux1")
    try rejects("Reject unsuccessful DSP reply") {
        _ = try AuxDSPProtocol.state(configuration: config, faders: Data("{\"GetFaders\":{\"result\":\"InvalidFaderError\",\"value\":[]}}".utf8))
    }
    try rejects("Reject truncated fader list") { _ = try AuxDSPProtocol.state(configuration: config, faders: reply("GetFaders", [])) }
    try rejects("Reject numeric mute field") {
        let malformed = try reply("GetFaders", (0...4).map { _ in ["volume": -10, "mute": 1] })
        _ = try AuxDSPProtocol.state(configuration: config, faders: malformed)
    }
    for id in [-1, 5] {
        try rejects("Never construct invalid volume command") { _ = try AuxDSPProtocol.volumeCommand(id: id, db: -10) }
        try rejects("Never construct invalid mute command") { _ = try AuxDSPProtocol.muteCommand(id: id, muted: false) }
    }
    try rejects("Reject nonfinite volume") { _ = try AuxDSPProtocol.volumeCommand(id: 1, db: .nan) }
    let volumeCommand = try AuxDSPProtocol.volumeCommand(id: 1, db: -20)
    let volumeObject = try JSONSerialization.jsonObject(with: Data(volumeCommand.utf8)) as? [String: [Double]]
    try expect(volumeObject?["SetFaderVolume"] == [1, -20], "Volume setter uses v4.1.3 tuple format")
    let muteCommand = try AuxDSPProtocol.muteCommand(id: 2, muted: true)
    let muteObject = try JSONSerialization.jsonObject(with: Data(muteCommand.utf8)) as? [String: [Any]]
    try expect((muteObject?["SetFaderMute"]?[0] as? Int) == 2 && (muteObject?["SetFaderMute"]?[1] as? Bool) == true,
               "Mute setter uses v4.1.3 tuple format")
    let profile = Profile(id: "test", name: "Test", triggerUID: "trigger", captureUID: "capture", playbackUID: "playback",
                          launchAgentLabel: "test", launchAgentPath: "/not-used.plist", websocketURL: "ws://127.0.0.1:1234",
                          expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
    let wrongProfile = Profile(id: "wrong", name: "Wrong", triggerUID: "trigger", captureUID: "capture", playbackUID: "playback",
                               launchAgentLabel: "test", launchAgentPath: "/not-used.plist", websocketURL: "ws://127.0.0.1:1234",
                               expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Wrong")
    let wrongEndpoint = CamillaAuxDSPTransport(transaction: { _, _ in
        [try reply("GetState", "Running"), config, faders]
    })
    var wrongRejected = false
    do { _ = try await wrongEndpoint.read(profile: wrongProfile) } catch { wrongRejected = true }
    try expect(wrongRejected, "Aux refresh validates exact profile selectors before exposing controls")
    let inactive = CamillaAuxDSPTransport(transaction: { _, _ in
        [try reply("GetState", "Inactive"), config, faders]
    })
    var inactiveRejected = false
    do { _ = try await inactive.read(profile: profile) } catch { inactiveRejected = true }
    try expect(inactiveRejected, "Aux refresh requires a ready DSP state")
    var requests: [[String]] = []
    var inFlight = 0
    var peak = 0
    let transport = CamillaAuxDSPTransport(transaction: { _, commands in
        requests.append(commands)
        inFlight += 1; peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
        if commands == ["\"GetState\"", "\"GetConfigJson\"", "\"GetFaders\""] {
            return [try reply("GetState", "Running"), config, faders]
        }
        let command = commands[0].contains("SetFaderVolume") ? "SetFaderVolume" : "SetFaderMute"
        return [try JSONSerialization.data(withJSONObject: [command: ["result": "Ok"]])]
    })
    _ = try await transport.read(profile: profile)
    let a = Task { try await transport.setVolume(id: 1, db: -20) }
    let b = Task { try await transport.setMute(id: 2, muted: true) }
    let main = Task { try await transport.setVolume(id: 0, db: -20) }
    try await a.value; try await b.value; try await main.value
    try expect(peak == 1 && requests.count == 4, "Main and Aux setters serialize independent finite transactions")
    var invalid = false
    do { try await transport.setVolume(id: 1, db: -7) } catch { invalid = true }
    try expect(invalid && requests.count == 4, "Configured fader limit rejects before wire mutation")
    transport.cancel()
    var canceled = false
    do { try await transport.setMute(id: 1, muted: true) } catch { canceled = true }
    try expect(canceled && requests.count == 4, "Cancellation removes previous profile mutation capability")
    var mainCanceled = false
    do { try await transport.setVolume(id: 0, db: -20) } catch { mainCanceled = true }
    try expect(mainCanceled && requests.count == 4, "Cancellation also removes Main mutation capability")
    var started: CheckedContinuation<Void, Never>?
    var release: CheckedContinuation<Void, Never>?
    let suspended = CamillaAuxDSPTransport(transaction: { _, _ in
        started?.resume(); started = nil
        await withCheckedContinuation { release = $0 }
        return [try reply("GetState", "Running"), config, faders]
    })
    let stale = Task { try await suspended.read(profile: profile) }
    await withCheckedContinuation { continuation in
        started = continuation
    }
    suspended.cancel()
    release?.resume()
    var staleRejected = false
    do { _ = try await stale.value } catch { staleRejected = error is CancellationError }
    try expect(staleRejected, "Canceled refresh cannot publish stale profile state")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aux-checks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("runtime-state.json.aux-preferences.json")
    let store = JSONAuxPreferencesStore(url: file)
    try expect(try store.load(profileID: "first") == nil, "Absent preferences are distinguishable from hidden faders")
    try store.save(AuxPreferences(visibleIDs: [2, 1], labels: ["1": " Left "], linkGroups: [[1, 2]]), profileID: "first")
    try store.save(AuxPreferences(visibleIDs: []), profileID: "second")
    let first = try store.load(profileID: "first")
    try expect(first?.visibleIDs == [1, 2] && first?.labels["1"] == "Left", "Preferences normalize and preserve other profiles")
    try expect(try store.load(profileID: "second")?.visibleIDs == [], "Hide all persists as explicit empty visibility")
    var selectedSubset = first!
    selectedSubset.visibleIDs = [2]; selectedSubset.linkMutes = false
    try store.save(selectedSubset.hidingVisibility(), profileID: "first")
    let hiddenSubset = try store.load(profileID: "first")!
    try expect(hiddenSubset.visibleIDs.isEmpty && hiddenSubset.lastVisibleIDs == [2], "Hidden subset memory survives store roundtrip")
    let restoredSubset = hiddenSubset.restoringVisibility(availableIDs: [1, 2])
    try store.save(restoredSubset, profileID: "first")
    let reloadedSubset = try store.load(profileID: "first")!
    try expect(reloadedSubset.visibleIDs == [2] && reloadedSubset.labels == first!.labels && reloadedSubset.linkGroups == first!.linkGroups && !reloadedSubset.linkMutes,
               "Store restore preserves subset, labels, gain links and mute link policy")
    let legacyFile = directory.appendingPathComponent("legacy-aux.json")
    try Data(#"{"version":1,"profiles":{"legacy":{"visibleIDs":[1,3],"labels":{},"linkGroups":[]}}}"#.utf8).write(to: legacyFile)
    let legacyStore = JSONAuxPreferencesStore(url: legacyFile)
    try expect(try legacyStore.load(profileID: "legacy")?.lastVisibleIDs == [1, 3], "Legacy store files recover remembered visibility without a schema migration")
    let original = try Data(contentsOf: file)
    try rejects("Invalid preference cannot overwrite existing profiles") { try store.save(AuxPreferences(visibleIDs: [0]), profileID: "first") }
    try rejects("Invalid remembered IDs cannot overwrite preferences") { try store.save(AuxPreferences(lastVisibleIDs: [0]), profileID: "first") }
    try rejects("Main cannot join Aux links") { try store.save(AuxPreferences(linkGroups: [[0, 1]]), profileID: "first") }
    try rejects("Main cannot receive an Aux label") { try store.save(AuxPreferences(labels: ["0": "Master"]), profileID: "first") }
    try expect(try Data(contentsOf: file) == original, "Invalid writes preserve file bytes")
    try Data("corrupt".utf8).write(to: file)
    try rejects("Corrupt existing preference document blocks replacement") { try store.save(AuxPreferences(), profileID: "third") }
    try expect(try Data(contentsOf: file) == Data("corrupt".utf8), "Corrupt document is preserved for recovery")
    print("Aux platform checks: \(count) assertions passed; no live DSP mutations")
}
