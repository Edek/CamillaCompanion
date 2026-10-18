import XCTest
@testable import AutoAudioCore

@MainActor private final class TestAudio: AudioManaging {
    var value = AudioSnapshot(devices: [
        AudioDevice(uid: "built", name: "Speakers", hasOutput: true, isBuiltIn: true),
        AudioDevice(uid: "phones", name: "Headphones", hasOutput: true),
        AudioDevice(uid: "interface", name: "Interface", hasOutput: true),
        AudioDevice(uid: "blackhole", name: "BlackHole", hasOutput: true)
    ], outputUID: "phones", alertUID: "built")
    var failedUIDs = Set<String>()
    var outputWrites: [String] = []
    var alertWrites: [String] = []
    var callback: (@MainActor (AudioEvent) -> Void)?
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws {
        if failedUIDs.contains(uid) { throw SwitcherError.message("set failed") }
        outputWrites.append(uid); value.outputUID = uid
    }
    func setAlertOutput(uid: String) throws {
        if failedUIDs.contains(uid) { throw SwitcherError.message("set failed") }
        alertWrites.append(uid); value.alertUID = uid
    }
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws { callback = handler }
    func stopMonitoring() { callback = nil }
}

@MainActor private final class TestDSP: DSPManaging {
    var onFailure: (@MainActor (String) -> Void)?
    var failStart = false
    var failReadiness = false
    var failStop = false
    var onVerify: (() throws -> Void)?
    var holdStart = false
    var continuation: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    func start(_ profile: Profile) async throws {
        calls.append("start")
        if holdStart { await withCheckedContinuation { continuation = $0 } }
        if failStart { throw SwitcherError.message("start failed") }
    }
    func verifyReadiness(_ profile: Profile) async throws {
        calls.append("verify")
        try onVerify?()
        if failReadiness { throw SwitcherError.message("not ready") }
    }
    func stop(_ profile: Profile) async throws {
        calls.append("stop")
        if failStop { throw SwitcherError.message("stop failed") }
    }
}
@MainActor private final class TestStore: RouteStoring {
    var record: RouteRecord?
    var failRelinquish = false
    func load() throws -> RouteRecord? { record }
    func save(_ record: RouteRecord?) throws {
        if record == nil, failRelinquish { throw SwitcherError.message("route save failed") }
        self.record = record
    }
}
@MainActor private final class InstantSleeper: TransitionSleeping {
    func sleep(milliseconds: Int) async throws { try Task.checkCancellation() }
}

@MainActor final class ReconcilerTests: XCTestCase {
    private func profile(alerts: Bool = false) -> Profile {
        Profile(id: "home", name: "Home", triggerUID: "interface", captureUID: "blackhole",
                playbackUID: "interface", launchAgentLabel: "test", launchAgentPath: "/test",
                websocketURL: "ws://localhost:1234", expectedCaptureDevice: "blackhole",
                expectedPlaybackDevice: "interface", routeAlerts: alerts)
    }
    private func make(_ audio: TestAudio, _ dsp: TestDSP, _ store: TestStore, alerts: Bool = false) -> Reconciler {
        Reconciler(profiles: [profile(alerts: alerts)], audio: audio, dsp: dsp, store: store, sleeper: InstantSleeper())
    }
    private func drain() async { for _ in 0..<100 { await Task.yield() } }

    func testReleaseRestoresRouteAndResumesWithoutDSPLifecycleCalls() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        engine.release(); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        XCTAssertEqual(audio.value.outputUID, "phones")
        XCTAssertEqual(dsp.calls, ["start", "verify"])
        engine.retry(); engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        XCTAssertEqual(dsp.calls, ["start", "verify"])
        XCTAssertThrowsError(try engine.reconnect(profileID: "home"))
        try engine.resume(); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        XCTAssertEqual(audio.value.outputUID, "blackhole")
        XCTAssertEqual(dsp.calls, ["start", "verify"])
        await engine.shutdown()
    }

    func testReleaseResumesOnlyOnGenuineDeviceReconnect() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        engine.release(); await drain()
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.state, .suspended)
        audio.value.devices.append(AudioDevice(uid: "interface", name: "Interface", hasOutput: true))
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testReconnectIntentionallyStopsAndStartsSameDSP() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        try engine.reconnect(profileID: "home"); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        XCTAssertEqual(dsp.calls, ["start", "verify", "stop", "start", "verify"])
        XCTAssertEqual(audio.outputWrites, ["blackhole", "phones", "blackhole"])
        engine.setMode(.forceOff); await drain()
        XCTAssertThrowsError(try engine.reconnect(profileID: "home"))
        await engine.shutdown()
    }

    func testReconnectDuringStartSupersededByReleaseCannotRoute() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.holdStart = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        try engine.reconnect(profileID: "home")
        engine.release()
        dsp.continuation?.resume(); dsp.continuation = nil
        await drain()
        XCTAssertEqual(engine.state, .suspended)
        XCTAssertTrue(audio.outputWrites.isEmpty)
        XCTAssertEqual(dsp.calls, ["start", "stop"])
        await engine.shutdown()
    }

    func testStartupWithoutInterfacePreservesHeadphones() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.value.devices.removeAll { $0.uid == "interface" }
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(audio.value.outputUID, "phones")
        XCTAssertTrue(audio.outputWrites.isEmpty)
        XCTAssertTrue(dsp.calls.isEmpty)
        await engine.shutdown()
    }

    func testFailedStartNeverRoutesAndDoesNotRetry() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.failStart = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        XCTAssertEqual(engine.state, .failed("start failed"))
        XCTAssertEqual(audio.value.outputUID, "phones")
        XCTAssertEqual(dsp.calls, ["start", "stop"])
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(dsp.calls, ["start", "stop"])
        await engine.shutdown()
    }

    func testReadinessFailureNeverRoutes() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.failReadiness = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        XCTAssertEqual(engine.state, .failed("not ready"))
        XCTAssertNil(engine.routingError)
        XCTAssertTrue(audio.outputWrites.isEmpty)
        XCTAssertEqual(dsp.calls, ["start", "verify", "stop"])
        await engine.shutdown()
    }

    func testManualOutputSuspendsAndPreservesUserSelection() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store, alerts: true)
        try engine.start(); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        audio.value.outputUID = "phones"
        engine.handle(.outputChanged); await drain()
        XCTAssertEqual(engine.state, .suspended)
        XCTAssertEqual(audio.value.outputUID, "phones")
        XCTAssertEqual(audio.value.alertUID, "built")
        XCTAssertNil(store.record)
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.state, .suspended)
        engine.retry(); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testRestoreFailureFallsBackAndRestoresAlertsSeparately() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store, alerts: true)
        try engine.start(); await drain()
        audio.failedUIDs.insert("phones")
        engine.setMode(.forceOff); await drain()
        XCTAssertEqual(audio.value.outputUID, "built")
        XCTAssertEqual(audio.value.alertUID, "built")
        XCTAssertNil(store.record)
        XCTAssertEqual(engine.state, .idle)
        await engine.shutdown()
    }

    func testTotalRestoreFailureRetainsOwnershipAndService() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        audio.failedUIDs = ["phones", "built", "interface"]
        engine.setMode(.forceOff); await drain()
        XCTAssertEqual(audio.value.outputUID, "blackhole")
        XCTAssertEqual(store.record?.ownsOutput, true)
        XCTAssertFalse(dsp.calls.contains("stop"))
        audio.failedUIDs = []
        await engine.shutdown()
        XCTAssertNil(store.record)
    }

    func testRapidUnplugReplugSerializesStaleStartAndNewStart() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.holdStart = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        let device = audio.value.devices.remove(at: 2)
        engine.handle(.devicesChanged)
        audio.value.devices.append(device)
        engine.handle(.devicesChanged)
        dsp.holdStart = false
        dsp.continuation?.resume(); dsp.continuation = nil
        await drain()
        XCTAssertEqual(dsp.calls, ["start", "stop", "start", "verify"])
        XCTAssertEqual(audio.outputWrites, ["blackhole"])
        XCTAssertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testManualChangeDuringStartupCancelsRouteAcquisition() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.holdStart = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        audio.value.outputUID = "built"
        engine.handle(.outputChanged)
        dsp.continuation?.resume(); dsp.continuation = nil
        await drain()
        XCTAssertEqual(engine.state, .suspended)
        XCTAssertTrue(audio.outputWrites.isEmpty)
        XCTAssertEqual(dsp.calls, ["start", "stop"])
        await engine.shutdown()
    }

    func testStartupRecoversOrphanRoute() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.value.devices.removeAll { $0.uid == "interface" }
        audio.value.outputUID = "blackhole"
        store.record = RouteRecord(profileID: "home", captureUID: "blackhole", previousOutputUID: "phones",
                                   previousAlertUID: nil, ownsOutput: true, ownsAlerts: false)
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        XCTAssertEqual(audio.value.outputUID, "phones")
        XCTAssertNil(store.record)
        XCTAssertEqual(dsp.calls, ["stop"])
        await engine.shutdown()
    }
    func testAutomaticClearsManualSelection() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        engine.setMode(.forceOn, profileID: "missing")
        await drain()
        engine.setMode(.automatic)
        await drain()
        XCTAssertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testReconnectRetriesFailedStartupWithoutPeriodicWork() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.failStart = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        let device = audio.value.devices.remove(at: 2)
        engine.handle(.devicesChanged); await drain()
        dsp.failStart = false
        audio.value.devices.append(device)
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testMacOSFallbackOnUnplugDoesNotSuspendReconnect() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        let device = audio.value.devices.remove(at: 2)
        audio.value.outputUID = "built"
        engine.handle(.outputChanged)
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.state, .idle)
        audio.value.devices.append(device)
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testStartupAdoptsSavedRouteWithoutStoppingService() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.value.outputUID = "blackhole"
        store.record = RouteRecord(profileID: "home", captureUID: "blackhole", previousOutputUID: "phones",
                                   previousAlertUID: nil, ownsOutput: true, ownsAlerts: false)
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        XCTAssertEqual(engine.state, .active("home"))
        XCTAssertEqual(dsp.calls, ["start", "verify"])
        XCTAssertEqual(store.record?.previousOutputUID, "phones")
        await engine.shutdown()
        XCTAssertEqual(audio.value.outputUID, "phones")
    }

    func testUnrecordedBlackHoleRouteRecoveredWhenStartFails() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.value.outputUID = "blackhole"
        dsp.failStart = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        XCTAssertEqual(engine.state, .failed("start failed"))
        XCTAssertEqual(audio.value.outputUID, "built")
        XCTAssertNil(store.record)
        await engine.shutdown()
    }

    func testManualOnLossTurnsPolicyOffAndReconnectDoesNotStart() async throws {
        for fallbackMode in [FallbackOutputMode.automatic, .manual, .off] {
            for failureFirst in [false, true] {
                for bypassed in [false, true] {
                    let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
                    let preference = FallbackOutputPreference(mode: fallbackMode, outputUID: "built")
                    let engine = Reconciler(profiles: [profile(alerts: true)], audio: audio, dsp: dsp,
                        store: store, sleeper: InstantSleeper(),
                        fallbackPreferences: .init(profiles: ["home": preference]))
                    engine.setMode(.forceOn, profileID: "home")
                    try engine.start(); await drain()
                    if bypassed { engine.release(); await drain() }
                    let outputs = audio.outputWrites, alerts = audio.alertWrites
                    let device = audio.value.devices.first { $0.uid == "interface" }!
                    audio.value.devices.removeAll { $0.uid == "interface" }
                    if failureFirst { dsp.onFailure?("transport lost") }
                    engine.handle(.devicesChanged)
                    dsp.onFailure?("late transport lost")
                    await drain()
                    XCTAssertEqual(engine.mode, .forceOff)
                    XCTAssertEqual(engine.selectedID, "home")
                    XCTAssertEqual(engine.state, .idle)
                    XCTAssertFalse(engine.recovering)
                    XCTAssertEqual(dsp.calls, ["start", "verify", "stop"])
                    XCTAssertEqual(engine.fallbackPreference(profileID: "home"), preference)
                    if fallbackMode == .off {
                        XCTAssertEqual(audio.outputWrites, outputs)
                        XCTAssertEqual(audio.alertWrites, alerts)
                    } else {
                        XCTAssertEqual(audio.value.outputUID, fallbackMode == .manual ? "built" : "phones")
                        XCTAssertEqual(audio.value.alertUID, "built")
                    }
                    engine.handle(.devicesChanged); engine.handle(.outputChanged); await drain()
                    XCTAssertEqual(dsp.calls, ["start", "verify", "stop"])
                    audio.value.devices.append(device)
                    engine.handle(.devicesChanged); await drain()
                    XCTAssertEqual(engine.mode, .forceOff)
                    XCTAssertEqual(engine.state, .idle)
                    XCTAssertEqual(dsp.calls, ["start", "verify", "stop"])
                    await engine.shutdown()
                }
            }
        }
    }

    func testManualOnStartupLossWithoutDeviceNotificationEndsOff() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        engine.setMode(.forceOn, profileID: "home")
        dsp.onVerify = {
            audio.value.devices.removeAll { $0.uid == "interface" }
            throw DSPFailure.unavailable("transport disappeared")
        }
        try engine.start(); await drain()
        XCTAssertEqual(engine.mode, .forceOff)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(dsp.calls, ["start", "verify", "stop"])
        XCTAssertTrue(audio.outputWrites.isEmpty)
        XCTAssertFalse(engine.recovering)
        await engine.shutdown()
    }

    func testManualOnQueuedStartupLosesDeviceBeforeManagedAssignment() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        engine.setMode(.forceOn, profileID: "home")
        try engine.start()
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged)
        await drain()
        XCTAssertEqual(engine.mode, .forceOff)
        XCTAssertEqual(engine.selectedID, "home")
        XCTAssertEqual(engine.state, .idle)
        XCTAssertTrue(dsp.calls.isEmpty)
        XCTAssertTrue(audio.outputWrites.isEmpty)
        await engine.shutdown()
    }

    func testManualOnLossCancelsHeldStartAndSurvivesImmediateReconnect() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.holdStart = true
        let engine = make(audio, dsp, store)
        engine.setMode(.forceOn, profileID: "home")
        try engine.start(); await drain()
        let device = audio.value.devices.first { $0.uid == "interface" }!
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged)
        XCTAssertEqual(engine.mode, .forceOff)
        audio.value.devices.append(device)
        engine.handle(.devicesChanged)
        dsp.holdStart = false
        dsp.continuation?.resume(); dsp.continuation = nil
        await drain()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(dsp.calls, ["start", "stop"])
        XCTAssertTrue(audio.outputWrites.isEmpty)
        await engine.shutdown()
    }

    func testManualOnLossPreservesCleanupFailuresWithoutNotificationRetries() async throws {
        for failure in ["stop", "save", "route"] {
            let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
            let engine = make(audio, dsp, store, alerts: true)
            engine.setMode(.forceOn, profileID: "home")
            try engine.start(); await drain()
            if failure == "stop" { dsp.failStop = true }
            if failure == "save" { store.failRelinquish = true }
            if failure == "route" { audio.failedUIDs = ["phones", "built"] }
            audio.value.devices.removeAll { $0.uid == "interface" }
            engine.handle(.devicesChanged); await drain()
            XCTAssertEqual(engine.mode, .forceOff)
            guard case .failed(let message) = engine.state else {
                XCTFail("Cleanup failure must remain visible"); continue
            }
            XCTAssertFalse(message.contains("Required audio devices"))
            let calls = dsp.calls
            engine.handle(.devicesChanged); engine.handle(.outputChanged)
            dsp.onFailure?("late transport failure")
            await drain()
            XCTAssertEqual(dsp.calls, calls)
            XCTAssertEqual(engine.state, .failed(message))
            dsp.failStop = false; store.failRelinquish = false; audio.failedUIDs = []
            await engine.shutdown()
        }
    }

    func testManualOnLossCancelsDSPCommandBeforeStopping() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        engine.setMode(.forceOn, profileID: "home")
        try engine.start(); await drain()
        var entered = false
        var wrote = false
        let command = Task { @MainActor in
            try await engine.performDSPControl(profileID: "home", allowsProcessingRestart: true) {
                entered = true
                try await Task.sleep(nanoseconds: 30_000_000_000)
                wrote = true
            }
        }
        await drain()
        XCTAssertTrue(entered)
        audio.value.devices.removeAll { $0.uid == "interface" }
        // A preset's expected processing interruption is deferred by its lease;
        // the actual hardware event still cancels that lease immediately.
        dsp.onFailure?("processing socket lost")
        engine.handle(.devicesChanged)
        do { try await command.value; XCTFail("Lost device must cancel command authority") }
        catch { XCTAssertTrue(error is CancellationError) }
        await drain()
        XCTAssertFalse(wrote)
        XCTAssertEqual(engine.mode, .forceOff)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(dsp.calls, ["start", "verify", "stop"])
        XCTAssertFalse(engine.dspControlBusy)
        await engine.shutdown()
    }

    func testAutomaticLossKeepsPolicyAndReactivatesOnReconnect() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        let device = audio.value.devices.first { $0.uid == "interface" }!
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.mode, .automatic)
        XCTAssertEqual(engine.state, .idle)
        audio.value.devices.append(device)
        engine.handle(.devicesChanged); await drain()
        XCTAssertEqual(engine.mode, .automatic)
        XCTAssertEqual(engine.state, .active("home"))
        XCTAssertEqual(dsp.calls, ["start", "verify", "stop", "start", "verify"])
        await engine.shutdown()
    }

    func testWrongDSPSelectorRejectedBeforeStart() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        var configured = profile()
        configured.expectedPlaybackDevice = "Different Interface"
        let engine = Reconciler(profiles: [configured], audio: audio, dsp: dsp, store: store, sleeper: InstantSleeper())
        try engine.start(); await drain()
        XCTAssertTrue(dsp.calls.isEmpty)
        XCTAssertTrue(audio.outputWrites.isEmpty)
        await engine.shutdown()
    }

}
