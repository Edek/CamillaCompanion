import Foundation
import AutoAudioCore

@MainActor private final class AuthorityAudio: AudioManaging {
    var value = AudioSnapshot(devices: [
        AudioDevice(uid: "phones", name: "Phones", hasOutput: true),
        AudioDevice(uid: "built", name: "Built in", hasOutput: true, isBuiltIn: true),
        AudioDevice(uid: "playback", name: "Playback", hasOutput: true),
        AudioDevice(uid: "capture", name: "Capture", hasOutput: true)
    ], outputUID: "phones", alertUID: "built")
    var outputWrites: [String] = []
    var alertWrites: [String] = []
    var monitoringStops = 0
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws { outputWrites.append(uid); value.outputUID = uid }
    func setAlertOutput(uid: String) throws { alertWrites.append(uid); value.alertUID = uid }
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws {}
    func stopMonitoring() { monitoringStops += 1 }
}

@MainActor private final class AuthorityDSP: DSPManaging {
    var onFailure: (@MainActor (String) -> Void)?
    var calls: [String] = []
    func start(_ profile: Profile) async throws { calls.append("start") }
    func verifyReadiness(_ profile: Profile) async throws { calls.append("verify") }
    func stop(_ profile: Profile) async throws { calls.append("stop") }
}

@MainActor private final class AuthorityStore: RouteStoring {
    var record: RouteRecord?
    func load() throws -> RouteRecord? { record }
    func save(_ record: RouteRecord?) throws { self.record = record }
}

/// Suspension deliberately ignores cancellation until explicitly released, so
/// assertions do not depend on a canceled operation completing immediately.
@MainActor private final class AuthorityBarrier {
    var started = false
    var completed = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
        completed = true
        try Task.checkCancellation()
    }
    func release() { let waiting = continuation; continuation = nil; waiting?.resume() }
}

@MainActor private final class AuthoritySleeper: TransitionSleeping {
    var debounce: AuthorityBarrier?
    var sleeps: [Int] = []
    func sleep(milliseconds: Int) async throws {
        sleeps.append(milliseconds)
        try Task.checkCancellation()
        if milliseconds == 800, let debounce { try await debounce.wait() }
    }
}

@MainActor private final class AuthorityFixture {
    let audio = AuthorityAudio()
    let dsp = AuthorityDSP()
    let store = AuthorityStore()
    let sleeper = AuthoritySleeper()
    let profile = Profile(id: "authority", name: "Authority", triggerUID: "playback", captureUID: "capture",
        playbackUID: "playback", launchAgentLabel: "fixture", launchAgentPath: "/unused",
        websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture",
        expectedPlaybackDevice: "playback", routeAlerts: true, startupDelayMilliseconds: 0)
    lazy var engine = Reconciler(profiles: [profile], audio: audio, dsp: dsp, store: store, sleeper: sleeper,
        fallbackPreferences: .init(profiles: [profile.id: .init(mode: .off)]))
    func start() async throws {
        try engine.start()
        try await eventually("Authority fixture did not activate") { engine.state == .active(profile.id) }
        try check(audio.outputWrites == ["capture"] && audio.alertWrites == ["capture"],
            "Authority fixture begins with independently owned normal and alert routes")
    }
    func finish() async throws {
        var finished = false
        let shutdown = Task { @MainActor in await engine.shutdown(); finished = true }
        try await eventually("Authority fixture shutdown did not finish") { finished }
        await shutdown.value
    }
}

private enum AuthorityOperationFailure: Error { case rejected }

@MainActor func runReconcilerWorkAuthorityChecks() async throws {
    try await checkSupersededDebounceCannotReactivate()
    try await checkExplicitOffSurvivesNotificationsDuringMutation()
    try await checkShutdownDrainsMutationAndRejectsLateWork()
    try await checkLeaseAdmissionCallbackCanInvalidateWork()
    try await checkFailedLeaseReleasesAuthorityBeforeCallback()
    print("Reconciler work authority checks passed: superseded debounce, carried explicit policy, shutdown mutation drain, callback invalidation and failed-lease cleanup.")
}

@MainActor private func checkSupersededDebounceCannotReactivate() async throws {
    let fixture = AuthorityFixture()
    try await fixture.start()
    let debounce = AuthorityBarrier()
    fixture.sleeper.debounce = debounce
    fixture.engine.handle(.devicesChanged)
    try await eventually("Authority debounce did not suspend") { debounce.started }
    fixture.engine.handle(.devicesChanged)
    fixture.engine.setMode(.forceOff)
    try check(fixture.dsp.calls == ["start", "verify"] && !debounce.completed,
        "Explicit Off waits behind canceled debounced work rather than overlapping its transition")
    debounce.release()
    try await eventually("Superseding Off did not finish") { fixture.engine.state == .idle && fixture.dsp.calls.last == "stop" }
    try check(fixture.dsp.calls == ["start", "verify", "stop"] && fixture.audio.outputWrites == ["capture", "phones"],
        "Two superseded automatic requests cannot restart DSP or reacquire capture after explicit Off")
    try check(fixture.store.record == nil && fixture.sleeper.sleeps.filter { $0 == 800 }.count == 1,
        "The obsolete debounce cannot install a second timer or retain route ownership")
    try await fixture.finish()
}

@MainActor private func checkExplicitOffSurvivesNotificationsDuringMutation() async throws {
    let fixture = AuthorityFixture()
    try await fixture.start()
    let mutation = AuthorityBarrier()
    var mutationFinished = false
    let command = Task { @MainActor in
        defer { mutationFinished = true }
        try await fixture.engine.performDSPControl(profileID: fixture.profile.id) { try await mutation.wait() }
    }
    try await eventually("Policy authority mutation did not suspend") { mutation.started }
    fixture.engine.setMode(.forceOff)
    fixture.audio.value.devices.removeAll { $0.uid == "playback" }
    fixture.engine.handle(.devicesChanged)
    fixture.engine.handle(.outputChanged)
    fixture.engine.handle(.devicesChanged)
    try check(fixture.dsp.calls == ["start", "verify"] && fixture.audio.outputWrites == ["capture"],
        "Device notifications cannot overlap the canceled mutation with Off restoration")
    mutation.release()
    try await eventually("Policy authority mutation did not finish") { mutationFinished }
    if case .success = await command.result { throw CheckFailure.failed("Superseded policy mutation succeeded") }
    try await eventually("Explicit policy was lost during device notifications") { fixture.engine.state == .idle }
    try check(fixture.audio.outputWrites == ["capture", "phones"] && fixture.audio.alertWrites == ["capture", "built"],
        "Explicit Off retains restoration through device notifications even when passive Fallback Off would relinquish")
    try check(fixture.store.record == nil && fixture.dsp.calls == ["start", "verify", "stop"] && !fixture.engine.recovering,
        "Carried explicit policy releases both owned routes and stops once without recovery")
    try await fixture.finish()
}

@MainActor private func checkShutdownDrainsMutationAndRejectsLateWork() async throws {
    let fixture = AuthorityFixture()
    try await fixture.start()
    let passiveFailure = fixture.dsp.onFailure
    let mutation = AuthorityBarrier()
    var commandFinished = false
    var mutationWrites = 0
    let command = Task { @MainActor in
        defer { commandFinished = true }
        try await fixture.engine.performDSPControl(profileID: fixture.profile.id, allowsProcessingRestart: true) {
            try await mutation.wait()
            mutationWrites += 1
        }
    }
    try await eventually("Shutdown authority mutation did not suspend") { mutation.started }
    var shutdownFinished = false
    let shutdown = Task { @MainActor in await fixture.engine.shutdown(); shutdownFinished = true }
    try await eventually("Shutdown admission was not revoked") { fixture.audio.monitoringStops == 1 }
    passiveFailure?("Late socket failure while shutdown drains mutation")
    fixture.engine.handle(.devicesChanged)
    try check(!shutdownFinished && fixture.dsp.calls == ["start", "verify"] && fixture.audio.outputWrites == ["capture"],
        "Shutdown closes admission and waits for canceled DSP work before service stop or restoration")
    mutation.release()
    try await eventually("Shutdown did not drain the canceled mutation") { commandFinished && shutdownFinished }
    if case .success = await command.result { throw CheckFailure.failed("Shutdown-canceled mutation succeeded") }
    await shutdown.value
    try check(mutationWrites == 0 && fixture.dsp.calls == ["start", "verify", "stop"],
        "Canceled restart mutation performs no later write or passive rearm before shutdown stops once")
    try check(fixture.audio.outputWrites == ["capture", "phones"] && fixture.audio.alertWrites == ["capture", "built"]
        && fixture.store.record == nil && !fixture.engine.dspControlBusy && !fixture.engine.processingReconfiguration,
        "Shutdown clears the lease and restores independently owned routes after the command drains")
    let outputs = fixture.audio.outputWrites, alerts = fixture.audio.alertWrites, calls = fixture.dsp.calls
    passiveFailure?("Obsolete socket callback after shutdown")
    fixture.engine.reportDSPFailure(profileID: fixture.profile.id, reason: "Late command failure")
    fixture.engine.handle(.devicesChanged)
    fixture.engine.retry()
    try check(!fixture.engine.recovering && !fixture.engine.permitsDSPControls(profileID: fixture.profile.id)
        && fixture.audio.outputWrites == outputs && fixture.audio.alertWrites == alerts && fixture.dsp.calls == calls,
        "Obsolete failure and device callbacks cannot recover or write after shutdown")
}

@MainActor private func checkLeaseAdmissionCallbackCanInvalidateWork() async throws {
    let fixture = AuthorityFixture()
    try await fixture.start()
    var invalidated = false
    var dispatched = false
    fixture.engine.onControlChange = {
        if fixture.engine.dspControlBusy && !invalidated {
            invalidated = true
            fixture.engine.setMode(.forceOff)
        }
    }
    var rejected = false
    do {
        try await fixture.engine.performDSPControl(profileID: fixture.profile.id) { dispatched = true }
    } catch is CancellationError { rejected = true }
    fixture.engine.onControlChange = nil
    try check(invalidated && rejected && !dispatched && !fixture.engine.dspControlBusy,
        "A synchronous Busy callback can invalidate an admitted lease before any DSP operation starts")
    try await eventually("Callback-invalidated Off did not finish") { fixture.engine.state == .idle }
    try check(fixture.dsp.calls == ["start", "verify", "stop"] && fixture.store.record == nil,
        "Callback invalidation preserves one lifecycle stop and releases ownership")
    fixture.engine.setMode(.forceOn, profileID: fixture.profile.id)
    try await eventually("New work did not acquire authority after callback invalidation") { fixture.engine.state == .active(fixture.profile.id) }
    try await fixture.engine.performDSPControl(profileID: fixture.profile.id) { dispatched = true }
    try check(dispatched && !fixture.engine.dspControlBusy, "Invalidated lease cleanup permits a later valid command")
    try await fixture.finish()
}

@MainActor private func checkFailedLeaseReleasesAuthorityBeforeCallback() async throws {
    let fixture = AuthorityFixture()
    try await fixture.start()
    var observedBusy = false
    var cleanupObservations: [Bool] = []
    fixture.engine.onControlChange = {
        if fixture.engine.dspControlBusy { observedBusy = true }
        else if observedBusy {
            cleanupObservations.append(!fixture.engine.processingReconfiguration
                && fixture.engine.permitsDSPControls(profileID: fixture.profile.id))
        }
    }
    var preservedFailure = false
    do {
        try await fixture.engine.performDSPControl(profileID: fixture.profile.id, allowsProcessingRestart: true) {
            throw AuthorityOperationFailure.rejected
        }
    } catch AuthorityOperationFailure.rejected { preservedFailure = true }
    fixture.engine.onControlChange = nil
    try check(preservedFailure && cleanupObservations == [true] && !fixture.engine.dspControlBusy,
        "Failed lease preserves its operation error and publishes cleanup after restart flags and command authority clear")
    try check(fixture.dsp.calls == ["start", "verify", "verify"] && fixture.audio.outputWrites == ["capture"],
        "A failed restart-capable command rearms once without route restoration or service restart")
    try await fixture.engine.performDSPControl(profileID: fixture.profile.id) {}
    try check(!fixture.engine.dspControlBusy && fixture.engine.state == .active(fixture.profile.id),
        "A following command is admitted after failure cleanup")
    try await fixture.finish()
}
