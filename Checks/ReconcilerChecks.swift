// Dependency-free mirrors of ReconcilerTests for Command Line Tools installations.
import AutoAudioCore

@MainActor private final class TestAudio: AudioManaging {
    var value = AudioSnapshot(devices: [
        AudioDevice(uid: "built", name: "Speakers", hasOutput: true, isBuiltIn: true),
        AudioDevice(uid: "phones", name: "Headphones", hasOutput: true),
        AudioDevice(uid: "interface", name: "Interface", hasOutput: true),
        AudioDevice(uid: "blackhole", name: "BlackHole", hasOutput: true)
    ], outputUID: "phones", alertUID: "built")
    var failedUIDs = Set<String>()
    var ignoreOutputWrites = false
    var outputWrites: [String] = []
    var alertWrites: [String] = []
    var reentrantOutputNotification = false
    var callback: (@MainActor (AudioEvent) -> Void)?
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws {
        if failedUIDs.contains(uid) { throw SwitcherError.message("set failed") }
        outputWrites.append(uid)
        if !ignoreOutputWrites { value.outputUID = uid }
        if reentrantOutputNotification { callback?(.outputChanged) }
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
    var profileCalls: [String] = []
    func start(_ profile: Profile) async throws {
        calls.append("start"); profileCalls.append("start:" + profile.id)
        if holdStart { await withCheckedContinuation { continuation = $0 } }
        if failStart { throw SwitcherError.message("start failed") }
    }
    func verifyReadiness(_ profile: Profile) async throws {
        calls.append("verify"); profileCalls.append("verify:" + profile.id)
        try onVerify?()
        if failReadiness { throw SwitcherError.message("not ready") }
    }
    func stop(_ profile: Profile) async throws {
        calls.append("stop"); profileCalls.append("stop:" + profile.id)
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

@MainActor private final class ReconcilerChecks {
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

    private func alternative(_ id: String = "other", auto: Bool = true) -> Profile {
        var result = profile(); result.id = id; result.name = id
        result.triggerUID = id + "-interface"; result.playbackUID = result.triggerUID
        result.captureUID = id + "-capture"; result.managedFeedUID = result.captureUID
        result.expectedCaptureDevice = result.captureUID; result.expectedPlaybackDevice = result.playbackUID
        result.launchAgentLabel = "test." + id; result.autoActivate = auto
        return result
    }
    private func addDevices(_ profile: Profile, to audio: TestAudio, trigger: Bool = true) {
        audio.value.devices.append(AudioDevice(uid: profile.captureUID, name: profile.captureUID, hasOutput: true))
        if trigger { audio.value.devices.append(AudioDevice(uid: profile.playbackUID, name: profile.playbackUID, hasOutput: true)) }
    }

    func testAutomaticSelectedInterfaceHandsOffWithoutArrivalTakeover() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore(), other = alternative()
        addDevices(other, to: audio, trigger: false)
        let engine = Reconciler(profiles: [profile(), other], audio: audio, dsp: dsp, store: store, sleeper: InstantSleeper())
        engine.setMode(.automatic, profileID: "home")
        try engine.start(); await drain()
        let originalCalls = dsp.profileCalls
        audio.value.devices.append(AudioDevice(uid: other.playbackUID, name: "Other", hasOutput: true))
        engine.handle(.devicesChanged); await drain()
        try check(engine.state == .active("home") && dsp.profileCalls == originalCalls,
                  "Connecting another automatic interface never steals a healthy selected session")
        let originalDevice = audio.value.devices.first { $0.uid == "interface" }!
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        try check(engine.state == .active(other.id) && engine.selectedID == other.id
                  && audio.value.outputUID == other.captureUID,
                  "Auto hands off from unavailable explicitly selected hardware to its unique eligible alternative")
        try check(dsp.profileCalls == ["start:home", "verify:home", "stop:home", "start:other", "verify:other"],
                  "Handoff stops the old DSP before starting and verifying the new profile")
        let handedOffCalls = dsp.profileCalls
        audio.value.devices.append(originalDevice); engine.handle(.devicesChanged); await drain()
        try check(engine.state == .active(other.id) && dsp.profileCalls == handedOffCalls,
                  "The original interface returning cannot reclaim a healthy handed-off session")
        await engine.shutdown()
    }

    func testAutomaticLateAlternativeAfterSelectedDeviceLoss() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore(), other = alternative()
        addDevices(other, to: audio, trigger: false)
        let engine = Reconciler(profiles: [profile(), other], audio: audio, dsp: dsp, store: store, sleeper: InstantSleeper())
        engine.setMode(.automatic, profileID: "home"); try engine.start(); await drain()
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        try check(engine.state == .idle && engine.mode == .automatic, "Auto waits without a usable replacement")
        audio.value.devices.append(AudioDevice(uid: other.playbackUID, name: "Other", hasOutput: true))
        engine.handle(.devicesChanged); await drain()
        try check(engine.state == .active(other.id) && engine.selectedID == other.id,
                  "A consumed selected-device loss does not block a later automatic alternative")
        await engine.shutdown()
    }

    func testAutomaticHandoffRequiresOneEnabledAlternative() async throws {
        for manualAlternative in [false, true] {
            let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
            let other = alternative(auto: !manualAlternative), third = alternative("third")
            addDevices(other, to: audio)
            if !manualAlternative { addDevices(third, to: audio) }
            let profiles = manualAlternative ? [profile(), other] : [profile(), other, third]
            let engine = Reconciler(profiles: profiles, audio: audio, dsp: dsp, store: store, sleeper: InstantSleeper())
            engine.setMode(.automatic, profileID: "home"); try engine.start(); await drain()
            audio.value.devices.removeAll { $0.uid == "interface" }
            engine.handle(.devicesChanged); await drain()
            try check(engine.state == (manualAlternative ? .idle : .needsSelection)
                      && dsp.profileCalls == ["start:home", "verify:home", "stop:home"],
                      "Handoff skips manual alternatives and requires selection when several automatic alternatives remain")
            await engine.shutdown()
        }
    }

    func testAutomaticHandoffDoesNotOverrideOffOnOrCompanion() async throws {
        for policy in ["off", "on", "companion"] {
            let audio = TestAudio(), dsp = TestDSP(), store = TestStore(), other = alternative()
            addDevices(other, to: audio)
            let engine = Reconciler(profiles: [profile(), other], audio: audio, dsp: dsp, store: store,
                sleeper: InstantSleeper(), automaticSwitching: policy != "companion", companionProfileID: "home")
            if policy != "companion" { engine.setMode(policy == "off" ? .forceOff : .forceOn, profileID: "home") }
            try engine.start(); await drain()
            audio.value.devices.removeAll { $0.uid == "interface" }
            engine.handle(.devicesChanged); await drain()
            try check(!dsp.profileCalls.contains("start:other") && engine.selectedID == "home",
                      "Automatic handoff cannot override Off, forced On loss or Companion selection")
            await engine.shutdown()
        }
    }

    func testReleaseRestoresRouteAndResumesWithoutDSPLifecycleCalls() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        try assertEqual(engine.state, .active("home"))
        try check(engine.permitsDSPControls(profileID: "home"), "Active profile should permit interactive DSP controls")
        try check(!engine.permitsDSPControls(profileID: "other"), "Aux writes cannot target a different profile")
        engine.release()
        try check(engine.permitsDSPControls(profileID: "home"), "Routing bypass retains verified DSP control authority")
        await drain()
        try assertEqual(engine.state, .active("home"))
        try assertEqual(audio.value.outputUID, "phones")
        try check(engine.permitsDSPControls(profileID: "home"), "Aux remains available after route-only release settles")
        try assertEqual(dsp.calls, ["start", "verify"])
        engine.retry(); engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.state, .active("home"))
        try assertEqual(dsp.calls, ["start", "verify"])
        do { try engine.reconnect(profileID: "home"); throw CheckFailure.failed("Reconnect should be rejected") } catch let error as CheckFailure { throw error } catch { }
        try engine.resume(); await drain()
        try assertEqual(engine.mode, .automatic)
        try assertEqual(engine.state, .active("home"))
        try assertEqual(audio.value.outputUID, "blackhole")
        try assertEqual(dsp.calls, ["start", "verify"])
        await engine.shutdown()
    }

    func testReleaseResumeRetainsForcedPolicyAndSelection() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        engine.setMode(.forceOn, profileID: "home")
        try engine.start(); await drain()
        engine.release(); await drain()
        try assertEqual(engine.mode, .forceOn)
        try assertEqual(engine.selectedID, "home")
        engine.retry(); await drain()
        try check(engine.released, "Retry cannot clear explicit release")
        try engine.resume(); await drain()
        try assertEqual(engine.mode, .forceOn)
        try assertEqual(engine.selectedID, "home")
        try assertEqual(engine.state, .active("home"))
        try check(dsp.calls == ["start", "verify"], "On release and resume must not restart DSP")
        do { try engine.resume(); throw CheckFailure.failed("Resume requires suspension") }
        catch let error as CheckFailure { throw error } catch { }
        await engine.shutdown()
    }

    func testReleaseResumesOnlyOnGenuineDeviceReconnect() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        engine.release(); await drain()
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.state, .suspended)
        audio.value.devices.append(AudioDevice(uid: "interface", name: "Interface", hasOutput: true))
        engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testResumeUsesCurrentPhysicalOutputAsReturnRoute() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        engine.release(); await drain()
        audio.value.outputUID = "built"
        engine.handle(.outputChanged); await drain()
        try engine.resume(); await drain()
        try assertEqual(audio.value.outputUID, "blackhole")
        try assertEqual(store.record?.previousOutputUID, "built")
        engine.setMode(.forceOff); await drain()
        try assertEqual(audio.value.outputUID, "built")
        try assertEqual(dsp.calls.filter { $0 == "start" }.count, 1)
        try assertEqual(dsp.calls.filter { $0 == "stop" }.count, 1)
        await engine.shutdown()
    }

    func testReleaseFallbackAndFailureKeepDSPRunning() async throws {
        let fallbackAudio = TestAudio(), fallbackDSP = TestDSP(), fallbackStore = TestStore()
        let fallbackEngine = make(fallbackAudio, fallbackDSP, fallbackStore)
        try fallbackEngine.start(); await drain()
        fallbackAudio.failedUIDs.insert("phones")
        fallbackEngine.release(); await drain()
        try assertEqual(fallbackAudio.value.outputUID, "built")
        try assertNil(fallbackEngine.routingError)
        try assertEqual(fallbackDSP.calls, ["start", "verify"])
        await fallbackEngine.shutdown()

        let failedAudio = TestAudio(), failedDSP = TestDSP(), failedStore = TestStore()
        let failedEngine = make(failedAudio, failedDSP, failedStore)
        try failedEngine.start(); await drain()
        failedAudio.failedUIDs = ["phones", "built", "interface"]
        failedEngine.release(); await drain()
        try assertEqual(failedAudio.value.outputUID, "blackhole")
        try check(failedEngine.routingError != nil, "Unconfirmed output restoration has its own error")
        try assertEqual(failedDSP.calls, ["start", "verify"])
        failedAudio.failedUIDs = []
        failedEngine.release(); await drain()
        try assertEqual(failedAudio.value.outputUID, "phones")
        try assertNil(failedEngine.routingError)
        try check(failedDSP.calls == ["start", "verify"], "Retrying output restoration keeps DSP lifecycle untouched")
        await failedEngine.shutdown()
    }

    func testReconnectIntentionallyStopsAndStartsSameDSP() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        try engine.reconnect(profileID: "home")
        try check(!engine.permitsDSPControls(profileID: "home"), "Queued reconnect disables Aux before service teardown")
        await drain()
        try assertEqual(engine.state, .active("home"))
        try assertEqual(dsp.calls, ["start", "verify", "stop", "start", "verify"])
        try assertEqual(audio.outputWrites, ["blackhole", "phones", "blackhole"])
        engine.setMode(.forceOff)
        try check(!engine.permitsDSPControls(profileID: "home"), "Off disables Aux before asynchronous cleanup")
        await drain()
        do { try engine.reconnect(profileID: "home"); throw CheckFailure.failed("Reconnect should be rejected") } catch let error as CheckFailure { throw error } catch { }
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
        try assertEqual(engine.state, .suspended)
        try assertTrue(audio.outputWrites.isEmpty)
        try assertEqual(dsp.calls, ["start", "stop"])
        await engine.shutdown()
    }

    func testStartupWithoutInterfacePreservesHeadphones() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.value.devices.removeAll { $0.uid == "interface" }
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        try assertEqual(engine.state, .idle)
        try assertEqual(audio.value.outputUID, "phones")
        try assertTrue(audio.outputWrites.isEmpty)
        try assertTrue(dsp.calls.isEmpty)
        await engine.shutdown()
    }

    func testFailedStartNeverRoutesAndDoesNotRetry() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.failStart = true
        let engine = make(audio, dsp, store)
        var feedbackCount = 0
        engine.onFeedback = { _ in feedbackCount += 1 }
        try engine.start(); await drain()
        try assertEqual(engine.state, .failed("start failed"))
        try assertEqual(feedbackCount, 0)
        try assertEqual(audio.value.outputUID, "phones")
        try assertEqual(dsp.calls, ["start", "stop"])
        engine.handle(.devicesChanged); await drain()
        try assertEqual(dsp.calls, ["start", "stop"])
        await engine.shutdown()
    }

    func testReadinessFailureNeverRoutes() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.failReadiness = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        try assertEqual(engine.state, .failed("not ready"))
        try assertNil(engine.routingError)
        try assertTrue(audio.outputWrites.isEmpty)
        try assertEqual(dsp.calls, ["start", "verify", "stop"])
        await engine.shutdown()
    }

    func testManualOutputSuspendsAndPreservesUserSelection() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store, alerts: true)
        try engine.start(); await drain()
        try assertEqual(engine.state, .active("home"))
        audio.value.outputUID = "phones"
        engine.handle(.outputChanged); await drain()
        try assertEqual(engine.state, .suspended)
        try assertEqual(audio.value.outputUID, "phones")
        try assertEqual(audio.value.alertUID, "built")
        try assertNil(store.record)
        engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.state, .suspended)
        engine.retry(); await drain()
        try assertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testRestoreFailureFallsBackAndRestoresAlertsSeparately() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store, alerts: true)
        try engine.start(); await drain()
        audio.failedUIDs.insert("phones")
        engine.setMode(.forceOff); await drain()
        try assertEqual(audio.value.outputUID, "built")
        try assertEqual(audio.value.alertUID, "built")
        try assertNil(store.record)
        try assertEqual(engine.state, .idle)
        await engine.shutdown()
    }

    func testTotalRestoreFailureRetainsOwnershipAndService() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        audio.failedUIDs = ["phones", "built", "interface"]
        engine.setMode(.forceOff); await drain()
        try assertEqual(audio.value.outputUID, "blackhole")
        try assertEqual(store.record?.ownsOutput, true)
        try assertFalse(dsp.calls.contains("stop"))
        audio.failedUIDs = []
        await engine.shutdown()
        try assertNil(store.record)
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
        try assertEqual(dsp.calls, ["start", "stop", "start", "verify"])
        try assertEqual(audio.outputWrites, ["blackhole"])
        try assertEqual(engine.state, .active("home"))
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
        try assertEqual(engine.state, .suspended)
        try assertTrue(audio.outputWrites.isEmpty)
        try assertEqual(dsp.calls, ["start", "stop"])
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
        try assertEqual(audio.value.outputUID, "phones")
        try assertNil(store.record)
        try assertEqual(dsp.calls, ["stop"])
        await engine.shutdown()
    }
    func testAutomaticClearsManualSelection() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        engine.setMode(.forceOn, profileID: "missing")
        await drain()
        engine.setMode(.automatic)
        await drain()
        try assertEqual(engine.state, .active("home"))
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
        try assertEqual(engine.state, .active("home"))
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
        try assertEqual(engine.state, .idle)
        audio.value.devices.append(device)
        engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.state, .active("home"))
        await engine.shutdown()
    }

    func testStartupAdoptsSavedRouteWithoutStoppingService() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.value.outputUID = "blackhole"
        store.record = RouteRecord(profileID: "home", captureUID: "blackhole", previousOutputUID: "phones",
                                   previousAlertUID: nil, ownsOutput: true, ownsAlerts: false)
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        try assertEqual(engine.state, .active("home"))
        try assertEqual(dsp.calls, ["start", "verify"])
        try assertEqual(store.record?.previousOutputUID, "phones")
        await engine.shutdown()
        try assertEqual(audio.value.outputUID, "phones")
    }

    func testUnrecordedBlackHoleRouteRecoveredWhenStartFails() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.value.outputUID = "blackhole"
        dsp.failStart = true
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        try assertEqual(engine.state, .failed("start failed"))
        try assertEqual(audio.value.outputUID, "built")
        try assertNil(store.record)
        await engine.shutdown()
    }

    func testWrongDSPSelectorRejectedBeforeStart() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        var configured = profile()
        configured.expectedPlaybackDevice = "Different Interface"
        let engine = Reconciler(profiles: [configured], audio: audio, dsp: dsp, store: store, sleeper: InstantSleeper())
        try engine.start(); await drain()
        try assertTrue(dsp.calls.isEmpty)
        try assertTrue(audio.outputWrites.isEmpty)
        await engine.shutdown()
    }


    func testReconnectClearsManualSuspension() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        audio.value.outputUID = "phones"
        engine.handle(.outputChanged); await drain()
        try assertEqual(engine.state, .suspended)
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        audio.value.devices.append(AudioDevice(uid: "interface", name: "Interface", hasOutput: true))
        engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.state, .active("home"))
        try assertEqual(dsp.calls.filter { $0 == "start" }.count, 2)
        await engine.shutdown()
    }

    func testManualVirtualSelectionResumesAndRestoresPhysicalOutputOnFailure() async throws {
        for fail in [false, true] {
            let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
            let engine = make(audio, dsp, store)
            try engine.start(); await drain()
            audio.value.outputUID = "phones"
            engine.handle(.outputChanged); await drain()
            dsp.failStart = fail
            audio.outputWrites.removeAll()
            audio.value.outputUID = "blackhole"
            engine.handle(.outputChanged); await drain()
            if fail {
                try assertEqual(audio.value.outputUID, "phones")
                try assertEqual(engine.state, .failed("start failed"))
            } else {
                try assertEqual(engine.state, .active("home"))
                try assertTrue(audio.outputWrites.isEmpty)
                engine.handle(.outputChanged); await drain()
                try assertEqual(dsp.calls.filter { $0 == "start" }.count, 2)
            }
            await engine.shutdown()
            try assertEqual(audio.value.outputUID, "phones")
        }
    }

    func testForceOffBlocksVirtualSelectionAndReconnect() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        engine.setMode(.forceOff)
        try engine.start(); await drain()
        audio.value.outputUID = "blackhole"
        engine.handle(.outputChanged); await drain()
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        audio.value.devices.append(AudioDevice(uid: "interface", name: "Interface", hasOutput: true))
        engine.handle(.devicesChanged); await drain()
        try assertTrue(dsp.calls.isEmpty)
        await engine.shutdown()
    }

    func testFeedbackRequiresConfirmedRoutingAndSuppressesNoops() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.holdStart = true
        let engine = make(audio, dsp, store)
        var settings = FeedbackSettings(); settings.mode = .allChanges
        var feedback = FeedbackPolicy(settings: settings)
        feedback.seedOutput(audio.value.outputUID)
        var messages: [FeedbackMessage] = []
        engine.onFeedback = { if let message = feedback.message(for: $0) { messages.append(message) } }
        try engine.start(); await drain()
        try assertTrue(messages.isEmpty)
        dsp.continuation?.resume(); dsp.continuation = nil
        await drain()
        try assertEqual(messages.map(\.text), ["Output changed to BlackHole"])
        engine.handle(.outputChanged); engine.handle(.devicesChanged); await drain()
        try assertEqual(messages.count, 1)
        engine.setMode(.forceOff); await drain()
        try assertEqual(messages.map(\.text), ["Output changed to BlackHole", "Output restored to Headphones"])
        engine.handle(.outputChanged); await drain()
        try assertEqual(messages.count, 2)
        audio.value.outputUID = "built"
        engine.handle(.outputChanged); await drain()
        try assertEqual(messages.last?.text, "Output changed to Speakers")
        await engine.shutdown()
    }

    func testUnconfirmedWriteNeverAnnouncesRouteSuccess() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.ignoreOutputWrites = true
        let engine = make(audio, dsp, store)
        var feedbackCount = 0
        engine.onFeedback = { _ in feedbackCount += 1 }
        try engine.start(); await drain()
        try assertEqual(engine.state, .failed("Audio route change was not confirmed."))
        try check(engine.routingError != nil, "Unconfirmed route acquisition has a routing error")
        try assertEqual(feedbackCount, 0)
        try assertEqual(audio.value.outputUID, "phones")
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
                    try assertEqual(engine.mode, .forceOff)
                    try assertEqual(engine.selectedID, "home")
                    try assertEqual(engine.state, .idle)
                    try assertFalse(engine.recovering)
                    try assertEqual(dsp.calls, ["start", "verify", "stop"])
                    try assertEqual(engine.fallbackPreference(profileID: "home"), preference)
                    if fallbackMode == .off {
                        try assertEqual(audio.outputWrites, outputs)
                        try assertEqual(audio.alertWrites, alerts)
                    } else {
                        try assertEqual(audio.value.outputUID, fallbackMode == .manual ? "built" : "phones")
                        try assertEqual(audio.value.alertUID, "built")
                    }
                    engine.handle(.devicesChanged); engine.handle(.outputChanged); await drain()
                    try assertEqual(dsp.calls, ["start", "verify", "stop"])
                    audio.value.devices.append(device)
                    engine.handle(.devicesChanged); await drain()
                    try assertEqual(engine.mode, .forceOff)
                    try assertEqual(engine.state, .idle)
                    try assertEqual(dsp.calls, ["start", "verify", "stop"])
                    await engine.shutdown()
                }
            }
        }
    }

    func testExternalOutputSelectionReportsStableDevicesWithoutChangingPolicy() async throws {
        for fallbackMode in [FallbackOutputMode.automatic, .manual, .off] {
            let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
            let preference = FallbackOutputPreference(mode: fallbackMode, outputUID: "built")
            let engine = Reconciler(profiles: [profile()], audio: audio, dsp: dsp,
                store: store, sleeper: InstantSleeper(),
                fallbackPreferences: .init(profiles: ["home": preference]))
            var selections: [(String, AudioDevice)] = []
            engine.onExternalOutputSelection = { selections.append(($0, $1)) }
            try engine.start(); await drain()
            audio.value.outputUID = "interface"
            engine.handle(.outputChanged); await drain()
            try check(selections.count == 1 && selections[0].0 == "home" && selections[0].1.uid == "interface",
                      "Stable external macOS output selection identifies the active profile and physical device")
            try check(engine.fallbackPreference(profileID: "home") == preference && engine.mode == .automatic,
                      "Candidate observation does not implicitly save or change fallback/DSP policy")
            engine.handle(.outputChanged); await drain()
            try check(selections.count == 1, "Duplicate output notifications do not repeat adoption")
            engine.setMode(.forceOff); await drain()
            audio.value.outputUID = "phones"
            engine.handle(.outputChanged); await drain()
            try check(selections.count == 2 && selections.last?.1.uid == "phones" && engine.mode == .forceOff,
                      "Stable deliberate selection is available even with DSP Off without enabling it")
            await engine.shutdown()
        }
    }

    func testManualOnLossForceReconnectIgnoresOptionalAutoTrigger() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        var configured = profile()
        configured.triggerUID = "auto-trigger-not-present"
        let engine = Reconciler(profiles: [configured], audio: audio, dsp: dsp, store: store,
            sleeper: InstantSleeper(), fallbackPreferences: .init(profiles: ["home":
                .init(mode: .manual, outputUID: "built")]))
        engine.setMode(.forceOn, profileID: "home")
        try engine.start(); await drain()
        try assertEqual(engine.state, .active("home"))
        let device = audio.value.devices.first { $0.uid == "interface" }!
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.mode, .forceOff)
        audio.value.outputUID = "phones"
        engine.handle(.outputChanged)
        audio.value.devices.append(device)
        engine.handle(.devicesChanged); await drain()
        try check(audio.value.outputUID == "built" && engine.mode == .forceOff,
                  "Force still enforces the real On-session reconnect edge without restarting DSP or requiring Auto's trigger")
        try assertEqual(dsp.calls, ["start", "verify", "stop"])
        await engine.shutdown()
    }

    func testExternalOutputSelectionIgnoresOwnedSettersAndHardwareFallback() async throws {
        for fallbackMode in [FallbackOutputMode.automatic, .manual, .off] {
            let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
            audio.reentrantOutputNotification = true
            let preference = FallbackOutputPreference(mode: fallbackMode, outputUID: "built")
            let engine = Reconciler(profiles: [profile()], audio: audio, dsp: dsp,
                store: store, sleeper: InstantSleeper(),
                fallbackPreferences: .init(profiles: ["home": preference]))
            var selections: [String] = []
            engine.onExternalOutputSelection = { selections.append($1.uid) }
            try engine.start(); await drain()
            engine.release(); await drain()
            engine.handle(.outputChanged); await drain()
            try check(selections.isEmpty, "App-owned Bypassed restoration is excluded for synchronous and deferred callbacks")
            try engine.resume(); await drain()
            let device = audio.value.devices.first { $0.uid == "interface" }!
            audio.value.devices.removeAll { $0.uid == "interface" }
            audio.value.outputUID = "built"
            engine.handle(.outputChanged); engine.handle(.devicesChanged); await drain()
            audio.value.devices.append(device)
            audio.value.outputUID = "phones"
            engine.handle(.outputChanged); engine.handle(.devicesChanged); await drain()
            try check(selections.isEmpty, "OS fallback on loss and reconnect, plus Force enforcement, never replaces saved user target")
            await engine.shutdown()
        }
    }

    func testExternalOutputSelectionIgnoresStartupAndCaptureRoutes() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        dsp.holdStart = true
        let engine = make(audio, dsp, store)
        var selections: [String] = []
        engine.onExternalOutputSelection = { selections.append($1.uid) }
        try engine.start(); await drain()
        audio.value.outputUID = "built"
        engine.handle(.outputChanged)
        dsp.holdStart = false
        dsp.continuation?.resume(); dsp.continuation = nil
        await drain()
        try check(selections.isEmpty, "Unsettled startup output changes are not persisted as explicit device choices")
        engine.setMode(.forceOff); await drain()
        audio.value.outputUID = "blackhole"
        engine.handle(.outputChanged); await drain()
        try check(selections.isEmpty, "Managed capture devices cannot become fallback targets")
        await engine.shutdown()
    }

    func testExternalOutputSelectionIgnoresBothHardwareNotificationOrders() async throws {
        for dspMode in [AutomationMode.automatic, .forceOff] {
            for fallbackMode in [FallbackOutputMode.automatic, .off] {
                for devicesFirst in [false, true] {
                    let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
                    let engine = Reconciler(profiles: [profile()], audio: audio, dsp: dsp,
                        store: store, sleeper: InstantSleeper(),
                        fallbackPreferences: .init(profiles: ["home": .init(mode: fallbackMode, outputUID: "built")]))
                    engine.setMode(dspMode, profileID: "home")
                    var selections: [String] = []
                    engine.onExternalOutputSelection = { selections.append($1.uid) }
                    try engine.start(); await drain()
                    let device = audio.value.devices.first { $0.uid == "interface" }!
                    audio.value.devices.removeAll { $0.uid == "interface" }
                    if devicesFirst { engine.handle(.devicesChanged) }
                    audio.value.outputUID = "built"
                    engine.handle(.outputChanged)
                    if !devicesFirst { engine.handle(.devicesChanged) }
                    await drain()
                    audio.value.devices.append(device)
                    if devicesFirst { engine.handle(.devicesChanged) }
                    audio.value.outputUID = "phones"
                    engine.handle(.outputChanged)
                    if !devicesFirst { engine.handle(.devicesChanged) }
                    await drain()
                    try check(selections.isEmpty,
                              "OS availability routing never becomes a user target in either device/output event order for DSP Auto or Off")
                    audio.value.outputUID = "interface"
                    engine.handle(.outputChanged); await drain()
                    try check(selections == ["interface"],
                              "Event-bound hardware suppression ends after reconciliation and preserves later deliberate output choices")
                    await engine.shutdown()
                }
            }
        }
    }

    func testExternalOutputSelectionIgnoresUnrelatedOutputTopologyOrders() async throws {
        for dspMode in [AutomationMode.automatic, .forceOff] {
            for devicesFirst in [false, true] {
                let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
                let engine = make(audio, dsp, store)
                engine.setMode(dspMode, profileID: "home")
                var selections: [String] = []
                engine.onExternalOutputSelection = { selections.append($1.uid) }
                try engine.start(); await drain()
                audio.value.devices.removeAll { $0.uid == "phones" }
                if devicesFirst { engine.handle(.devicesChanged) }
                audio.value.outputUID = "built"
                engine.handle(.outputChanged)
                if !devicesFirst { engine.handle(.devicesChanged) }
                await drain()
                let bluetooth = AudioDevice(uid: "bluetooth", name: "Bluetooth", hasOutput: true)
                audio.value.devices.append(bluetooth)
                if devicesFirst { engine.handle(.devicesChanged) }
                audio.value.outputUID = "bluetooth"
                engine.handle(.outputChanged)
                if !devicesFirst { engine.handle(.devicesChanged) }
                await drain()
                try check(selections.isEmpty,
                          "OS rerouting after unrelated headphone removal or Bluetooth admission is excluded in both event orders")
                audio.value.outputUID = "interface"
                engine.handle(.outputChanged); await drain()
                try check(selections == ["interface"],
                          "Later deliberate output selection resumes after unrelated topology settles")
                // A name-only update is not an output topology edge.
                let built = audio.value.devices.firstIndex { $0.uid == "built" }!
                audio.value.devices[built] = AudioDevice(uid: "built", name: "Renamed Speakers", hasOutput: true, isBuiltIn: true)
                engine.handle(.devicesChanged)
                audio.value.outputUID = "built"
                engine.handle(.outputChanged); await drain()
                try check(selections == ["interface", "built"],
                          "Label-only device changes do not suppress an otherwise stable deliberate selection")
                await engine.shutdown()
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
        try assertEqual(engine.mode, .forceOff)
        try assertEqual(engine.state, .idle)
        try assertEqual(dsp.calls, ["start", "verify", "stop"])
        try assertTrue(audio.outputWrites.isEmpty)
        try assertFalse(engine.recovering)
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
        try assertEqual(engine.mode, .forceOff)
        try assertEqual(engine.selectedID, "home")
        try assertEqual(engine.state, .idle)
        try assertTrue(dsp.calls.isEmpty)
        try assertTrue(audio.outputWrites.isEmpty)
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
        try assertEqual(engine.mode, .forceOff)
        audio.value.devices.append(device)
        engine.handle(.devicesChanged)
        dsp.holdStart = false
        dsp.continuation?.resume(); dsp.continuation = nil
        await drain()
        try assertEqual(engine.state, .idle)
        try assertEqual(dsp.calls, ["start", "stop"])
        try assertTrue(audio.outputWrites.isEmpty)
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
            try assertEqual(engine.mode, .forceOff)
            guard case .failed(let message) = engine.state else {
                throw CheckFailure.failed("Cleanup failure must remain visible")
            }
            try assertFalse(message.contains("Required audio devices"))
            let calls = dsp.calls
            engine.handle(.devicesChanged); engine.handle(.outputChanged)
            dsp.onFailure?("late transport failure")
            await drain()
            try assertEqual(dsp.calls, calls)
            try assertEqual(engine.state, .failed(message))
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
        try assertTrue(entered)
        audio.value.devices.removeAll { $0.uid == "interface" }
        // A preset's expected processing interruption is deferred by its lease;
        // the actual hardware event still cancels that lease immediately.
        dsp.onFailure?("processing socket lost")
        engine.handle(.devicesChanged)
        do {
            try await command.value
            throw CheckFailure.failed("Lost device must cancel command authority")
        } catch let failure as CheckFailure { throw failure }
        catch { try assertTrue(error is CancellationError) }
        await drain()
        try assertFalse(wrote)
        try assertEqual(engine.mode, .forceOff)
        try assertEqual(engine.state, .idle)
        try assertEqual(dsp.calls, ["start", "verify", "stop"])
        try assertFalse(engine.dspControlBusy)
        await engine.shutdown()
    }

    func testBypassedManualOutputRetainsDSPAcrossPolicies() async throws {
        for mode in [AutomationMode.automatic, .forceOn] {
            for fallbackMode in [FallbackOutputMode.automatic, .manual, .off] {
                let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
                let preference = FallbackOutputPreference(mode: fallbackMode, outputUID: "built")
                let engine = Reconciler(profiles: [profile()], audio: audio, dsp: dsp, store: store,
                    sleeper: InstantSleeper(), fallbackPreferences: .init(profiles: ["home": preference]))
                engine.setMode(mode, profileID: "home")
                try engine.start(); await drain()
                engine.release(); await drain()
                let calls = dsp.calls
                audio.value.outputUID = "interface"
                engine.handle(.outputChanged); engine.handle(.woke); await drain()
                try check(engine.released && !engine.suspended && engine.state == .active("home"),
                          "Explicit Bypassed retains the verified DSP after a stable manual output choice")
                try check(engine.permitsDSPControls(profileID: "home") && dsp.calls == calls,
                          "Stable physical selection while Bypassed preserves control authority without restarting DSP")
                try assertEqual(audio.value.outputUID, "interface")
                try assertEqual(engine.mode, mode)
                try assertEqual(engine.fallbackPreference(profileID: "home"), preference)
                try engine.resume(); await drain()
                try assertEqual(store.record?.previousOutputUID, "interface")
                await engine.shutdown()
                try assertEqual(audio.value.outputUID, "interface")
            }
        }
    }

    func testEnabledModeSelectionExplicitlyEndsBypassAcrossPolicies() async throws {
        for mode in [AutomationMode.automatic, .forceOn] {
            for fallbackMode in [FallbackOutputMode.automatic, .manual, .off] {
                let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
                let preference = FallbackOutputPreference(mode: fallbackMode, outputUID: "built")
                let engine = Reconciler(profiles: [profile()], audio: audio, dsp: dsp, store: store,
                    sleeper: InstantSleeper(), fallbackPreferences: .init(profiles: ["home": preference]))
                try engine.start(); await drain()
                engine.release(); await drain()
                let calls = dsp.calls
                engine.setMode(mode, profileID: "home"); await drain()
                try check(!engine.released && engine.state == .active("home") && audio.value.outputUID == "blackhole",
                          "Explicit enabled DSP policy resets session Bypassed and reacquires Processed")
                try check(dsp.calls == calls && engine.fallbackPreference(profileID: "home") == preference,
                          "Reacquiring the healthy session preserves its DSP and fallback preference")
                await engine.shutdown()
            }
        }
    }

    func testForceFallbackDoesNotEnforceOnExplicitDSPRestart() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = Reconciler(profiles: [profile()], audio: audio, dsp: dsp, store: store,
            sleeper: InstantSleeper(), fallbackPreferences: .init(profiles: ["home":
                .init(mode: .manual, outputUID: "built")]))
        try engine.start(); await drain()
        audio.outputWrites.removeAll()
        try engine.reconnect(profileID: "home"); await drain()
        try check(dsp.calls == ["start", "verify", "stop", "start", "verify"],
                  "Explicit restart drains and restarts the selected managed DSP exactly once")
        try check(audio.outputWrites == ["phones", "blackhole"] && !engine.released,
                  "Restart restores its owned return and reprocesses without inventing a Force device edge")
        engine.handle(.devicesChanged); engine.handle(.woke); await drain()
        try assertEqual(audio.outputWrites, ["phones", "blackhole"])
        await engine.shutdown()
    }

    func testAutomaticLossFailuresStayTerminalUntilMeaningfulAction() async throws {
        for fallbackMode in [FallbackOutputMode.automatic, .manual, .off] {
            for failure in ["stop", "save", "route"] {
                for failureFirst in [false, true] {
                    for completion in ["retry", "reconnect", "quit"] {
                        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
                        let engine = Reconciler(profiles: [profile(alerts: true)], audio: audio, dsp: dsp,
                            store: store, sleeper: InstantSleeper(), fallbackPreferences: .init(profiles:
                                ["home": .init(mode: fallbackMode, outputUID: "built")]))
                        try engine.start(); await drain()
                        let device = audio.value.devices.first { $0.uid == "interface" }!
                        if failure == "stop" { dsp.failStop = true }
                        if failure == "save" { store.failRelinquish = true }
                        if failure == "route" { audio.failedUIDs = ["phones", "built"] }
                        audio.value.devices.removeAll { $0.uid == "interface" }
                        if failureFirst { dsp.onFailure?("Transport detects device loss first") }
                        engine.handle(.devicesChanged); await drain()
                        // Fallback Off intentionally does not attempt output restoration.
                        let expectedFailure = failure != "route" || fallbackMode != .off
                        let settledState = engine.state
                        if expectedFailure {
                            guard case .failed = settledState else {
                                throw CheckFailure.failed("Automatic loss cleanup failure must remain visible")
                            }
                        }
                        let calls = dsp.calls, outputs = audio.outputWrites, alerts = audio.alertWrites
                        engine.handle(.outputChanged); engine.handle(.devicesChanged)
                        engine.handle(.woke); dsp.onFailure?("Late loss failure")
                        await drain()
                        try check(dsp.calls == calls && audio.outputWrites == outputs && audio.alertWrites == alerts,
                            "Unchanged missing-device notifications cannot retry consumed Auto cleanup")
                        try assertEqual(engine.state, settledState)
                        try assertEqual(engine.mode, .automatic)
                        dsp.failStop = false; store.failRelinquish = false; audio.failedUIDs = []
                        if completion == "retry" {
                            engine.retry(); await drain()
                            try check(!engine.recovering && engine.state == .idle,
                                "Explicit retry may clean up absent hardware without restarting DSP")
                        } else if completion == "reconnect" {
                            audio.value.devices.append(device)
                            engine.handle(.devicesChanged); await drain()
                            try check(engine.state == .active("home") && engine.permitsDSPControls(profileID: "home"),
                                "A genuine reconnect clears the consumed loss and restores enabled authority")
                            try assertEqual(audio.value.outputUID, fallbackMode == .manual ? "built" : "blackhole")
                        }
                        await engine.shutdown()
                        try assertEqual(engine.state, .idle)
                    }
                }
            }
        }
    }

    func testConsumedLossDoesNotBlockAnotherAutomaticProfile() async throws {
        for fallbackMode in [FallbackOutputMode.automatic, .manual, .off] {
            for stopFailed in [false, true] {
                let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
                let secondDevice = AudioDevice(uid: "other-interface", name: "Other", hasOutput: true)
                audio.value.devices.append(AudioDevice(uid: "other-capture", name: "Other capture", hasOutput: true))
                var other = profile(); other.id = "other"; other.triggerUID = "other-interface"
                other.playbackUID = "other-interface"; other.captureUID = "other-capture"
                other.managedFeedUID = "other-capture"
                other.expectedCaptureDevice = "other-capture"; other.expectedPlaybackDevice = "other-interface"
                let engine = Reconciler(profiles: [profile(), other], audio: audio, dsp: dsp, store: store,
                    sleeper: InstantSleeper(), fallbackPreferences: .init(profiles:
                        ["home": .init(mode: fallbackMode, outputUID: "built")]))
                try engine.start(); await drain()
                try assertEqual(engine.state, .active("home"))
                dsp.failStop = stopFailed
                audio.value.devices.removeAll { $0.uid == "interface" }
                engine.handle(.devicesChanged); await drain()
                dsp.failStop = false
                audio.value.devices.append(secondDevice)
                engine.handle(.devicesChanged); await drain()
                try check(engine.state == .active("other") && audio.value.outputUID == "other-capture",
                    "A newly eligible different profile may hand off after consumed loss cleanup")
                let calls = dsp.calls
                audio.value.devices.removeAll { $0.uid == "other-interface" }
                engine.handle(.devicesChanged); await drain()
                try check(engine.state == .idle && dsp.calls == calls + ["stop"],
                    "The former profile's consumed loss cannot suppress the new profile's teardown")
                await engine.shutdown()
            }
        }
    }

    func testForceReconnectRespectsAutomaticProfileEligibility() async throws {
        for autoActivate in [false, true] {
            for selected in [false, true] {
                let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
                var configured = profile(); configured.autoActivate = autoActivate
                let engine = Reconciler(profiles: [configured], audio: audio, dsp: dsp, store: store,
                    sleeper: InstantSleeper(), fallbackPreferences: .init(profiles:
                        ["home": .init(mode: .manual, outputUID: "built")]))
                if selected { engine.setMode(.automatic, profileID: "home") }
                try engine.start(); await drain()
                let eligible = autoActivate || selected
                try assertEqual(dsp.calls, eligible ? ["start", "verify"] : [])
                let device = audio.value.devices.first { $0.uid == "interface" }!
                audio.value.devices.removeAll { $0.uid == "interface" }
                engine.handle(.devicesChanged); await drain()
                audio.value.outputUID = "phones"; engine.handle(.outputChanged); await drain()
                audio.value.devices.append(device)
                engine.handle(.devicesChanged); await drain()
                try assertEqual(audio.value.outputUID, "built")
                try assertEqual(engine.mode, .automatic)
                if eligible {
                    try check(engine.state == .active("home") && engine.released,
                        "Force reconnect starts only Auto-eligible or explicitly selected DSP Bypassed")
                    try assertEqual(dsp.calls, ["start", "verify", "stop", "start", "verify"])
                } else {
                    try check(engine.state == .idle && !engine.permitsDSPControls(profileID: "home"),
                        "Force output enforcement cannot enable an excluded unselected Auto profile")
                    try assertEqual(dsp.calls, [])
                }
                await engine.shutdown()
            }
        }
        // A failed old-service stop must not let its Force edge override a newer selection.
        do {
            let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
            audio.value.devices += [AudioDevice(uid: "other-interface", name: "Other", hasOutput: true),
                                    AudioDevice(uid: "other-capture", name: "Other capture", hasOutput: true)]
            var other = profile(); other.id = "other"; other.triggerUID = "other-interface"
            other.playbackUID = "other-interface"; other.captureUID = "other-capture"
            other.managedFeedUID = "other-capture"
            other.expectedCaptureDevice = "other-capture"; other.expectedPlaybackDevice = "other-interface"
            other.autoActivate = false
            let engine = Reconciler(profiles: [profile(), other], audio: audio, dsp: dsp, store: store,
                sleeper: InstantSleeper(), fallbackPreferences: .init(profiles:
                    ["home": .init(mode: .manual, outputUID: "built")]))
            engine.setMode(.automatic, profileID: "home")
            try engine.start(); await drain()
            dsp.failStop = true
            engine.setMode(.automatic, profileID: "other"); await drain()
            guard case .failed = engine.state else { throw CheckFailure.failed("Handoff must retain the stop failure") }
            let device = audio.value.devices.first { $0.uid == "interface" }!
            audio.value.devices.removeAll { $0.uid == "interface" }
            engine.handle(.devicesChanged); await drain()
            dsp.failStop = false
            audio.value.devices.append(device); engine.handle(.devicesChanged); await drain()
            try check(engine.selectedID == "other" && engine.state == .active("other")
                && engine.permitsDSPControls(profileID: "other") && !engine.permitsDSPControls(profileID: "home"),
                "A stale Force edge cannot activate a different service than the explicitly selected profile")
            try assertEqual(audio.value.outputUID, "other-capture")
            await engine.shutdown()
        }
        // Force preferences do not choose a profile when Auto requires selection.
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        audio.value.devices += [AudioDevice(uid: "other-interface", name: "Other", hasOutput: true),
                                AudioDevice(uid: "other-capture", name: "Other capture", hasOutput: true)]
        var other = profile(); other.id = "other"; other.triggerUID = "other-interface"
        other.playbackUID = "other-interface"; other.captureUID = "other-capture"
        other.managedFeedUID = "other-capture"
        other.expectedCaptureDevice = "other-capture"; other.expectedPlaybackDevice = "other-interface"
        let engine = Reconciler(profiles: [profile(), other], audio: audio, dsp: dsp, store: store,
            sleeper: InstantSleeper(), fallbackPreferences: .init(profiles:
                ["home": .init(mode: .manual, outputUID: "built")]))
        try engine.start(); await drain()
        let device = audio.value.devices.first { $0.uid == "interface" }!
        let otherDevice = audio.value.devices.first { $0.uid == "other-interface" }!
        audio.value.devices.removeAll { $0.uid == "interface" || $0.uid == "other-interface" }
        engine.handle(.devicesChanged); await drain()
        audio.value.devices += [device, otherDevice]
        engine.handle(.devicesChanged); await drain()
        try check(engine.state == .needsSelection && dsp.calls.isEmpty,
            "Force cannot resolve ambiguous Auto profiles or start an unselected service")
        await engine.shutdown()
    }

    func testAutomaticLossKeepsPolicyAndReactivatesOnReconnect() async throws {
        let audio = TestAudio(), dsp = TestDSP(), store = TestStore()
        let engine = make(audio, dsp, store)
        try engine.start(); await drain()
        let device = audio.value.devices.first { $0.uid == "interface" }!
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.mode, .automatic)
        try assertEqual(engine.state, .idle)
        audio.value.devices.append(device)
        engine.handle(.devicesChanged); await drain()
        try assertEqual(engine.mode, .automatic)
        try assertEqual(engine.state, .active("home"))
        try assertEqual(dsp.calls, ["start", "verify", "stop", "start", "verify"])
        await engine.shutdown()
    }

}

private func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) throws {
    try check(lhs == rhs, "Expected \(rhs), received \(lhs) at \(file):\(line)")
}
private func assertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) throws {
    try check(value, "Expected true at \(file):\(line)")
}
private func assertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) throws {
    try check(!value, "Expected false at \(file):\(line)")
}
private func assertNil(_ value: Any?, file: StaticString = #file, line: UInt = #line) throws {
    try check(value == nil, "Expected nil at \(file):\(line)")
}
@MainActor func runReconcilerChecks() async throws {
    let scenarios = ReconcilerChecks()
    try await scenarios.testAutomaticSelectedInterfaceHandsOffWithoutArrivalTakeover()
    try await scenarios.testAutomaticLateAlternativeAfterSelectedDeviceLoss()
    try await scenarios.testAutomaticHandoffRequiresOneEnabledAlternative()
    try await scenarios.testAutomaticHandoffDoesNotOverrideOffOnOrCompanion()
    try await scenarios.testReleaseRestoresRouteAndResumesWithoutDSPLifecycleCalls()
    try await scenarios.testReleaseResumeRetainsForcedPolicyAndSelection()
    try await scenarios.testReleaseResumesOnlyOnGenuineDeviceReconnect()
    try await scenarios.testResumeUsesCurrentPhysicalOutputAsReturnRoute()
    try await scenarios.testReleaseFallbackAndFailureKeepDSPRunning()
    try await scenarios.testReconnectIntentionallyStopsAndStartsSameDSP()
    try await scenarios.testReconnectDuringStartSupersededByReleaseCannotRoute()
    try await scenarios.testStartupWithoutInterfacePreservesHeadphones()
    try await scenarios.testFailedStartNeverRoutesAndDoesNotRetry()
    try await scenarios.testReadinessFailureNeverRoutes()
    try await scenarios.testManualOutputSuspendsAndPreservesUserSelection()
    try await scenarios.testRestoreFailureFallsBackAndRestoresAlertsSeparately()
    try await scenarios.testTotalRestoreFailureRetainsOwnershipAndService()
    try await scenarios.testRapidUnplugReplugSerializesStaleStartAndNewStart()
    try await scenarios.testManualChangeDuringStartupCancelsRouteAcquisition()
    try await scenarios.testStartupRecoversOrphanRoute()
    try await scenarios.testAutomaticClearsManualSelection()
    try await scenarios.testReconnectRetriesFailedStartupWithoutPeriodicWork()
    try await scenarios.testMacOSFallbackOnUnplugDoesNotSuspendReconnect()
    try await scenarios.testStartupAdoptsSavedRouteWithoutStoppingService()
    try await scenarios.testUnrecordedBlackHoleRouteRecoveredWhenStartFails()
    try await scenarios.testWrongDSPSelectorRejectedBeforeStart()
    try await scenarios.testReconnectClearsManualSuspension()
    try await scenarios.testManualVirtualSelectionResumesAndRestoresPhysicalOutputOnFailure()
    try await scenarios.testForceOffBlocksVirtualSelectionAndReconnect()
    try await scenarios.testFeedbackRequiresConfirmedRoutingAndSuppressesNoops()
    try await scenarios.testUnconfirmedWriteNeverAnnouncesRouteSuccess()
    try await scenarios.testManualOnLossTurnsPolicyOffAndReconnectDoesNotStart()
    try await scenarios.testManualOnStartupLossWithoutDeviceNotificationEndsOff()
    try await scenarios.testManualOnQueuedStartupLosesDeviceBeforeManagedAssignment()
    try await scenarios.testManualOnLossCancelsHeldStartAndSurvivesImmediateReconnect()
    try await scenarios.testManualOnLossPreservesCleanupFailuresWithoutNotificationRetries()
    try await scenarios.testManualOnLossCancelsDSPCommandBeforeStopping()
    try await scenarios.testAutomaticLossKeepsPolicyAndReactivatesOnReconnect()
    try await scenarios.testAutomaticLossFailuresStayTerminalUntilMeaningfulAction()
    try await scenarios.testConsumedLossDoesNotBlockAnotherAutomaticProfile()
    try await scenarios.testForceReconnectRespectsAutomaticProfileEligibility()
    try await scenarios.testBypassedManualOutputRetainsDSPAcrossPolicies()
    try await scenarios.testEnabledModeSelectionExplicitlyEndsBypassAcrossPolicies()
    try await scenarios.testForceFallbackDoesNotEnforceOnExplicitDSPRestart()
    try await scenarios.testExternalOutputSelectionReportsStableDevicesWithoutChangingPolicy()
    try await scenarios.testExternalOutputSelectionIgnoresOwnedSettersAndHardwareFallback()
    try await scenarios.testExternalOutputSelectionIgnoresStartupAndCaptureRoutes()
    try await scenarios.testManualOnLossForceReconnectIgnoresOptionalAutoTrigger()
    try await scenarios.testExternalOutputSelectionIgnoresBothHardwareNotificationOrders()
    try await scenarios.testExternalOutputSelectionIgnoresUnrelatedOutputTopologyOrders()
    print("Reconciler checks: 50 event-driven scenarios passed; no live audio or service mutations")
}
