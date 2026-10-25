import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class FallbackAudio: AudioManaging {
    var value = AudioSnapshot(devices: [
        AudioDevice(uid: "built", name: "Speakers", hasOutput: true, isBuiltIn: true),
        AudioDevice(uid: "phones", name: "Headphones", hasOutput: true),
        AudioDevice(uid: "interface", name: "Interface", hasOutput: true),
        AudioDevice(uid: "capture", name: "Capture", hasOutput: true),
        AudioDevice(uid: "input", name: "Microphone", hasOutput: false)
    ], outputUID: "phones", alertUID: "built")
    var failedUIDs = Set<String>()
    var unconfirmedUIDs = Set<String>()
    var failedAlertUIDs = Set<String>()
    var outputWrites: [String] = []
    var alertWrites: [String] = []
    var reentrantNotifications = false
    var callback: (@MainActor (AudioEvent) -> Void)?
    func snapshot() throws -> AudioSnapshot { value }
    func setOutput(uid: String) throws {
        outputWrites.append(uid)
        if failedUIDs.contains(uid) { throw SwitcherError.message("Unavailable fixture output") }
        if unconfirmedUIDs.contains(uid) { return }
        value.outputUID = uid
        if reentrantNotifications { callback?(.outputChanged); callback?(.devicesChanged) }
    }
    func setAlertOutput(uid: String) throws {
        alertWrites.append(uid)
        if failedAlertUIDs.contains(uid) { throw SwitcherError.message("Unavailable fixture alert output") }
        value.alertUID = uid
    }
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws { callback = handler }
    func stopMonitoring() { callback = nil }
}
@MainActor private final class FallbackDSP: DSPManaging {
    var onFailure: (@MainActor (String) -> Void)?
    var calls: [String] = []
    var failStart = false
    var failStop = false
    var onVerify: (() throws -> Void)?
    func start(_ profile: Profile) async throws {
        calls.append("start")
        if failStart { throw SwitcherError.message("Fixture start failure") }
    }
    func verifyReadiness(_ profile: Profile) async throws { calls.append("verify"); try onVerify?() }
    func stop(_ profile: Profile) async throws {
        calls.append("stop")
        if failStop { throw SwitcherError.message("Fixture stop failure") }
    }
}
@MainActor private final class FallbackRouteStore: RouteStoring {
    var value: RouteRecord?
    var failRelinquish = false
    func load() throws -> RouteRecord? { value }
    func save(_ record: RouteRecord?) throws {
        if record == nil, failRelinquish { throw SwitcherError.message("Fixture route persistence failure") }
        value = record
    }
}
@MainActor private final class FallbackSleeper: TransitionSleeping {
    var onSleep: ((Int) -> Void)?
    func sleep(milliseconds: Int) async throws { try Task.checkCancellation(); onSleep?(milliseconds) }
}
@MainActor private func settleFallback() async { for _ in 0..<100 { await Task.yield() } }
private func fallbackProfile() -> Profile {
    Profile(id: "home", name: "Home", triggerUID: "interface", captureUID: "capture", playbackUID: "interface",
            launchAgentLabel: "fixture", launchAgentPath: "/fixture", websocketURL: "ws://localhost:1234",
            expectedCaptureDevice: "capture", expectedPlaybackDevice: "interface", routeAlerts: true)
}
@MainActor private func fallbackEngine(_ audio: FallbackAudio, _ dsp: FallbackDSP,
                                      preference: FallbackOutputPreference,
                                      store: FallbackRouteStore? = nil,
                                      sleeper: FallbackSleeper? = nil) -> Reconciler {
    Reconciler(profiles: [fallbackProfile()], audio: audio, dsp: dsp, store: store ?? FallbackRouteStore(),
               sleeper: sleeper ?? FallbackSleeper(), fallbackPreferences: .init(profiles: ["home": preference]))
}

@MainActor func runFallbackOutputChecks() async throws {
    let manual = FallbackOutputPreference(mode: .manual, outputUID: "built", outputName: "Speakers")
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), engine = fallbackEngine(audio, dsp, preference: manual)
        try engine.start(); await settleFallback()
        let writes = audio.outputWrites
        try engine.setFallbackPreference(manual, profileID: "home")
        try check(audio.outputWrites == writes, "Editing fallback preferences never changes a processing route")
        let eligible = try engine.eligibleFallbackOutputs().map(\.uid)
        try check(eligible == ["built", "phones", "interface"],
                  "Fallback picker excludes all managed captures and input-only devices")
        engine.release(); await settleFallback()
        try check(audio.value.outputUID == "built" && audio.value.alertUID == "built",
                  "Bypassed prefers Manual normal output while alerts restore independently")
        try check(dsp.calls == ["start", "verify"], "Bypassed keeps verified DSP running")
        try engine.resume(); await settleFallback()
        // Resume saves the then-current return output. Change preference rather
        // than changing that independent return record.
        try engine.setFallbackPreference(.init(mode: .manual, outputUID: "phones"), profileID: "home")
        engine.setMode(.forceOff); await settleFallback()
        try check(audio.value.outputUID == "built", "Off uses the saved return route, not Manual fallback")
        await engine.shutdown()
    }
    for event in [AudioEvent.devicesChanged, .outputChanged] {
        let audio = FallbackAudio(), dsp = FallbackDSP(), engine = fallbackEngine(audio, dsp, preference: manual)
        try engine.start(); await settleFallback()
        audio.value.devices.removeAll { $0.uid == "interface" }
        audio.value.outputUID = "phones" // macOS selected an available output before notification.
        audio.reentrantNotifications = true
        engine.handle(event); await settleFallback()
        try check(audio.value.outputUID == "built", "First required-device loss applies Manual despite OS automatic fallback")
        let count = audio.outputWrites.count
        audio.value.outputUID = "phones"
        engine.handle(.outputChanged); engine.handle(.devicesChanged); await settleFallback()
        try check(audio.outputWrites.count == count && audio.value.outputUID == "phones",
                  "Disconnect authority is consumed once; later manual selections are preserved")
        try check(dsp.calls.filter { $0 == "stop" }.count == 1, "Device loss stops managed DSP without recurring attempts")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), engine = fallbackEngine(audio, dsp, preference: manual)
        try engine.start(); await settleFallback()
        audio.value.devices.removeAll { $0.uid == "interface" }
        audio.value.outputUID = "phones"
        dsp.onFailure?("Required device loss before CoreAudio event")
        await settleFallback()
        try check(audio.value.outputUID == "built" && !engine.recovering,
                  "Manual preserves its one-time preferred fallback when DSP failure discovers loss first")
        let writes = audio.outputWrites
        engine.handle(.devicesChanged); await settleFallback()
        try check(audio.outputWrites == writes, "Delayed hardware event cannot repeat Manual fallback")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), engine = fallbackEngine(audio, dsp, preference: manual)
        try engine.start(); await settleFallback()
        audio.value.outputUID = "phones"
        engine.handle(.outputChanged); await settleFallback()
        let count = audio.outputWrites.count
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await settleFallback()
        try check(audio.value.outputUID == "built" && audio.outputWrites.count == count + 1,
                  "Manual fallback forces its selected output on real loss even after an unowned manual departure")
        await engine.shutdown()
    }
    for unavailable in [true, false] {
        let preference = FallbackOutputPreference(mode: .manual, outputUID: unavailable ? "missing" : "built")
        let audio = FallbackAudio(), dsp = FallbackDSP(), engine = fallbackEngine(audio, dsp, preference: preference)
        if !unavailable { audio.failedUIDs.insert("built") }
        try engine.start(); await settleFallback()
        engine.release(); await settleFallback()
        try check(audio.value.outputUID == "phones" && engine.routingError == nil,
                  "Absent or failed Manual target falls through finite verified restoration candidates")
        try check(engine.fallbackPreference(profileID: "home") == preference,
                  "Unavailable Manual device identity stays saved")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), engine = fallbackEngine(audio, dsp, preference: manual)
        try engine.start(); await settleFallback()
        await engine.shutdown()
        try check(audio.value.outputUID == "phones", "Quit preserves existing return route rather than Manual fallback")
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), engine = fallbackEngine(audio, dsp, preference: manual)
        dsp.failStart = true
        try engine.start(); await settleFallback()
        try check(audio.value.outputUID == "phones" && audio.outputWrites.isEmpty,
                  "Startup failure never applies a new Manual fallback")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), engine = fallbackEngine(audio, dsp, preference: .init())
        try engine.start(); await settleFallback()
        audio.value.devices.removeAll { $0.uid == "interface" }; audio.value.outputUID = "phones"
        engine.handle(.outputChanged); await settleFallback()
        try check(audio.value.outputUID == "phones", "Auto retains existing macOS fallback behavior")
        do {
            try engine.setFallbackPreference(.init(mode: .manual, outputUID: "capture"), profileID: "home")
            throw CheckFailure.failed("Managed capture accepted as fallback")
        } catch let error as CheckFailure { throw error } catch { }
        try check(engine.fallbackPreference(profileID: "other") == .init(), "Fallback preferences remain profile scoped")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let engine = fallbackEngine(audio, dsp, preference: .init(mode: .manual))
        try engine.start(); await settleFallback()
        audio.value.devices.removeAll { $0.uid == "interface" }; audio.value.outputUID = "built"
        let count = audio.outputWrites.count
        engine.handle(.outputChanged); await settleFallback()
        try check(audio.value.outputUID == "built" && audio.outputWrites.count == count,
                  "Manual without a selected device offers Choose Output without gaining loss override authority")
        await engine.shutdown()
    }
    try await runFallbackOffChecks()
    try await runIndependentFallbackChecks()
    try await runRestorationPolicyChecks()
    try runFallbackPersistenceChecks()
    print("Fallback checks passed: scoped preferences, Bypassed, one-time device loss, preserved manual routes, finite alternatives and atomic sidecar")
}

@MainActor private func runRestorationPolicyChecks() async throws {
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let engine = fallbackEngine(audio, dsp, preference: .init(mode: .manual, outputUID: "phones"))
        try engine.start(); await settleFallback()
        let outputs = audio.outputWrites.count
        audio.failedUIDs = ["phones"]
        engine.release(); await settleFallback()
        try check(Array(audio.outputWrites.dropFirst(outputs)) == ["phones", "built"],
                  "An explicit Bypassed target identical to the previous output is attempted once before alternatives")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), store = FallbackRouteStore()
        audio.value.devices = [
            AudioDevice(uid: "external", name: "External", hasOutput: true),
            AudioDevice(uid: "built-b", name: "Built B", hasOutput: true, isBuiltIn: true),
            AudioDevice(uid: "phones", name: "Previous", hasOutput: true, isBuiltIn: true),
            AudioDevice(uid: "built-a", name: "Built A", hasOutput: true, isBuiltIn: true),
            AudioDevice(uid: "built-b", name: "Duplicate B", hasOutput: true),
            AudioDevice(uid: "input", name: "Input", hasOutput: false, isBuiltIn: true),
            AudioDevice(uid: "capture", name: "Capture", hasOutput: true),
            AudioDevice(uid: "other-capture", name: "Other capture", hasOutput: true, isBuiltIn: true),
            AudioDevice(uid: "interface", name: "Interface", hasOutput: true)
        ]
        audio.value.alertUID = "built-b"
        var other = fallbackProfile()
        other.id = "other"; other.captureUID = "other-capture"
        other.managedFeedUID = "other-capture"
        let engine = Reconciler(profiles: [fallbackProfile(), other], audio: audio, dsp: dsp,
                                store: store, sleeper: FallbackSleeper())
        engine.setMode(.automatic, profileID: "home")
        try engine.start(); await settleFallback()
        let outputs = audio.outputWrites.count, alerts = audio.alertWrites.count
        let eligible = try engine.eligibleFallbackOutputs().map(\.uid)
        try check(eligible == ["external", "built-b", "phones", "built-a", "built-b", "interface"],
                  "Picker retains snapshot order while excluding every configured capture and input-only output")
        try check(engine.suggestedAutomaticFallbackOutput(profileID: "home", snapshot: audio.value)?.uid == "phones",
                  "The saved previous output precedes other built-in outputs in the automatic hint")
        audio.failedUIDs = ["phones", "built-b"]
        audio.unconfirmedUIDs = ["built-a"]
        engine.setMode(.forceOff); await settleFallback()
        try check(Array(audio.outputWrites.dropFirst(outputs)) == ["phones", "built-b", "built-a", "external"],
                  "Restoration tries previous, stable built-ins and other outputs once each, advancing after rejected or unconfirmed writes")
        try check(Array(audio.alertWrites.dropFirst(alerts)) == ["built-b"] && store.value == nil,
                  "Alert candidates remain independent of normal output failures and both confirmed routes relinquish ownership")
        await engine.shutdown()
    }
    for normalFails in [true, false] {
        let audio = FallbackAudio(), dsp = FallbackDSP(), store = FallbackRouteStore()
        let engine = fallbackEngine(audio, dsp, preference: .init(), store: store)
        try engine.start(); await settleFallback()
        let physicalUIDs: Set<String> = ["built", "phones", "interface"]
        if normalFails { audio.failedUIDs = physicalUIDs }
        else { audio.failedAlertUIDs = physicalUIDs }
        engine.release(); await settleFallback()
        try check(store.value?.ownsOutput == normalFails && store.value?.ownsAlerts == !normalFails,
                  "Partial restoration retains only the failed destination's ownership")
        try check(audio.value.outputUID == (normalFails ? "capture" : "phones")
                  && audio.value.alertUID == (normalFails ? "built" : "capture"),
                  "A failed destination does not undo the independently confirmed route")
        try check(engine.routingError != nil && engine.state == .active("home") && dsp.calls == ["start", "verify"],
                  "Partial Bypassed restoration reports failure while the verified DSP remains running")
        audio.failedUIDs = []; audio.failedAlertUIDs = []
        let outputs = audio.outputWrites.count, alerts = audio.alertWrites.count
        await engine.shutdown()
        try check(store.value == nil && audio.outputWrites.count == outputs + (normalFails ? 1 : 0)
                  && audio.alertWrites.count == alerts + (normalFails ? 0 : 1),
                  "Later clean shutdown retries only the retained route ownership")
    }
}

@MainActor private func runFallbackOffChecks() async throws {
    let off = FallbackOutputPreference(mode: .off, outputUID: "built", outputName: "Speakers")
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let engine = fallbackEngine(audio, dsp, preference: off)
        var snapshots: [AudioSnapshot] = []
        engine.onSnapshot = { snapshots.append($0) }
        try engine.start(); await settleFallback()
        snapshots.removeAll()
        audio.value.devices.removeAll { $0.uid == "interface" }
        audio.value.outputUID = "phones"; audio.value.alertUID = "built"
        let removed = audio.value
        dsp.onFailure?("Loss observed before CoreAudio notification")
        await settleFallback()
        try check(snapshots == [removed],
                  "Failure-first disconnect publishes one loss snapshot without waiting for a device event")
        try check(!engine.recovering && dsp.calls == ["start", "verify", "stop"],
                  "Publishing loss availability does not add readiness retries")
        await engine.shutdown()
    }
    for failureFirst in [false, true] {
        for operatingSystemMoved in [false, true] {
            let audio = FallbackAudio(), dsp = FallbackDSP(), store = FallbackRouteStore()
            let engine = fallbackEngine(audio, dsp, preference: off, store: store)
            try engine.start(); await settleFallback()
            let outputs = audio.outputWrites, alerts = audio.alertWrites
            audio.value.devices.removeAll { $0.uid == "interface" }
            if operatingSystemMoved { audio.value.outputUID = "phones"; audio.value.alertUID = "built" }
            let output = audio.value.outputUID, alert = audio.value.alertUID
            if failureFirst { dsp.onFailure?("Device transport disappeared") }
            engine.handle(.devicesChanged)
            if !failureFirst { dsp.onFailure?("Late transport disappearance") }
            await settleFallback()
            engine.handle(.outputChanged); engine.handle(.devicesChanged); await settleFallback()
            try check(audio.outputWrites == outputs && audio.alertWrites == alerts,
                      "Fallback Off performs no normal or alert setter in either loss/failure order")
            try check(audio.value.outputUID == output && audio.value.alertUID == alert && store.value == nil,
                      "Off consumes durable ownership whether capture remains selected or macOS moved outputs")
            try check(dsp.calls == ["start", "verify", "stop"] && !engine.recovering,
                      "Off loss stops DSP once without readiness retries")
            try check(engine.fallbackPreference(profileID: "home") == off,
                      "Off retains the previous Manual device identity")
            engine.release(); await settleFallback()
            engine.setMode(.forceOff); await settleFallback()
            try check(audio.outputWrites == outputs && audio.alertWrites == alerts,
                      "Explicit actions after first loss cannot restore already relinquished ownership")
            await engine.shutdown()
            try check(audio.outputWrites == outputs && audio.alertWrites == alerts,
                      "Quit after Off loss cannot perform deferred route restoration")
        }
    }
    for action in ["bypassed", "off"] {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let engine = fallbackEngine(audio, dsp, preference: off)
        try engine.start(); await settleFallback()
        audio.value.devices.removeAll { $0.uid == "interface" }
        if action == "bypassed" { engine.release() } else { engine.setMode(.forceOff) }
        dsp.onFailure?("Late failure during explicit teardown")
        engine.handle(.devicesChanged); await settleFallback()
        try check(audio.value.outputUID == (action == "bypassed" ? "built" : "phones") && audio.value.alertUID == "built",
                  "An explicit " + action + " requested before observing loss keeps ordinary restoration")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        audio.value.devices += [AudioDevice(uid: "other-interface", name: "Other interface", hasOutput: true),
                                AudioDevice(uid: "other-capture", name: "Other capture", hasOutput: true)]
        var other = fallbackProfile()
        other.id = "other"; other.name = "Other"
        other.triggerUID = "other-interface"; other.playbackUID = "other-interface"
        other.captureUID = "other-capture"
        other.managedFeedUID = "other-capture"
        other.expectedCaptureDevice = "other-capture"; other.expectedPlaybackDevice = "other-interface"
        let engine = Reconciler(profiles: [fallbackProfile(), other], audio: audio, dsp: dsp,
            store: FallbackRouteStore(), sleeper: FallbackSleeper(),
            fallbackPreferences: .init(profiles: ["home": off]))
        engine.setMode(.automatic, profileID: "home")
        try engine.start(); await settleFallback()
        engine.setMode(.automatic, profileID: "other"); await settleFallback()
        try check(engine.state == .active("other") && audio.outputWrites == ["capture", "phones", "other-capture"],
                  "Off profile handoff restores owned routes before activating another profile")
        try check(engine.fallbackPreference(profileID: "other").mode == .automatic,
                  "Off remains scoped to its selected profile")
        await engine.shutdown()
    }
    // Reconnection still activates the profile and takes fresh route ownership.
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), store = FallbackRouteStore()
        let engine = fallbackEngine(audio, dsp, preference: off, store: store)
        try engine.start(); await settleFallback()
        let device = audio.value.devices.first { $0.uid == "interface" }!
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await settleFallback()
        audio.value.outputUID = "phones"; audio.value.alertUID = "built"
        engine.handle(.outputChanged)
        audio.value.devices.append(device); engine.handle(.devicesChanged); await settleFallback()
        try check(engine.state == .active("home") && audio.value.outputUID == "capture" && store.value?.ownsOutput == true,
                  "Off does not disable normal profile reactivation after hardware reconnects")
        await engine.shutdown()
        try check(audio.value.outputUID == "phones" && audio.value.alertUID == "built",
                  "A new connected session retains its ordinary quit restoration")
    }
    // These explicit actions are not disconnect fallback policy.
    for action in ["bypassed", "off", "quit", "connected failure"] {
        let audio = FallbackAudio(), dsp = FallbackDSP(), sleeper = FallbackSleeper()
        let engine = fallbackEngine(audio, dsp, preference: off, sleeper: sleeper)
        try engine.start(); await settleFallback()
        if action == "bypassed" { engine.release(); await settleFallback() }
        else if action == "off" { engine.setMode(.forceOff); await settleFallback() }
        else if action == "quit" { await engine.shutdown() }
        else {
            // Stop recovery from advancing until its finite cancellation below.
            sleeper.onSleep = { _ in engine.setMode(.forceOff) }
            dsp.onFailure?("Connected transport failure")
        }
        try check(audio.value.outputUID == (action == "bypassed" ? "built" : "phones") && audio.value.alertUID == "built",
                  "Fallback Off preserves ordinary route restoration for " + action)
        await engine.shutdown()
    }
    // Loss discovered within startup verification is still passive loss, even
    // with no CoreAudio notification delivered before the DSP failure.
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), store = FallbackRouteStore()
        store.value = RouteRecord(profileID: "home", captureUID: "capture", previousOutputUID: "phones",
                                  previousAlertUID: "built", ownsOutput: true, ownsAlerts: true)
        audio.value.outputUID = "capture"; audio.value.alertUID = "capture"
        dsp.onVerify = {
            audio.value.devices.removeAll { $0.uid == "interface" }
            throw DSPFailure.unavailable("Hardware disappeared during readiness")
        }
        let engine = fallbackEngine(audio, dsp, preference: off, store: store)
        try engine.start(); await settleFallback()
        try check(audio.outputWrites.isEmpty && audio.alertWrites.isEmpty && store.value == nil,
                  "Startup loss relinquishes adopted ownership before entering DSP recovery")
        try check(dsp.calls == ["start", "verify", "stop"] && !engine.recovering,
                  "Startup loss has no bounded restart attempts")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), sleeper = FallbackSleeper()
        let engine = fallbackEngine(audio, dsp, preference: off, sleeper: sleeper)
        try engine.start(); await settleFallback()
        sleeper.onSleep = { milliseconds in
            if milliseconds == 1000 { audio.value.devices.removeAll { $0.uid == "interface" } }
        }
        dsp.onFailure?("Connected failure starts recovery")
        let outputs = audio.outputWrites, alerts = audio.alertWrites
        await settleFallback()
        try check(audio.outputWrites == outputs && audio.alertWrites == alerts && !engine.recovering,
                  "Loss discovered inside recovery terminates it without another output mutation")
        try check(dsp.calls == ["start", "verify", "stop"],
                  "Recovery loss stops the existing service without a restart")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), store = FallbackRouteStore()
        let engine = fallbackEngine(audio, dsp, preference: off, store: store)
        try engine.start(); await settleFallback()
        let outputs = audio.outputWrites, alerts = audio.alertWrites
        store.failRelinquish = true
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await settleFallback(); await engine.shutdown()
        try check(audio.outputWrites == outputs && audio.alertWrites == alerts && dsp.calls.last == "stop",
                  "A persistence failure is reported without a fallback write or later quit restoration")
        store.failRelinquish = false
        let restartedDSP = FallbackDSP()
        let restarted = fallbackEngine(audio, restartedDSP, preference: off, store: store)
        try restarted.start(); await settleFallback(); await restarted.shutdown()
        try check(store.value == nil && audio.outputWrites == outputs && audio.alertWrites == alerts,
                  "Stale ownership after a failed save is safely cleared on restart with Off and absent hardware")
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let engine = fallbackEngine(audio, dsp, preference: off)
        try engine.start(); await settleFallback()
        dsp.failStop = true
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await settleFallback()
        try check(dsp.calls == ["start", "verify", "stop"] && !engine.recovering,
                  "A failed DSP stop during Off loss terminates without recurring cleanup attempts")
        dsp.failStop = false
        await engine.shutdown()
    }
}

@MainActor private func runIndependentFallbackChecks() async throws {
    for mode in [FallbackOutputMode.automatic, .manual, .off] {
        for selection in [FallbackOutputSelection.automatic, .device] {
            let audio = FallbackAudio(), dsp = FallbackDSP()
            let preference = FallbackOutputPreference(mode: mode, outputSelection: selection,
                                                       outputUID: "built", outputName: "Speakers")
            let engine = fallbackEngine(audio, dsp, preference: preference)
            try engine.start(); await settleFallback()
            let writes = audio.outputWrites
            var edited = preference
            edited.mode = mode == .off ? .automatic : .off
            try engine.setFallbackPreference(edited, profileID: "home")
            try check(edited.outputSelection == selection && edited.outputUID == "built" && audio.outputWrites == writes,
                      "Changing fallback mode retains output choice without changing routing")
            if mode == .manual && selection == .automatic {
                do {
                    try engine.setFallbackPreference(preference, profileID: "home")
                    throw CheckFailure.failed("Force accepted Automatic instead of an explicit selected UID")
                } catch let failure as CheckFailure { throw failure } catch {
                    try check(error.localizedDescription.contains("Force fallback"),
                              "Invalid Force preference reports the current user-visible label")
                }
                await engine.shutdown()
                continue
            }
            try engine.setFallbackPreference(preference, profileID: "home")
            try check(engine.suggestedAutomaticFallbackOutput(profileID: "home", snapshot: audio.value)?.uid == "phones",
                      "Automatic output hint uses the owned return route instead of a retained explicit choice")
            var missingPrevious = audio.value
            missingPrevious.devices.removeAll { $0.uid == "phones" }
            try check(engine.suggestedAutomaticFallbackOutput(profileID: "home", snapshot: missingPrevious)?.uid == "built",
                      "Automatic hint skips an absent previous output and matches built-in restoration priority")
            var physicalDeparture = audio.value
            physicalDeparture.outputUID = "interface"
            try check(engine.suggestedAutomaticFallbackOutput(profileID: "home", snapshot: physicalDeparture)?.uid == "interface",
                      "A cached physical departure overrides a stale owned return before its output event is handled")
            try check(audio.outputWrites == writes, "Automatic output hint performs no route mutation")
            engine.release(); await settleFallback()
            try check(audio.value.outputUID == (mode != .automatic && selection == .device ? "built" : "phones"),
                      "Auto Bypassed uses its automatic return; Force and Off prefer their selected output")
            try check(engine.fallbackPreference(profileID: "home") == preference,
                      "Auto Bypassed preserves a retained selected UID/name for later Force or Off")
            await engine.shutdown()
        }
    }
    for mode in [FallbackOutputMode.automatic, .manual, .off] {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let preference = FallbackOutputPreference(mode: mode, outputSelection: .device,
                                                   outputUID: "built", outputName: "Speakers")
        let engine = fallbackEngine(audio, dsp, preference: preference)
        try engine.start(); await settleFallback()
        let writes = audio.outputWrites, alerts = audio.alertWrites
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await settleFallback()
        if mode == .off {
            try check(audio.outputWrites == writes && audio.alertWrites == alerts,
                      "Off never writes normal or alert output on disconnect")
        } else {
            try check(audio.value.outputUID == (mode == .manual ? "built" : "phones"),
                      "Auto disconnect ignores the explicit Bypassed device; Manual forces that selected device")
        }
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let selected = FallbackOutputPreference(mode: .off, outputSelection: .device,
                                                outputUID: "built", outputName: "Speakers")
        let engine = fallbackEngine(audio, dsp, preference: selected)
        try engine.start(); await settleFallback()
        let writes = audio.outputWrites
        var automatic = selected; automatic.outputSelection = .automatic
        try engine.setFallbackPreference(automatic, profileID: "home")
        try check(audio.outputWrites == writes && automatic.outputUID == selected.outputUID && automatic.mode == .off,
                  "Returning output choice to Automatic keeps the last UID/name and mode without rerouting")
        engine.release(); await settleFallback()
        try check(audio.value.outputUID == "phones", "Automatic does not select the retained previous explicit UID")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP(), store = FallbackRouteStore()
        store.value = RouteRecord(profileID: "home", captureUID: "capture", previousOutputUID: "phones",
                                  previousAlertUID: "built", ownsOutput: false, ownsAlerts: true)
        audio.value.outputUID = "built"; audio.value.alertUID = "capture"
        let engine = fallbackEngine(audio, dsp, preference: .init(), store: store)
        // Startup publishes a snapshot before restoration/reconciliation. Its
        // hint must not treat alert-only ownership as an owned normal return.
        var initialHint: String?
        engine.onSnapshot = { [weak engine] snapshot in
            guard let engine else { return }
            if initialHint == nil {
                initialHint = engine.suggestedAutomaticFallbackOutput(profileID: "home", snapshot: snapshot)?.uid
            }
        }
        try engine.start()
        try check(initialHint == "built" && audio.outputWrites.isEmpty,
                  "Alert-only durable ownership does not replace the current physical Automatic hint with a stale normal return")
        await settleFallback(); await engine.shutdown()
    }
    try await runForcedManualEdgeChecks()
}

@MainActor private func runForcedManualEdgeChecks() async throws {
    let manual = FallbackOutputPreference(mode: .manual, outputUID: "built", outputName: "Speakers")
    for forceOff in [false, true] {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let engine = fallbackEngine(audio, dsp, preference: manual)
        var lastPublishedOutput: String?
        engine.onSnapshot = { lastPublishedOutput = $0.outputUID }
        engine.setMode(.automatic, profileID: "home")
        try engine.start(); await settleFallback()
        if forceOff { engine.setMode(.forceOff); await settleFallback() }
        else { audio.value.outputUID = "phones"; engine.handle(.outputChanged); await settleFallback() }
        let device = audio.value.devices.first { $0.uid == "interface" }!
        let calls = dsp.calls
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await settleFallback()
        try check(audio.value.outputUID == "built", "Manual loss forces selected output even after DSP Off or manual route departure")
        try check(lastPublishedOutput == "built", "Manual loss publishes its confirmed output without relying on another CoreAudio event")
        audio.value.outputUID = "phones"
        engine.handle(.outputChanged); engine.handle(.devicesChanged); await settleFallback()
        try check(audio.value.outputUID == "phones", "Repeated notifications between real edges preserve later user output")
        let beforeGain = audio.outputWrites.count, alertWrites = audio.alertWrites
        audio.value.devices.append(device)
        engine.handle(.outputChanged); await settleFallback()
        try check(audio.value.outputUID == "built" && audio.outputWrites.count == beforeGain + 1,
                  "Manual reconnect forces selected normal output once even if output notification arrives first")
        try check(lastPublishedOutput == "built", "Manual reconnect publishes the confirmed selected output")
        try check(audio.alertWrites == alertWrites, "Manual reconnect never forces unrelated alerts")
        try check(!audio.outputWrites.dropFirst(beforeGain).contains("capture"), "Manual reconnect has no virtual capture bounce")
        if forceOff {
            try check(engine.mode == .forceOff && dsp.calls == calls, "Settled DSP Off remains Off across Manual fallback edges")
        } else {
            try check(engine.state == .active("home") && engine.released, "Manual reconnect starts a verified DSP session with routing Bypassed")
            try engine.resume(); await settleFallback()
            try check(audio.value.outputUID == "capture" && !engine.released, "Explicit Processed resumes capture routing between hardware edges")
            engine.handle(.devicesChanged); engine.handle(.woke); await settleFallback()
            try check(audio.value.outputUID == "capture", "Repeated connected events do not override explicit Processed")
            audio.value.devices.removeAll { $0.uid == "interface" }
            engine.handle(.devicesChanged); await settleFallback()
            try check(audio.value.outputUID == "built", "The next real loss owns a new Manual enforcement")
        }
        await engine.shutdown()
    }
    for missing in [true, false] {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let engine = fallbackEngine(audio, dsp, preference: manual)
        try engine.start(); await settleFallback()
        audio.value.outputUID = "phones"; engine.handle(.outputChanged); await settleFallback()
        if missing { audio.value.devices.removeAll { $0.uid == "built" } }
        else { audio.failedUIDs.insert("built") }
        let writes = audio.outputWrites.count
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await settleFallback()
        try check(audio.value.outputUID == "phones" && engine.routingError != nil,
                  "Missing or failed Manual selection surfaces an error without choosing another physical output")
        try check(audio.outputWrites.count == writes + (missing ? 0 : 1), "Unavailable Manual selection gets no fallback candidate retry")
        await engine.shutdown()
    }
    do {
        let audio = FallbackAudio(), dsp = FallbackDSP()
        let engine = fallbackEngine(audio, dsp, preference: manual)
        try engine.start(); await settleFallback()
        let device = audio.value.devices.first { $0.uid == "interface" }!
        audio.value.devices.removeAll { $0.uid == "interface" }
        engine.handle(.devicesChanged); await settleFallback()
        dsp.onVerify = { engine.setMode(.forceOff) }
        let writes = audio.outputWrites.count
        audio.value.devices.append(device); engine.handle(.devicesChanged); await settleFallback()
        try check(engine.mode == .forceOff && engine.state == .idle && !engine.recovering,
                  "Explicit DSP Off cancels reconnect activation without retaining a pending Manual start")
        try check(!audio.outputWrites.dropFirst(writes).contains("capture"),
                  "Cancelled Manual reconnect cannot acquire virtual capture routing")
        await engine.shutdown()
    }
}

@MainActor private func runFallbackPersistenceChecks() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-checks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("fallback.json")
    let store = JSONFallbackPreferencesStore(url: url)
    let absent = try store.load()
    try check(absent == .init(), "Absent fallback sidecar defaults to Auto")
    let saved = FallbackOutputPreferences(profiles: [
        "home": .init(mode: .manual, outputUID: "missing", outputName: "Saved absent device"),
        "studio": .init(mode: .automatic, outputUID: "retained", outputName: "Last Manual choice"),
        "off": .init(mode: .off, outputUID: "retained-off", outputName: "Retained Off device")
    ])
    try store.save(saved)
    let restored = try store.load()
    try check(restored == saved, "Profile UIDs/names and Auto/Off retained Manual choices survive sidecar persistence")
    let legacy = try JSONDecoder().decode(FallbackOutputPreferences.self, from: Data("{\"profiles\":{\"home\":{\"mode\":\"automatic\",\"outputUID\":\"legacy\",\"outputName\":\"Legacy saved device\"}}}".utf8))
    try check(legacy.preference(profileID: "home").mode == .automatic && legacy.preference(profileID: "home").outputSelection == .automatic && legacy.preference(profileID: "home").outputName == "Legacy saved device",
              "Legacy v1 sidecars retain Auto behavior and saved identity")
    for oldMode in ["manual", "off"] {
        let old = try JSONDecoder().decode(FallbackOutputPreference.self, from: Data("{\"mode\":\"\(oldMode)\",\"outputUID\":\"saved\",\"outputName\":\"Saved device\"}".utf8))
        try check(old.mode.rawValue == oldMode && old.outputSelection == .device && old.outputUID == "saved",
                  "Legacy Manual/Off migrate enablement independently from retained selected device")
    }
    for mode in [FallbackOutputMode.automatic, .manual, .off] {
        for selection in [FallbackOutputSelection.automatic, .device] {
            let independent = FallbackOutputPreference(mode: mode, outputSelection: selection,
                                                        outputUID: "retained", outputName: "Retained choice")
            let data = try JSONEncoder().encode(independent)
            let decoded = try JSONDecoder().decode(FallbackOutputPreference.self, from: data)
            try check(decoded == independent, "Every independent mode/selection combination survives v1 persistence")
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try check(object["mode"] as? String == independent.mode.rawValue,
                      "New sidecars retain a derived compatible legacy mode key")
        }
    }
    let bad = Data("not-json".utf8)
    try bad.write(to: url)
    do { try store.save(.init()); throw CheckFailure.failed("Corrupt fallback sidecar overwritten") }
    catch let error as CheckFailure { throw error } catch { }
    let preserved = try Data(contentsOf: url)
    try check(preserved == bad, "Unreadable sidecar is preserved")
}
