import Foundation
import AutoAudioCore

@MainActor private final class RecoveryAudio: AudioManaging {
    var value = AudioSnapshot(devices: [
        AudioDevice(uid: "built", name: "Speakers", hasOutput: true, isBuiltIn: true),
        AudioDevice(uid: "phones", name: "Phones", hasOutput: true),
        AudioDevice(uid: "interface", name: "Interface", hasOutput: true),
        AudioDevice(uid: "blackhole", name: "BlackHole", hasOutput: true)
    ], outputUID: "built", alertUID: "built")
    var outputWrites: [String] = []
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws { outputWrites.append(uid); value.outputUID = uid }
    func setAlertOutput(uid: String) throws { value.alertUID = uid }
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws {}
    func stopMonitoring() {}
}
@MainActor private final class RecoveryDSP: DSPManaging {
    var onFailure: (@MainActor (String) -> Void)?
    var starts = 0, verifies = 0, stops = 0
    var startError: Error?
    var readinessError: Error?
    var holdStart = false
    var cancelledStart = false
    var startBarrier: RecoveryBarrier?
    var readinessBarrier: RecoveryBarrier?
    func start(_ profile: Profile) async throws {
        starts += 1
        try await startBarrier?.wait()
        if holdStart {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelledStart = true; throw error }
        }
        if let startError { throw startError }
    }
    func verifyReadiness(_ profile: Profile) async throws {
        verifies += 1
        try await readinessBarrier?.wait()
        if let readinessError { throw readinessError }
    }
    func stop(_ profile: Profile) async throws { stops += 1 }
}
// Cancellation is observed immediately, but completion requires explicit release.
// This models DSP work whose underlying command must drain before service stop.
@MainActor private final class RecoveryBarrier {
    var started = false
    var cancelled = false
    var completed = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async throws {
        started = true
        await withTaskCancellationHandler {
            if !released {
                await withCheckedContinuation { continuation = $0 }
            }
        } onCancel: {
            Task { @MainActor in self.cancelled = true }
        }
        completed = true
        try Task.checkCancellation()
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
@MainActor private final class RecoveryStore: RouteStoring {
    var record: RouteRecord?
    func load() throws -> RouteRecord? { record }
    func save(_ record: RouteRecord?) throws { self.record = record }
}
@MainActor private final class RecoveryClock: TransitionSleeping {
    var now: TimeInterval = 0
    var waits: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    func sleep(milliseconds: Int) async throws {
        try Task.checkCancellation()
        guard milliseconds > 0 else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waits[id] = (now + Double(milliseconds) / 1000, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.waits.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    func advance(_ seconds: TimeInterval) {
        now += seconds
        for id in Array(waits.keys) {
            if let wait = waits[id], wait.0 <= now + 0.000001 {
                waits.removeValue(forKey: id)
                wait.1.resume()
            }
        }
    }
}
@MainActor private final class RecoveryFixture {
    let audio = RecoveryAudio(), dsp = RecoveryDSP(), clock = RecoveryClock(), store = RecoveryStore()
    lazy var engine: Reconciler = {
        let profile = Profile(id: "home", name: "Home", triggerUID: "interface", captureUID: "blackhole",
                              playbackUID: "interface", launchAgentLabel: "test", launchAgentPath: "/unused",
                              websocketURL: "ws://localhost:1234", expectedCaptureDevice: "blackhole",
                              expectedPlaybackDevice: "interface", startupDelayMilliseconds: 0)
        return Reconciler(profiles: [profile], audio: audio, dsp: dsp, store: store,
                          sleeper: clock, now: { self.clock.now })
    }()
    func settle() async { for _ in 0..<200 { await Task.yield() } }
    func advance(_ seconds: TimeInterval) async { clock.advance(seconds); await settle() }
    func start() async throws { try engine.start(); await settle() }
    func finish() async throws {
        await engine.shutdown(); await settle()
        try check(clock.waits.isEmpty, "No recovery timer survives shutdown")
    }
}

@MainActor private func checkShutdownDrainsRecovery(readiness: Bool) async throws {
    let fixture = RecoveryFixture()
    let barrier = RecoveryBarrier()
    let operation = readiness ? "readiness" : "start"
    var shutdown: Task<Void, Never>?
    var shutdownFinished = false
    do {
        if readiness { fixture.dsp.readinessError = DSPFailure.starting }
        else { fixture.dsp.startError = DSPFailure.unavailable("not running") }
        try await fixture.start()
        let passiveFailure = fixture.dsp.onFailure
        if readiness {
            fixture.dsp.readinessError = nil
            fixture.dsp.readinessBarrier = barrier
            await fixture.advance(0.5)
        } else {
            fixture.dsp.startError = nil
            fixture.dsp.startBarrier = barrier
            await fixture.advance(1)
        }
        try check(barrier.started && !barrier.completed, "Recovery \(operation) suspends inside the DSP command")
        let starts = fixture.dsp.starts, verifies = fixture.dsp.verifies
        let outputs = fixture.audio.outputWrites
        shutdown = Task { @MainActor in
            await fixture.engine.shutdown()
            shutdownFinished = true
        }
        await fixture.settle()
        try check(barrier.cancelled && !barrier.completed,
                  "Shutdown cancels recovery \(operation) while its DSP command remains held")
        try check(!shutdownFinished && fixture.dsp.stops == 0,
                  "Shutdown waits for recovery \(operation) before returning or stopping DSP")
        passiveFailure?("Late failure while recovery \(operation) drains")
        fixture.engine.reportDSPFailure(profileID: "home", reason: "Late recovery command failure")
        fixture.audio.value.devices.append(AudioDevice(uid: "late", name: "Late device", hasOutput: true))
        fixture.engine.handle(.devicesChanged)
        fixture.engine.handle(.woke)
        fixture.engine.retry()
        await fixture.settle()
        await fixture.advance(60)
        try check(!shutdownFinished && fixture.dsp.stops == 0 && !barrier.completed,
                  "Late work and elapsed deadlines cannot stop DSP before recovery \(operation) drains")
        try check(fixture.dsp.starts == starts && fixture.dsp.verifies == verifies
                  && fixture.audio.outputWrites == outputs && fixture.clock.waits.isEmpty,
                  "Shutdown rejects failure, device and retry work while recovery \(operation) drains")
        barrier.release()
        await shutdown?.value
        await fixture.settle()
        try check(shutdownFinished && barrier.completed && fixture.dsp.stops == 1,
                  "Shutdown stops DSP once after the cancelled recovery \(operation) completes")
        try check(fixture.engine.state == .idle && !fixture.engine.recovering
                  && fixture.audio.value.outputUID == "built" && fixture.clock.waits.isEmpty,
                  "Drained recovery \(operation) leaves idle physical audio with no timers")
        let finalOutputs = fixture.audio.outputWrites
        passiveFailure?("Obsolete failure after recovery \(operation) shutdown")
        fixture.engine.reportDSPFailure(profileID: "home", reason: "Obsolete recovery failure")
        fixture.engine.handle(.devicesChanged)
        fixture.engine.handle(.woke)
        fixture.engine.retry()
        await fixture.settle()
        await fixture.advance(60)
        try check(fixture.dsp.starts == starts && fixture.dsp.verifies == verifies && fixture.dsp.stops == 1
                  && fixture.audio.outputWrites == finalOutputs && fixture.engine.state == .idle
                  && !fixture.engine.recovering && fixture.clock.waits.isEmpty,
                  "Late callbacks and retry cannot create work or timers after recovery \(operation) shutdown")
    } catch {
        // Release before awaiting cleanup, including failures before shutdown starts.
        barrier.release()
        if let shutdown { await shutdown.value }
        else { await fixture.engine.shutdown() }
        await fixture.settle()
        throw error
    }
}

@MainActor func runRecoveryChecks() async throws {
    // Starting must keep its process, then leave no recovery work after success.
    let ready = RecoveryFixture()
    ready.dsp.readinessError = DSPFailure.starting
    try await ready.start()
    try check(ready.dsp.starts == 1 && ready.dsp.verifies == 1, "Initial readiness attempted once")
    ready.dsp.readinessError = nil
    await ready.advance(0.5)
    try check(ready.engine.state == .active("home"), "Starting becomes Active on the next readiness check")
    try check(ready.dsp.starts == 1 && ready.dsp.stops == 0, "Starting never restarts the service")
    try check(ready.clock.waits.isEmpty, "Successful recovery cancels every timer")
    try await ready.finish()

    // A user-selected virtual output stays selected throughout a slow startup.
    for timeout in [false, true] {
        let manual = RecoveryFixture()
        try await manual.start()
        manual.audio.value.outputUID = "phones"
        manual.engine.handle(.outputChanged); await manual.settle()
        manual.dsp.readinessError = DSPFailure.starting
        manual.audio.value.outputUID = "blackhole"
        manual.engine.handle(.outputChanged); await manual.settle()
        try check(manual.audio.value.outputUID == "blackhole", "Manual BlackHole selection survives Starting")
        if timeout {
            await manual.advance(30)
            try check(manual.audio.value.outputUID == "phones", "Slow manual startup restores its original output on timeout")
        } else {
            manual.dsp.readinessError = nil
            await manual.advance(0.5)
            try check(manual.engine.state == .active("home"), "Manual virtual startup recovers without a physical detour")
            try check(manual.store.record?.previousOutputUID == "phones", "Recovery preserves the original return route")
        }
        try await manual.finish()
        try check(manual.audio.value.outputUID == "phones", "Manual virtual startup preserves restoration")
    }

    // A real failure uses backoff, and duplicate notifications cannot extend 30s.
    let expiry = RecoveryFixture()
    expiry.dsp.startError = DSPFailure.unavailable("not running")
    try await expiry.start()
    for (delay, count) in [(1.0, 2), (2.0, 3), (4.0, 4)] {
        await expiry.advance(delay)
        try check(expiry.dsp.starts == count, "Crash recovery follows 1, 2, 4 second backoff")
        expiry.engine.handle(.devicesChanged)
        expiry.engine.handle(.woke)
        expiry.dsp.onFailure?("duplicate")
        await expiry.settle()
    }
    for _ in 0..<5 { await expiry.advance(4) }
    await expiry.advance(3)
    guard case .failed(let message) = expiry.engine.state else { throw CheckFailure.failed("Recovery must expire at 30 seconds") }
    try check(message.contains("30 seconds"), "Expiry has a useful error")
    try check(expiry.audio.value.outputUID == "built" && expiry.clock.waits.isEmpty, "Expiry leaves physical audio and no timers")
    let attempts = expiry.dsp.starts
    expiry.audio.value.devices.append(AudioDevice(uid: "unrelated", name: "Unrelated", hasOutput: true))
    expiry.engine.handle(.devicesChanged)
    expiry.engine.handle(.woke)
    await expiry.settle()
    await expiry.advance(60)
    try check(expiry.dsp.starts == attempts, "Unrelated device/wake events cannot restart an expired window")
    try await expiry.finish()

    // Passive failure restores first, then adopts/restarts and verifies before routing.
    let crash = RecoveryFixture()
    try await crash.start()
    crash.dsp.onFailure?("connection lost")
    try check(crash.audio.value.outputUID == "built", "Observed crash immediately restores physical output")
    await crash.settle(); await crash.advance(1)
    try check(crash.engine.state == .active("home") && crash.dsp.starts == 2, "Observed crash recovers")
    try await crash.finish()

    // Recovery while output is explicitly bypassed never acquires BlackHole.
    let bypassed = RecoveryFixture()
    try await bypassed.start()
    bypassed.engine.release(); await bypassed.settle()
    try check(bypassed.engine.state == .active("home") && bypassed.audio.value.outputUID == "built",
              "Release retains verified DSP and restores physical output")
    bypassed.audio.outputWrites.removeAll()
    bypassed.dsp.onFailure?("connection lost while bypassed")
    bypassed.audio.value.outputUID = "phones"
    bypassed.engine.handle(.outputChanged)
    await bypassed.settle(); await bypassed.advance(1)
    try check(bypassed.engine.released && bypassed.engine.state == .active("home"),
              "DSP recovery retains the bypass choice")
    try check(bypassed.audio.value.outputUID == "phones", "Recovery preserves the latest physical output")
    try check(!bypassed.audio.outputWrites.contains("blackhole"), "Bypassed recovery never reacquires BlackHole")
    try check(bypassed.dsp.starts == 2 && bypassed.dsp.stops == 0,
              "Bypassed recovery does not stop DSP or route to BlackHole")
    try await bypassed.finish()

    // Resume can itself enter recovery after a manually suspended service stops.
    for outcome in ["success", "expiry", "fatal"] {
        let resuming = RecoveryFixture()
        try await resuming.start()
        resuming.audio.value.outputUID = "phones"
        resuming.engine.handle(.outputChanged); await resuming.settle()
        try check(resuming.engine.state == .suspended, "Manual output change suspends DSP before Resume")
        resuming.dsp.startError = DSPFailure.unavailable("not running")
        if outcome == "fatal" { resuming.dsp.readinessError = SwitcherError.message("invalid DSP configuration") }
        try resuming.engine.resume(); await resuming.settle()
        try check(resuming.engine.routingRestoring, "Resume reports route work while DSP is starting or recovering")
        switch outcome {
        case "success":
            resuming.dsp.startError = nil
            await resuming.advance(1)
            try check(resuming.engine.state == .active("home") && resuming.audio.value.outputUID == "blackhole",
                      "Recovered Resume reacquires the processed route")
        case "expiry":
            await resuming.advance(30)
            guard case .failed = resuming.engine.state else { throw CheckFailure.failed("Failed Resume must expire") }
        default:
            resuming.dsp.startError = nil
            await resuming.advance(1)
            guard case .failed = resuming.engine.state else { throw CheckFailure.failed("Fatal Resume recovery must fail") }
        }
        try check(!resuming.engine.routingRestoring, "Settled Resume recovery clears the in-progress route state")
        if outcome != "success" { try check(resuming.audio.value.outputUID == "phones", "Failed Resume preserves the physical output") }
        try await resuming.finish()
    }

    for action in ["off", "device", "manual", "quit"] {
        let cancelled = RecoveryFixture()
        cancelled.dsp.readinessError = DSPFailure.starting
        try await cancelled.start()
        switch action {
        case "off": cancelled.engine.setMode(.forceOff)
        case "device":
            cancelled.audio.value.devices.removeAll { $0.uid == "interface" }
            cancelled.engine.handle(.devicesChanged)
        case "manual":
            cancelled.audio.value.outputUID = "phones"
            cancelled.engine.handle(.outputChanged)
        default: await cancelled.engine.shutdown()
        }
        await cancelled.settle(); await cancelled.advance(31)
        try check(cancelled.dsp.verifies == 1, "\(action) cancels recovery checks")
        try check(cancelled.clock.waits.isEmpty, "\(action) leaves no recovery timer")
        if action == "manual" { try check(cancelled.audio.value.outputUID == "phones", "Preserve manual output") }
        try await cancelled.finish()
    }

    // Deadline and Force Off must interrupt an in-flight command, not only its delay.
    for expire in [false, true] {
        let inFlight = RecoveryFixture()
        inFlight.dsp.startError = DSPFailure.unavailable("not running")
        try await inFlight.start()
        inFlight.dsp.startError = nil; inFlight.dsp.holdStart = true
        await inFlight.advance(1)
        if expire { await inFlight.advance(29) }
        else { inFlight.engine.setMode(.forceOff); await inFlight.settle() }
        try check(inFlight.dsp.cancelledStart, "Deadline/Force Off cancels the running service command")
        try check(inFlight.audio.value.outputUID == "built", "Cancelled operation cannot acquire the route")
        try check(inFlight.clock.waits.isEmpty, "Cancelled in-flight command leaves no watchdog")
        try await inFlight.finish()
    }
    try await checkShutdownDrainsRecovery(readiness: false)
    try await checkShutdownDrainsRecovery(readiness: true)
    print("Recovery checks: 13 scenarios passed, including manual virtual startup, exact deadline, in-flight cancellation and shutdown draining")
}
