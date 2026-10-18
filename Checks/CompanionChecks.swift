import Foundation
import AutoAudioCore

@MainActor private final class CompanionAudio: AudioManaging {
    var value = AudioSnapshot(devices: [
        AudioDevice(uid: "phones", name: "Phones", hasOutput: true),
        AudioDevice(uid: "built", name: "Built in", hasOutput: true, isBuiltIn: true),
        AudioDevice(uid: "playback", name: "Playback", hasOutput: true),
        AudioDevice(uid: "capture", name: "Capture", hasOutput: true)
    ], outputUID: "phones", alertUID: "built")
    var outputWrites: [String] = []
    var alertWrites: [String] = []
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws {
        outputWrites.append(uid)
        value.outputUID = uid
    }
    func setAlertOutput(uid: String) throws { alertWrites.append(uid); value.alertUID = uid }
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws {}
    func stopMonitoring() {}
}

@MainActor private final class CompanionBarrier {
    var entered = false
    var completed = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async throws {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        completed = true
        try Task.checkCancellation()
    }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}

@MainActor private final class CompanionDSP: DSPManaging {
    var onFailure: (@MainActor (String) -> Void)?
    var calls: [String] = []
    var readinessFailures: [DSPFailure] = []
    var startBarrier: CompanionBarrier?
    func start(_ profile: Profile) async throws {
        calls.append("start:" + profile.id)
        try await startBarrier?.wait()
        try Task.checkCancellation()
    }
    func verifyReadiness(_ profile: Profile) async throws {
        calls.append("verify:" + profile.id)
        if !readinessFailures.isEmpty { throw readinessFailures.removeFirst() }
    }
    func stop(_ profile: Profile) async throws { calls.append("stop:" + profile.id) }
    var starts: Int { calls.filter { $0.hasPrefix("start:") }.count }
    var stops: Int { calls.filter { $0.hasPrefix("stop:") }.count }
    var verifies: Int { calls.filter { $0.hasPrefix("verify:") }.count }
}

@MainActor private final class CompanionStore: RouteStoring {
    var record: RouteRecord?
    var saves: [RouteRecord?] = []
    var saveFailuresRemaining = 0
    var saveAttempts = 0
    func load() throws -> RouteRecord? { record }
    func save(_ record: RouteRecord?) throws {
        saveAttempts += 1
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw SwitcherError.message("Fixture route persistence failed")
        }
        self.record = record; saves.append(record)
    }
}

/// Short delays yield deterministically. Deadline waits remain suspended until
/// canceled, so a fake watchdog never wins against its readiness operation.
@MainActor private final class CompanionSleeper: TransitionSleeping {
    private var waits: [UUID: CheckedContinuation<Void, Error>] = [:]
    func sleep(milliseconds: Int) async throws {
        try Task.checkCancellation()
        guard milliseconds >= 10_000 else { await Task.yield(); try Task.checkCancellation(); return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waits[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waits.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }
}

@MainActor private final class CompanionFixture {
    let audio = CompanionAudio()
    let dsp = CompanionDSP()
    let store = CompanionStore()
    let sleeper = CompanionSleeper()
    let profiles: [Profile]
    let engine: Reconciler
    init(automaticSwitching: Bool = false, mode: AutomationMode = .automatic,
         selected: String? = nil, multiple: Bool = false, persisted: RouteRecord? = nil,
         output: String = "phones", primaryPlayback: String = "playback") {
        let primary = Self.profile("home", playback: primaryPlayback, capture: "capture")
        profiles = multiple ? [primary, Self.profile("other", playback: "other-playback", capture: "other-capture")] : [primary]
        audio.value.outputUID = output
        if multiple {
            audio.value.devices += [AudioDevice(uid: "other-playback", name: "Other playback", hasOutput: true),
                                    AudioDevice(uid: "other-capture", name: "Other capture", hasOutput: true)]
        }
        store.record = persisted
        engine = Reconciler(profiles: profiles, audio: audio, dsp: dsp, store: store, sleeper: sleeper,
                            automaticSwitching: automaticSwitching, companionMode: mode, companionProfileID: selected)
    }
    private static func profile(_ id: String, playback: String, capture: String) -> Profile {
        Profile(id: id, name: id, triggerUID: playback, captureUID: capture, playbackUID: playback,
                launchAgentLabel: "unused", launchAgentPath: "/unused", websocketURL: "ws://127.0.0.1:1234",
                expectedCaptureDevice: capture, expectedPlaybackDevice: playback,
                routeAlerts: true, startupDelayMilliseconds: 0)
    }
    func start() async throws { try engine.start(); await drain() }
    func drain() async { for _ in 0..<200 { await Task.yield() } }
    func losePrimary() { audio.value.devices.removeAll { $0.uid == "playback" }; engine.handle(.devicesChanged) }
    func reconnectPrimary() {
        audio.value.devices.append(AudioDevice(uid: "playback", name: "Playback", hasOutput: true))
        engine.handle(.devicesChanged)
    }
    func noRoutes(_ message: String) throws {
        try check(audio.outputWrites.isEmpty && audio.alertWrites.isEmpty, message)
    }
}

@MainActor func runCompanionChecks() async throws {
    try await checkCompanionStartupAndOutputObservation()
    try await checkCompanionCaptureStartupRoutingHandoff()
    try await checkCompanionRoutingHandoffPreservesObservedOutput()
    try await checkCompanionRoutingHandoffRequiresPhysicalOutput()
    try await checkCompanionIntentAndReconnect()
    try await checkCompanionUnavailableIsTerminal()
    try await checkCompanionSelectionIsFixed()
    try await checkCompanionHeldStartup()
    try await checkCompanionTransitionDrainsCommand()
    try await checkCompanionEntryPreservesSelectedOutputs()
    try await checkCompanionEntryDrainsRoutingStartup()
    try await checkCompanionRapidToggleRestoresAuthority()
    try await checkCompanionImmediateDisableShutdownRelinquishesOwnership()
    try await checkCompanionUnavailableExplicitOnWaitsForHardware()
    try await checkCompanionHeldStartupShutdown()
    try await checkCompanionHeldStartupRoutingHandoff()
    try await checkCompanionOwnedRelinquishment()
    try await checkCompanionRelinquishmentFailureIsConsumed()
    print("Companion checks passed: output preservation, retained intent and selection, finite readiness, lifecycle drain and durable ownership relinquishment.")
}

@MainActor private func checkCompanionCaptureStartupRoutingHandoff() async throws {
    for quit in [false, true] {
        for alert in ["built", "capture"] {
            let f = CompanionFixture(output: "capture")
            f.audio.value.alertUID = alert
            try await f.start()
            try f.noRoutes("Capture-selected companion startup remains observation-only")
            try check(f.store.record == nil && f.store.saves.isEmpty,
                      "Capture-selected companion startup cannot invent return-route ownership")
            try f.engine.setAutomaticSwitching(true)
            await f.drain()
            try check(f.engine.state == .active("home") && !f.engine.released && f.engine.routingError == nil,
                      "Explicit switching enable acquires capture-selected fresh companion routes without an observed physical output")
            try check(f.engine.permitsDSPControls(profileID: "home") && f.dsp.calls == ["start:home", "verify:home"],
                      "Fresh companion route handoff retains its already verified DSP without restart")
            try check(f.store.record?.previousOutputUID == "built" && f.store.record?.ownsOutput == true
                      && f.store.record?.ownsAlerts == true && f.store.record?.previousAlertUID == (alert == "capture" ? nil : alert),
                      "Explicit handoff persists the automatic physical return route and actual previous alert route")
            try check(f.audio.outputWrites.isEmpty && f.audio.value.outputUID == "capture"
                      && f.audio.value.alertUID == "capture" && f.audio.alertWrites == (alert == "capture" ? [] : ["capture"]),
                      "Explicit handoff avoids rewriting the selected capture output and acquires alert routing correctly")
            if quit { await f.engine.shutdown() }
            else { f.engine.release(); await f.drain() }
            try check(f.audio.outputWrites == ["built"] && f.audio.value.outputUID == "built"
                      && f.audio.value.alertUID == "built" && f.store.record == nil,
                      "Release or Quit after a fresh companion handoff restores safe normal and alert outputs and clears ownership")
            try check(f.dsp.calls == (quit ? ["start:home", "verify:home", "stop:home"] : ["start:home", "verify:home"]),
                      "Only Quit stops the verified DSP after fresh companion route acquisition")
            if !quit { await f.engine.shutdown() }
        }
    }
}

@MainActor private func checkCompanionRoutingHandoffPreservesObservedOutput() async throws {
    for observedAvailable in [true, false] {
        let f = CompanionFixture()
        try await f.start()
        f.audio.value.outputUID = "capture"
        if !observedAvailable { f.audio.value.devices.removeAll { $0.uid == "phones" } }
        f.engine.handle(.outputChanged); await f.drain()
        try check(f.store.record == nil && f.store.saves.isEmpty, "Companion output observation cannot acquire ownership")
        try f.engine.setAutomaticSwitching(true)
        await f.drain()
        let expectedReturn = observedAvailable ? "phones" : "built"
        try check(f.engine.state == .active("home") && !f.engine.released && f.engine.routingError == nil
                  && f.store.record?.previousOutputUID == expectedReturn,
                  "Explicit companion handoff prefers the observed physical output when available, then the automatic restoration choice")
        try check(f.audio.outputWrites.isEmpty && f.dsp.calls == ["start:home", "verify:home"],
                  "Observed-output handoff retains DSP readiness and avoids redundant capture routing")
        await f.engine.shutdown()
        try check(f.audio.value.outputUID == expectedReturn && f.audio.value.alertUID == "built" && f.store.record == nil,
                  "Quit restores the physical return route selected at companion handoff")
    }
}

@MainActor private func checkCompanionRoutingHandoffRequiresPhysicalOutput() async throws {
    // Both remaining outputs are managed capture devices. They can satisfy this
    // fixture's DSP selectors but neither is a safe return route.
    let f = CompanionFixture(selected: "home", multiple: true, output: "capture", primaryPlayback: "other-capture")
    f.audio.value.devices.removeAll { !["capture", "other-capture"].contains($0.uid) }
    f.audio.value.alertUID = "capture"
    try await f.start()
    try check(f.engine.state == .active("home"), "No-physical-output fixture has a verified companion DSP")
    try f.engine.setAutomaticSwitching(true)
    await f.drain()
    try check(f.engine.state == .active("home") && f.engine.released && f.engine.routingError != nil,
              "Companion handoff without any eligible physical return output fails safely")
    try check(f.store.record == nil && f.store.saves.isEmpty && f.dsp.calls == ["start:home", "verify:home"],
              "Failed handoff cannot own a managed capture return route or restart verified DSP")
    try f.engine.resume(); await f.drain()
    try check(f.engine.released && f.engine.routingError != nil && f.store.record == nil,
              "Ordinary Resume continues to require an available physical return output")
    f.audio.value.devices.append(AudioDevice(uid: "built", name: "Built in", hasOutput: true, isBuiltIn: true))
    try f.engine.resume(); await f.drain()
    try check(f.engine.released && f.engine.routingError != nil && f.store.record == nil && f.store.saves.isEmpty,
              "Ordinary Resume cannot use the handoff fallback even when an unobserved physical output becomes available")
    await f.engine.shutdown()
    try f.noRoutes("Failed no-physical-output handoff, Resume and Quit never write routes")
}

@MainActor private func checkCompanionStartupAndOutputObservation() async throws {
    for output in ["phones", "capture"] {
        let f = CompanionFixture(output: output)
        try await f.start()
        try check(f.engine.state == .active("home") && f.engine.selectedID == "home",
                  "One companion profile is selected and becomes active")
        try check(f.engine.permitsDSPControls(profileID: "home"), "Ready companion permits DSP controls on any system output")
        try f.noRoutes("Fresh companion startup cannot infer virtual output ownership or change outputs")
        try check(f.store.record == nil && f.store.saves.isEmpty, "Fresh companion startup saves no invented route ownership")
        f.audio.value.outputUID = output == "phones" ? "capture" : "phones"
        f.engine.handle(.outputChanged); await f.drain()
        f.engine.release(); await f.drain()
        try check(f.engine.state == .active("home") && !f.engine.released && !f.engine.suspended,
                  "Companion output changes and routing release preserve active authority")
        var resumeRejected = false
        do { try f.engine.resume() } catch { resumeRejected = true }
        try check(resumeRejected, "Routing resume is unavailable with automatic switching disabled")
        await f.engine.shutdown()
        try f.noRoutes("Companion observation, release and shutdown perform no output writes")
        try check(f.dsp.calls == ["start:home", "verify:home", "stop:home"], "Companion shutdown stops its managed service once")
    }
}

@MainActor private func checkCompanionIntentAndReconnect() async throws {
    let f = CompanionFixture(mode: .forceOn, selected: "home")
    try await f.start()
    f.losePrimary(); await f.drain()
    try check(f.engine.mode == .forceOn && f.engine.selectedID == "home" && f.dsp.stops == 1,
              "Companion device loss consumes one teardown and retains On intent and selection")
    for _ in 0..<3 { f.engine.handle(.devicesChanged); f.engine.handle(.woke) }
    await f.drain()
    try check(f.dsp.starts == 1 && f.dsp.stops == 1, "Duplicate loss and wake events do not retry teardown or startup")
    f.reconnectPrimary(); await f.drain()
    try check(f.engine.state == .active("home") && f.engine.mode == .forceOn && f.dsp.starts == 2,
              "Selected hardware reconnect restores retained On intent")
    f.engine.setMode(.forceOff); await f.drain()
    try check(f.engine.state == .idle && f.dsp.stops == 2, "Companion Off stops the service")
    f.losePrimary(); f.reconnectPrimary(); await f.drain()
    try check(f.dsp.starts == 2 && f.engine.mode == .forceOff, "Reconnect cannot override companion Off")
    try f.noRoutes("Companion loss, reconnect and Off never route system output")
    await f.engine.shutdown()

    let automatic = CompanionFixture()
    try await automatic.start()
    automatic.losePrimary(); await automatic.drain()
    try check(automatic.engine.mode == .automatic && automatic.engine.selectedID == "home",
              "Companion loss retains Auto intent and fixed selection")
    automatic.reconnectPrimary(); await automatic.drain()
    try check(automatic.engine.state == .active("home") && automatic.dsp.starts == 2,
              "Companion Auto resumes its selected profile after genuine reconnect")
    await automatic.engine.shutdown()
    try automatic.noRoutes("Companion Auto loss and reconnect remain observation-only")

    let off = CompanionFixture(mode: .forceOff)
    try await off.start()
    try check(off.engine.state == .idle && off.dsp.calls.isEmpty,
              "Persisted companion Off performs no startup attempt")
    await off.engine.shutdown()
}

@MainActor private func checkCompanionUnavailableIsTerminal() async throws {
    let f = CompanionFixture()
    f.dsp.readinessFailures = [.unavailable("Fixture unavailable")]
    try await f.start()
    if case .failed = f.engine.state {} else { throw CheckFailure.failed("Companion unavailable must become terminal") }
    try check(!f.engine.recovering && !f.engine.permitsDSPControls(profileID: "home"), "Unavailable companion retains no recovery watcher or DSP authority")
    for _ in 0..<4 { f.engine.handle(.devicesChanged); f.engine.handle(.outputChanged); f.engine.handle(.woke) }
    await f.drain()
    try check(f.dsp.starts == 1 && f.dsp.verifies == 1, "Duplicate notifications cannot restart an unavailable companion")
    f.engine.retry(); await f.drain()
    try check(f.engine.state == .active("home") && f.dsp.starts == 2, "Explicit retry clears terminal companion readiness fault")
    f.dsp.onFailure?("Passive unavailable"); await f.drain()
    try check(!f.engine.recovering && f.dsp.starts == 2, "Passive companion failure cannot start background recovery")
    f.losePrimary(); await f.drain(); f.reconnectPrimary(); await f.drain()
    try check(f.engine.state == .active("home") && f.dsp.starts == 3, "Genuine selected reconnect clears terminal companion fault")
    try f.noRoutes("Unavailable companion recovery actions remain routing-free")
    await f.engine.shutdown()

    let starting = CompanionFixture()
    starting.dsp.readinessFailures = [.starting, .starting]
    try await starting.start()
    try check(starting.engine.state == .active("home") && starting.dsp.starts == 1 && starting.dsp.verifies == 3,
              "Starting companion retries readiness finitely without restarting its service")
    try starting.noRoutes("Starting-only readiness retry cannot change output")
    await starting.engine.shutdown()

    let expiredReadiness = CompanionFixture()
    expiredReadiness.dsp.readinessFailures = [.starting, .unavailable("Readiness became unavailable")]
    try await expiredReadiness.start()
    if case .failed = expiredReadiness.engine.state {} else { throw CheckFailure.failed("Starting followed by unavailable must terminate companion readiness") }
    expiredReadiness.engine.handle(.devicesChanged); await expiredReadiness.drain()
    try check(expiredReadiness.dsp.starts == 1 && expiredReadiness.dsp.verifies == 2 && !expiredReadiness.engine.recovering,
              "Unavailable ends Starting readiness retry without restarting or watching")
    await expiredReadiness.engine.shutdown()
}

@MainActor private func checkCompanionSelectionIsFixed() async throws {
    let unselected = CompanionFixture(multiple: true)
    try await unselected.start()
    try check(unselected.engine.state == .needsSelection && unselected.dsp.calls.isEmpty,
              "Multiple companion profiles require explicit selection")
    unselected.audio.value.devices.removeAll { $0.uid == "other-playback" }
    unselected.engine.handle(.devicesChanged); await unselected.drain()
    try check(unselected.engine.state == .needsSelection && unselected.dsp.calls.isEmpty,
              "Hardware availability cannot choose among configured companion profiles")
    await unselected.engine.shutdown()
    let selected = CompanionFixture(selected: "home", multiple: true)
    try await selected.start()
    selected.losePrimary(); await selected.drain()
    selected.engine.handle(.devicesChanged); await selected.drain()
    try check(selected.engine.selectedID == "home" && selected.dsp.starts == 1,
              "Other available profile cannot take over the lost selected companion")
    selected.reconnectPrimary(); await selected.drain()
    try check(selected.engine.state == .active("home") && !selected.dsp.calls.contains("start:other"),
              "Only the fixed selected companion can resume")
    try selected.noRoutes("Fixed companion selection does not acquire route ownership")
    await selected.engine.shutdown()
}

@MainActor private func checkCompanionHeldStartup() async throws {
    let f = CompanionFixture()
    let barrier = CompanionBarrier(); f.dsp.startBarrier = barrier
    try f.engine.start()
    try await eventually("Companion startup barrier was not entered") { barrier.entered }
    f.audio.value.outputUID = "capture"; f.engine.handle(.outputChanged)
    f.audio.value.outputUID = "built"; f.engine.handle(.outputChanged)
    await f.drain()
    try check(f.dsp.starts == 1 && !barrier.completed, "Output observation cannot supersede a held companion startup")
    barrier.release()
    try await eventually("Companion startup did not retain authority after output changes") { f.engine.state == .active("home") }
    try check(f.dsp.starts == 1 && f.engine.permitsDSPControls(profileID: "home"), "Held startup completes once with DSP authority on physical output")
    await f.engine.shutdown()
    try f.noRoutes("Output changes during held companion startup and shutdown remain observation-only")
}

@MainActor private func checkCompanionTransitionDrainsCommand() async throws {
    let f = CompanionFixture(automaticSwitching: true)
    try await f.start()
    let barrier = CompanionBarrier()
    var commandWrites = 0
    let command = Task { @MainActor in
        try await f.engine.performDSPControl(profileID: "home") {
            try await barrier.wait(); commandWrites += 1
        }
    }
    try await eventually("Companion transition command did not begin") { barrier.entered }
    try f.engine.setAutomaticSwitching(false, companionMode: .forceOn, profileID: "home")
    try check(!f.engine.permitsDSPControls(profileID: "home") && f.audio.outputWrites == ["capture"],
              "Disabling routing invalidates DSP admission and waits for held command before relinquishing ownership")
    f.engine.handle(.outputChanged); await f.drain()
    try check(f.audio.outputWrites == ["capture"] && !barrier.completed && f.store.record?.ownsOutput == true,
              "Output notification cannot bypass companion transition command drain or clear ownership early")
    barrier.release()
    if case .success = await command.result { throw CheckFailure.failed("Companion transition must cancel stale DSP command") }
    try await eventually("Drained routing disable did not activate companion") {
        f.engine.state == .active("home") && f.store.record == nil && f.engine.permitsDSPControls(profileID: "home")
    }
    try check(commandWrites == 0 && f.audio.outputWrites == ["capture"] && f.audio.alertWrites == ["capture"]
              && f.audio.value.outputUID == "capture" && f.audio.value.alertUID == "capture",
              "Canceled command performs no later write and companion entry relinquishes routes without changing outputs")
    await f.engine.shutdown()
    try check(f.audio.outputWrites == ["capture"] && f.audio.alertWrites == ["capture"],
              "Companion shutdown after mode transition cannot restore relinquished outputs")
}

@MainActor private func checkCompanionEntryPreservesSelectedOutputs() async throws {
    for output in ["capture", "phones"] {
        for alert in ["capture", "built"] {
            let f = CompanionFixture(automaticSwitching: true)
            try await f.start()
            // Include manual departures whose property notifications have not
            // reached the controller before the explicit policy command.
            f.audio.value.outputUID = output; f.audio.value.alertUID = alert
            try f.engine.setAutomaticSwitching(false, companionMode: .forceOn, profileID: "home")
            await f.drain()
            try check(f.engine.state == .active("home") && f.engine.routingError == nil && f.store.record == nil,
                      "Companion entry clears persisted normal and alert ownership")
            try check(f.audio.value.outputUID == output && f.audio.value.alertUID == alert
                      && f.audio.outputWrites == ["capture"] && f.audio.alertWrites == ["capture"]
                      && f.dsp.calls == ["start:home", "verify:home"],
                      "Companion entry preserves every selected normal and alert output and keeps verified DSP ready")
            f.engine.setMode(.forceOff); await f.drain()
            try check(f.engine.state == .idle && f.dsp.stops == 1, "Companion Off stops DSP after output-preserving entry")
            f.engine.setMode(.forceOn, profileID: "home"); await f.drain()
            try check(f.engine.state == .active("home"), "Companion On starts DSP after output-preserving entry")
            await f.engine.shutdown()
            try check(f.audio.value.outputUID == output && f.audio.value.alertUID == alert
                      && f.audio.outputWrites == ["capture"] && f.audio.alertWrites == ["capture"] && f.store.record == nil,
                      "Later companion Off, On and Quit never assign relinquished normal or alert outputs")
        }
    }
}

@MainActor private func checkCompanionEntryDrainsRoutingStartup() async throws {
    let f = CompanionFixture(automaticSwitching: true)
    let barrier = CompanionBarrier(); f.dsp.startBarrier = barrier
    try f.engine.start()
    try await eventually("Routing startup barrier was not entered before companion entry") { barrier.entered }
    try f.engine.setAutomaticSwitching(false, companionMode: .forceOn, profileID: "home")
    await f.drain()
    try check(!barrier.completed && f.dsp.starts == 1 && f.dsp.stops == 0 && !f.engine.permitsDSPControls(profileID: "home"),
              "Companion entry drains canceled routing startup before its own lifecycle work")
    try f.noRoutes("Companion entry cannot acquire output while canceled routing startup is held")
    f.dsp.startBarrier = nil; barrier.release()
    try await eventually("Companion entry did not complete after canceled routing startup drained") { f.engine.state == .active("home") }
    try check(f.dsp.calls == ["start:home", "stop:home", "start:home", "verify:home"] && f.store.record == nil && f.store.saves.isEmpty,
              "Only final companion startup verifies readiness, without route acquisition or invented ownership")
    await f.engine.shutdown()
    try f.noRoutes("Companion entry from held routing startup and later Quit preserve outputs")
}

@MainActor private func checkCompanionRapidToggleRestoresAuthority() async throws {
    let f = CompanionFixture(automaticSwitching: true)
    try await f.start()
    var controlObservations: [Bool] = []
    f.engine.onControlChange = { controlObservations.append(f.engine.permitsDSPControls(profileID: "home")) }
    try f.engine.setAutomaticSwitching(false, companionMode: .forceOn, profileID: "home")
    try check(!f.engine.permitsDSPControls(profileID: "home"), "Queued routing disable immediately revokes DSP admission")
    try f.engine.setAutomaticSwitching(true)
    await f.drain()
    try check(f.engine.automaticSwitching && f.engine.state == .active("home") && f.engine.permitsDSPControls(profileID: "home"),
              "Rapid disable then enable restores active routing command authority when the final transition reuses its service")
    try check(controlObservations.contains(false) && controlObservations.last == true,
              "Rapid toggle publishes revoked and restored control authority to observers")
    try check(f.audio.outputWrites == ["capture"] && f.audio.alertWrites == ["capture"] && f.dsp.calls == ["start:home", "verify:home"],
              "Superseded companion entry cannot relinquish routes or restart a service owned by final enabled policy")
    f.engine.onControlChange = nil
    await f.engine.shutdown()
}

@MainActor private func checkCompanionImmediateDisableShutdownRelinquishesOwnership() async throws {
    let f = CompanionFixture(automaticSwitching: true)
    try await f.start()
    try f.engine.setAutomaticSwitching(false, companionMode: .forceOn, profileID: "home")
    // No yield lets the queued companion entry run before shutdown owns it.
    await f.engine.shutdown()
    try check(f.audio.outputWrites == ["capture"] && f.audio.alertWrites == ["capture"] && f.store.record == nil
              && f.audio.value.outputUID == "capture" && f.audio.value.alertUID == "capture",
              "Immediate shutdown consumes pending companion entry by clearing ownership without changing normal or alert output")
    try check(f.dsp.calls == ["start:home", "verify:home", "stop:home"],
              "Immediate disable then shutdown cancels companion startup and stops the managed service once")
    f.engine.handle(.outputChanged); f.engine.retry()
    await f.drain()
    try check(f.audio.outputWrites == ["capture"] && f.audio.alertWrites == ["capture"],
              "Late notifications cannot assign outputs after immediate companion shutdown")
}

@MainActor private func checkCompanionUnavailableExplicitOnWaitsForHardware() async throws {
    let f = CompanionFixture(mode: .forceOff, selected: "home")
    f.audio.value.devices.removeAll { $0.uid == "playback" }
    try await f.start()
    f.engine.setMode(.forceOn, profileID: "home"); await f.drain()
    try check(f.engine.mode == .forceOn && f.engine.selectedID == "home" && f.dsp.calls.isEmpty,
              "Explicit companion On with absent required hardware retains intent without attempting startup")
    f.engine.handle(.outputChanged); f.engine.handle(.woke); await f.drain()
    try check(f.dsp.calls.isEmpty, "Output and wake notifications cannot attempt unavailable explicit companion On")
    f.reconnectPrimary(); await f.drain()
    try check(f.engine.state == .active("home") && f.dsp.starts == 1,
              "Explicit companion On waits for a genuine device availability event before one startup")
    await f.engine.shutdown()
    try f.noRoutes("Unavailable explicit companion On and reconnect perform no output writes")
}

@MainActor private func checkCompanionHeldStartupShutdown() async throws {
    let f = CompanionFixture()
    let barrier = CompanionBarrier(); f.dsp.startBarrier = barrier
    try f.engine.start()
    try await eventually("Shutdown companion startup barrier was not entered") { barrier.entered }
    var shutdownFinished = false
    let shutdown = Task { @MainActor in await f.engine.shutdown(); shutdownFinished = true }
    await f.drain()
    try check(!shutdownFinished && f.dsp.stops == 0 && !f.engine.permitsDSPControls(profileID: "home"),
              "Companion shutdown closes authority and drains held startup before stopping its managed job")
    barrier.release()
    try await eventually("Companion shutdown did not drain held startup") { shutdownFinished }
    await shutdown.value
    try check(f.dsp.calls == ["start:home", "stop:home"], "Canceled companion startup cannot verify readiness or reactivate before shutdown stop")
    try f.noRoutes("Shutdown draining held companion startup never changes output")
}

@MainActor private func checkCompanionHeldStartupRoutingHandoff() async throws {
    let f = CompanionFixture()
    let barrier = CompanionBarrier(); f.dsp.startBarrier = barrier
    try f.engine.start()
    try await eventually("Routing handoff companion startup barrier was not entered") { barrier.entered }
    try f.engine.setAutomaticSwitching(true)
    await f.drain()
    try check(f.engine.automaticSwitching && f.dsp.starts == 1 && f.dsp.stops == 0 && f.audio.outputWrites.isEmpty,
              "Routing handoff waits for canceled held companion startup before lifecycle or route acquisition")
    f.dsp.startBarrier = nil
    barrier.release()
    try await eventually("Routing handoff did not activate after held companion startup drained") { f.engine.state == .active("home") && f.audio.value.outputUID == "capture" }
    try check(f.engine.permitsDSPControls(profileID: "home") && f.dsp.verifies == 1 && f.audio.outputWrites == ["capture"],
              "Only the final routing session verifies readiness and acquires output after companion startup cancellation")
    await f.engine.shutdown()
}

@MainActor private func checkCompanionOwnedRelinquishment() async throws {
    let record = RouteRecord(profileID: "home", captureUID: "capture", previousOutputUID: "phones",
                             previousAlertUID: "built", ownsOutput: true, ownsAlerts: true)
    let f = CompanionFixture(persisted: record, output: "capture")
    f.audio.value.alertUID = "capture"
    try await f.start()
    try check(f.engine.state == .active("home") && f.audio.outputWrites.isEmpty && f.audio.alertWrites.isEmpty && f.store.record == nil
              && f.audio.value.outputUID == "capture" && f.audio.value.alertUID == "capture",
              "Disabled startup relinquishes persisted ownership while preserving selected capture normal and alert outputs")
    f.audio.value.outputUID = "capture"; f.engine.handle(.outputChanged); await f.drain()
    try check(f.audio.outputWrites.isEmpty && f.store.record == nil, "Later virtual output choice cannot recreate companion ownership")
    try f.engine.setAutomaticSwitching(true)
    await f.drain()
    try check(f.engine.automaticSwitching && f.engine.state == .active("home") && f.engine.routingError == nil
              && f.store.record?.previousOutputUID == "built" && f.store.record?.ownsOutput == true
              && f.store.record?.ownsAlerts == true && f.audio.outputWrites.isEmpty && f.audio.alertWrites.isEmpty,
              "Re-enabling switching safely reacquires capture-selected routes after persisted companion ownership was relinquished")
    try f.engine.setAutomaticSwitching(false, companionMode: .automatic, profileID: "home")
    await f.drain()
    try check(!f.engine.automaticSwitching && f.engine.state == .active("home") && f.store.record == nil,
              "Disabling again relinquishes newly owned routes and retains selected companion")
    let writes = f.audio.outputWrites, alerts = f.audio.alertWrites
    await f.engine.shutdown()
    try check(f.audio.outputWrites == writes && f.audio.alertWrites == alerts, "Companion shutdown preserves output after ownership relinquishment")
}

@MainActor private func checkCompanionRelinquishmentFailureIsConsumed() async throws {
    let record = RouteRecord(profileID: "home", captureUID: "capture", previousOutputUID: "phones",
                             previousAlertUID: nil, ownsOutput: true, ownsAlerts: false)
    let f = CompanionFixture(persisted: record, output: "capture")
    f.store.saveFailuresRemaining = 1
    try await f.start()
    try check(f.engine.routingError != nil && f.store.saveAttempts == 1 && f.store.record != nil,
              "Failed durable companion ownership clearing surfaces its error and retains failed-save evidence")
    for _ in 0..<3 { f.engine.handle(.devicesChanged); f.engine.handle(.outputChanged) }
    f.engine.retry(); await f.drain()
    f.losePrimary(); await f.drain(); f.reconnectPrimary(); await f.drain()
    await f.engine.shutdown()
    try check(f.store.saveAttempts == 1, "Consumed relinquishment failure never retries persistence on companion events, retry, reconnect or shutdown")
    try f.noRoutes("Failed durable ownership clearing cannot authorize output writes during companion events, retry, reconnect or Quit")
}
