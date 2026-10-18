import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class PresetFixture: PresetDSPTransport {
    var inspections = 0
    var applications: [String] = []
    var cancellations = 0
    var hold = false
    var restoredFailure: PresetFailure?
    var waiting: CheckedContinuation<Void, Never>?
    var entries: [PresetEntry] = []
    func inspect(profile: Profile, paths: [String]) async throws -> PresetDSPState {
        inspections += 1
        if hold { await withCheckedContinuation { waiting = $0 } }
        try Task.checkCancellation()
        entries = paths.map { PresetEntry(path: $0, title: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) }
        return PresetDSPState(activePath: "/external/listening.yml", activeTitle: "External listening", entries: entries)
    }
    func apply(path: String, profile: Profile) async throws -> PresetDSPState {
        applications.append(path)
        if let restoredFailure { throw restoredFailure }
        if hold { await withCheckedContinuation { waiting = $0 } }
        try Task.checkCancellation()
        return PresetDSPState(activePath: path, activeTitle: "Selected", entries: entries)
    }
    func cancel() { cancellations += 1; let prior = waiting; waiting = nil; prior?.resume() }
}
@MainActor private final class PresetLeaseAudio: AudioManaging {
    var value = AudioSnapshot(devices: [AudioDevice(uid: "capture", name: "Capture", hasOutput: true),
        AudioDevice(uid: "playback", name: "Playback", hasOutput: true),
        AudioDevice(uid: "built", name: "Built in", hasOutput: true, isBuiltIn: true)],
        outputUID: "built", alertUID: "built")
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws { value.outputUID = uid }
    func setAlertOutput(uid: String) throws { value.alertUID = uid }
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws {}
    func stopMonitoring() {}
}
@MainActor private final class PresetLeaseDSP: DSPManaging {
    var onFailure: (@MainActor (String) -> Void)?
    var stops = 0
    var verifications = 0
    var failVerification = false
    var failureDuringVerification = false
    var failureAfterVerification = false
    func start(_ profile: Profile) async throws {}
    func verifyReadiness(_ profile: Profile) async throws {
        verifications += 1
        if failVerification { throw DSPFailure.unavailable("Fixture rearm failed") }
        if failureDuringVerification { onFailure?("New passive socket failed during rearm") }
        if failureAfterVerification {
            failureAfterVerification = false
            Task { @MainActor [weak self] in self?.onFailure?("New passive socket failed after rearm returned") }
        }
    }
    func stop(_ profile: Profile) async throws { stops += 1 }
}
@MainActor private final class PresetLeaseStore: RouteStoring {
    var record: RouteRecord?
    func load() throws -> RouteRecord? { record }
    func save(_ record: RouteRecord?) throws { self.record = record }
}
@MainActor private final class PresetLeaseSleeper: TransitionSleeping {
    func sleep(milliseconds: Int) async throws { try Task.checkCancellation() }
}
@MainActor private final class PresetLeaseGate {
    var started = false
    var completed = false
    var continuation: CheckedContinuation<Void, Never>?
    func run() async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
        completed = true
        try Task.checkCancellation()
    }
    func release() { let prior = continuation; continuation = nil; prior?.resume() }
}
@MainActor private final class PresetDrainFixture: AuxDSPTransport {
    var hold = false
    var waiting: CheckedContinuation<Void, Never>?
    var writes = 0
    func read(profile: Profile) async throws -> AuxDSPState {
        if hold { await withCheckedContinuation { waiting = $0 } }
        return AuxDSPState(faders: [], main: AuxFader(id: 0, name: "Main", volumeDB: -12, muted: false, maximumDB: 0))
    }
    func setVolume(id: Int, db: Double) async throws { writes += 1 }
    func setMute(id: Int, muted: Bool) async throws { writes += 1 }
    func cancel() { let prior = waiting; waiting = nil; prior?.resume() }
}

@MainActor func runPresetChecks() async throws {
    let profile = Profile(id: "preset", name: "Preset", triggerUID: "playback", captureUID: "capture",
        playbackUID: "playback", launchAgentLabel: "fixture", launchAgentPath: "/unused.plist",
        websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback",
        startupDelayMilliseconds: 0)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preset-checks-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("one.yml"), second = folder.appendingPathComponent("two.yaml")
    try Data("title: First".utf8).write(to: first)
    try Data("title: Second".utf8).write(to: second)
    try Data().write(to: folder.appendingPathComponent("ignored.txt"))
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("directory.yml"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.yml"), withDestinationURL: first)
    let discovered = try PresetCatalog.paths(folderPath: folder.path)
    try check(discovered == [first.path, second.path], "Preset discovery is flat YAML-only and excludes symbolic links")

    let transport = PresetFixture(), controller = PresetController(transport: transport)
    controller.activate(profile: profile, ready: true, folderPath: folder.path)
    try check(transport.inspections == 0 && !controller.snapshot.ready, "Preset activation does not create an idle reader")
    try await controller.refreshForUser()
    try check(controller.snapshot.ready && controller.snapshot.activeTitle == "External listening" && controller.snapshot.entries.count == 2,
        "Preset refresh reports the actual external configuration and finite catalog")
    try await controller.selectForUser(path: first.path)
    try check(controller.snapshot.activePath == first.path && controller.snapshot.entries.count == 2 && transport.applications == [first.path],
        "Selection commits only a confirmed transport state")
    try FileManager.default.removeItem(at: first)
    var rejected = false
    do { try await controller.selectForUser(path: first.path) } catch { rejected = true }
    try check(rejected && transport.applications == [first.path] && !controller.snapshot.ready,
        "Disappeared preset never reaches mutation transport and status becomes unverified")
    transport.restoredFailure = .restored("Previous preset restored", PresetDSPState(activePath: "/external/recent.yml", activeTitle: "Actual prior preset"))
    try await controller.refreshForUser()
    do { try await controller.selectForUser(path: second.path) } catch {}
    try check(controller.snapshot.ready && controller.snapshot.activePath == "/external/recent.yml" && controller.snapshot.activeTitle == "Actual prior preset",
        "Confirmed rollback publishes actual prior identity rather than a stale menu identity")
    transport.restoredFailure = nil
    transport.hold = true
    let stale = Task { try await controller.refreshForUser() }
    try await eventually("Preset inspection did not suspend") { transport.waiting != nil }
    controller.activate(profile: nil, ready: false, folderPath: folder.path)
    _ = await stale.result
    try check(controller.snapshot.profileID == nil && controller.snapshot.entries.isEmpty && !controller.snapshot.busy,
        "Old-profile inspection cannot publish into a changed preset target")

    let request = ControllerRequest(command: .preset, profileID: profile.id, presetPath: second.path)
    let decoded = try JSONDecoder().decode(ControllerRequest.self, from: JSONEncoder().encode(request))
    try check(decoded.command == .preset && decoded.presetPath == second.path, "Controller and CLI share the preset request schema")
    let oldRequest = Data("{\"scope\":\"controller\",\"command\":\"status\"}".utf8)
    let oldDecoded = try JSONDecoder().decode(ControllerRequest.self, from: oldRequest)
    try check(oldDecoded.presetPath == nil,
        "Existing controller requests remain decodable")
    let legacyEntry = try JSONDecoder().decode(PresetEntry.self, from: Data("{\"path\":\"/old.yml\",\"title\":\"Old\",\"available\":true}".utf8))
    try check(!legacyEntry.requiresAudioRestart && legacyEntry.settingChanges.isEmpty, "Legacy preset entries decode with compatible impact defaults")
    func configuration(_ devices: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["devices": devices], options: [.sortedKeys]), as: UTF8.self)
    }
    let baseDevices: [String: Any] = ["samplerate": 48000, "chunksize": 1024, "adjust_period": 1,
        "capture": ["type": "CoreAudio", "device": "capture", "channels": 2],
        "playback": ["type": "CoreAudio", "device": "playback", "channels": 2]]
    let base = try configuration(baseDevices)
    let compatible = try PresetCompatibility.classify(activeConfiguration: base, candidateConfiguration: base)
    try check(!compatible.requiresAudioRestart && compatible.settingChanges.isEmpty, "Unchanged devices remain compatible")
    var changedDevices = baseDevices; changedDevices["adjust_period"] = 2
    let adjustment = try PresetCompatibility.classify(activeConfiguration: base, candidateConfiguration: configuration(changedDevices))
    try check(adjustment.requiresAudioRestart && adjustment.settingChanges == ["adjust_period: 1 → 2 seconds"],
        "Supported adjustment period difference reports exact processing restart impact")
    for key in ["samplerate", "capture_samplerate", "resampler", "volume_limit", "worker_threads"] {
        changedDevices = baseDevices
        if key == "resampler" { changedDevices[key] = ["type": "AsyncSinc", "profile": "Fast"] }
        else { changedDevices[key] = 96000 }
        rejected = false
        do { _ = try PresetCompatibility.classify(activeConfiguration: base, candidateConfiguration: configuration(changedDevices)) } catch { rejected = true }
        try check(rejected, "Unsupported field \(key) cannot enter selectable restart scope")
    }
    changedDevices = baseDevices; changedDevices["adjust_period"] = 0
    rejected = false
    do { _ = try PresetCompatibility.classify(activeConfiguration: base, candidateConfiguration: configuration(changedDevices)) } catch { rejected = true }
    try check(rejected, "Invalid adjustment period remains unavailable")

    let faderTransport = PresetDrainFixture()
    let aux = AuxController(transport: faderTransport, loadPreferences: { _ in AuxPreferences() }, savePreferences: { _, _ in })
    aux.activate(profile: profile)
    try await aux.refreshForUser()
    let mainBeforeDrain = aux.snapshot.main
    faderTransport.hold = true
    let faderWork = Task { try await aux.changeVolumeForUser(id: 0, db: -24) }
    try await eventually("Fader work did not suspend before preset drain") { faderTransport.waiting != nil }
    await aux.drainForDSPChange()
    _ = await faderWork.result
    try check(mainBeforeDrain != nil && !aux.snapshot.ready && !aux.snapshot.busy && aux.snapshot.main == mainBeforeDrain && faderTransport.writes == 0,
        "Preset drain retains disabled Main, waits for canceled work and prevents a stale post-read write")

    let audio = PresetLeaseAudio(), dsp = PresetLeaseDSP()
    let engine = Reconciler(profiles: [profile], audio: audio, dsp: dsp, store: PresetLeaseStore(), sleeper: PresetLeaseSleeper())
    engine.setMode(.forceOn, profileID: profile.id)
    try engine.start()
    try await eventually("Preset lease DSP did not activate") { engine.state == .active(profile.id) }
    let initialVerifications = dsp.verifications
    try await engine.performDSPControl(profileID: profile.id, allowsProcessingRestart: true) {}
    try check(dsp.verifications == initialVerifications + 1,
        "Every flagged audio restart re-arms passive observation even without a delivered old-socket failure")
    try await engine.performDSPControl(profileID: profile.id, allowsProcessingRestart: true) {
        dsp.onFailure?("Expected audio reopening")
        try check(!engine.recovering && audio.value.outputUID == profile.captureUID,
            "Expected restart observation does not start competing recovery or restore owned routes")
    }
    try check(dsp.verifications == initialVerifications + 2 && engine.state == .active(profile.id) && !engine.dspControlBusy,
        "Expected restart interruption re-arms passive observation before releasing the lease")
    engine.release()
    try await eventually("Preset bypass fixture did not settle") {
        engine.released && !engine.routingRestoring && engine.state == .active(profile.id) && audio.value.outputUID == "built"
    }
    let bypassedUID = audio.value.outputUID
    try await engine.performDSPControl(profileID: profile.id, allowsProcessingRestart: true) {
        dsp.onFailure?("Expected audio reopening in Direct")
    }
    try check(engine.released && audio.value.outputUID == bypassedUID,
        "Reconfiguration preserves explicit Direct intent and physical output routing")
    try engine.resume()
    try await eventually("Preset bypass fixture did not resume") { !engine.released && !engine.routingRestoring && engine.state == .active(profile.id) }
    var restored = false
    do {
        try await engine.performDSPControl(profileID: profile.id, allowsProcessingRestart: true) {
            dsp.onFailure?("Expected interrupted rollback observation")
            throw PresetFailure.restored("Restored fixture", PresetDSPState(activePath: "/previous.yml", activeTitle: "Previous"))
        }
    } catch PresetFailure.restored { restored = true }
    try check(restored && dsp.verifications == initialVerifications + 4 && !engine.recovering,
        "Verified rollback preserves its typed result after rearming passive observation")
    let gate = PresetLeaseGate()
    let operation = Task { try await engine.performDSPControl(profileID: profile.id) { try await gate.run() } }
    try await eventually("Preset lease operation did not start") { gate.started }
    try check(engine.dspControlBusy && !engine.permitsDSPControls(profileID: profile.id), "Mutation lease revokes new Aux/Main command authority")
    rejected = false
    do { try await engine.performDSPControl(profileID: profile.id) {} } catch { rejected = true }
    try check(rejected, "A second DSP mutation cannot overlap the first")
    engine.setMode(.forceOff)
    for _ in 0..<30 { await Task.yield() }
    try check(dsp.stops == 0 && !gate.completed, "Lifecycle stop waits for the accepted finite DSP mutation")
    gate.release()
    let result = await operation.result
    if case .success = result { throw CheckFailure.failed("Lifecycle change must cancel the old DSP mutation") }
    try await eventually("Preset lifecycle did not finish after canceled operation") { dsp.stops == 1 && !engine.dspControlBusy }
    await engine.shutdown()
    let recoveryAudio = PresetLeaseAudio(), recoveryDSP = PresetLeaseDSP()
    let recoveryEngine = Reconciler(profiles: [profile], audio: recoveryAudio, dsp: recoveryDSP,
        store: PresetLeaseStore(), sleeper: PresetLeaseSleeper())
    recoveryEngine.setMode(.forceOn, profileID: profile.id)
    try recoveryEngine.start()
    try await eventually("Preset unsafe-recovery fixture did not activate") { recoveryEngine.state == .active(profile.id) }
    recoveryEngine.reportDSPFailure(profileID: "other", reason: "stale failure")
    try check(recoveryEngine.state == .active(profile.id), "A stale profile cannot report failure into another lifecycle")
    recoveryDSP.failureDuringVerification = true
    var unsafeRearm = false
    do {
        try await recoveryEngine.performDSPControl(profileID: profile.id, allowsProcessingRestart: true) {
        }
    } catch DSPFailure.unavailable { unsafeRearm = true }
    try check(unsafeRearm && !recoveryEngine.dspControlBusy && !recoveryEngine.processingReconfiguration,
        "A new passive failure during successful rearm is retained and reports unavailable DSP rather than being erased")
    recoveryEngine.reportDSPFailure(profileID: profile.id, reason: "Preset restart readiness was not verified")
    try check(recoveryEngine.recovering && !recoveryEngine.permitsDSPControls(profileID: profile.id) && recoveryAudio.value.outputUID == "built",
        "Unverified preset recovery restores routing and revokes DSP command authority")
    await recoveryEngine.shutdown()
    let lateAudio = PresetLeaseAudio(), lateDSP = PresetLeaseDSP()
    let lateEngine = Reconciler(profiles: [profile], audio: lateAudio, dsp: lateDSP,
        store: PresetLeaseStore(), sleeper: PresetLeaseSleeper())
    lateEngine.setMode(.forceOn, profileID: profile.id)
    try lateEngine.start()
    try await eventually("Late passive failure fixture did not activate") { lateEngine.state == .active(profile.id) }
    var lateRecoveryObserved = false
    lateEngine.onControlChange = { if lateEngine.recovering { lateRecoveryObserved = true } }
    lateDSP.failureAfterVerification = true
    do { try await lateEngine.performDSPControl(profileID: profile.id, allowsProcessingRestart: true) {} }
    catch DSPFailure.unavailable(let reason) { lateEngine.reportDSPFailure(profileID: profile.id, reason: reason) }
    try await eventually("A passive failure after rearm was discarded by lease cleanup") { lateRecoveryObserved }
    await lateEngine.shutdown()
    let lossAudio = PresetLeaseAudio(), lossDSP = PresetLeaseDSP()
    let lossEngine = Reconciler(profiles: [profile], audio: lossAudio, dsp: lossDSP,
        store: PresetLeaseStore(), sleeper: PresetLeaseSleeper())
    lossEngine.setMode(.forceOn, profileID: profile.id)
    try lossEngine.start()
    try await eventually("Device-loss reconfiguration fixture did not activate") { lossEngine.state == .active(profile.id) }
    let lossGate = PresetLeaseGate()
    let lostOperation = Task {
        try await lossEngine.performDSPControl(profileID: profile.id, allowsProcessingRestart: true) { try await lossGate.run() }
    }
    try await eventually("Device-loss reconfiguration lease did not begin") { lossGate.started }
    lossAudio.value.devices.removeAll { $0.uid == profile.playbackUID }
    lossEngine.handle(.devicesChanged)
    for _ in 0..<30 { await Task.yield() }
    try check(lossDSP.stops == 0, "Device loss waits for canceled reconfiguration work to finish before stopping DSP")
    lossGate.release()
    let lossResult = await lostOperation.result
    if case .success = lossResult { throw CheckFailure.failed("Device loss must cancel the preset reconfiguration") }
    try await eventually("Device-loss reconfiguration did not stop cleanly") { lossDSP.stops == 1 && !lossEngine.dspControlBusy }
    await lossEngine.shutdown()
    try await runPresetPlatformChecks()
}
