import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class SignalLevelsFixture: SignalLevelsTransport {
    var profiles: [Profile] = []
    var reads = 0
    var cancellations = 0
    var waits = 0
    var clock = 0.0
    var requestedWaits: [Double] = []
    var waitResume: CheckedContinuation<Void, Error>?
    var connectError: Error?
    var holdConnect = false
    var connection: CheckedContinuation<Void, Never>?
    var pending: [Int: CheckedContinuation<SignalLevels, Error>] = [:]
    func connect(profile: Profile) async throws {
        profiles.append(profile)
        if holdConnect { await withCheckedContinuation { connection = $0 } }
        if let connectError { throw connectError }
    }
    func read() async throws -> SignalLevels {
        reads += 1
        let id = reads
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    // Deliberately allow stale completions to arrive, to exercise controller authority.
    func cancel() { cancellations += 1 }
    func pause() async throws {
        waits += 1
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    func pacingPause(_ duration: Double) async throws {
        requestedWaits.append(duration)
        try await withCheckedThrowingContinuation { waitResume = $0 }
    }
    func complete(_ id: Int, with result: Result<SignalLevels, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }
}

@MainActor func runSignalLevelsChecks() async throws {
    let profile = Profile(id: "levels", name: "Levels fixture", triggerUID: "trigger", captureUID: "capture", playbackUID: "playback",
                          launchAgentLabel: "unused", launchAgentPath: "/unused", websocketURL: "ws://127.0.0.1:1234",
                          expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
    let sample = SignalLevels(input: [.init(label: "Left", rmsDB: -24, peakDB: -6)], output: [.init(label: "Main", rmsDB: -18, peakDB: 1)])
    try runSignalMeterBallisticsChecks()
    var initialDecoder = SignalLevelsIntervalDecoder(inputLabels: ["Left"], outputLabels: ["Main"])
    func initialInterval(_ values: [String: [Double]]) throws -> SignalLevels {
        try initialDecoder.decode(JSONSerialization.data(withJSONObject: ["GetSignalLevelsSinceLast": ["result": "Ok", "value": values]]))
    }
    let partialInitial = try initialInterval(["capture_rms": [], "capture_peak": [], "playback_rms": [-30], "playback_peak": [-6]])
    let startupTransport = SignalLevelsFixture()
    let startupReader = SignalLevelsController(transport: startupTransport, wait: { try await startupTransport.pause() })
    startupReader.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("Initial history reader did not query") { startupTransport.pending[1] != nil }
    startupTransport.complete(1, with: .success(partialInitial))
    try await eventually("Initial history reader did not continue") { startupTransport.pending[2] != nil }
    try check(startupReader.snapshot.levels == nil && startupReader.snapshot.displayLevels == nil && startupReader.snapshot.numericPeakLevels == nil,
              "Buffered initial output-only interval leaves the measured snapshot empty for remembered placeholders")
    let completeInitial = try initialInterval(["capture_rms": [-40], "capture_peak": [-3], "playback_rms": [], "playback_peak": []])
    startupTransport.complete(2, with: .success(completeInitial))
    try await eventually("Complete initial history was not published") { startupTransport.pending[3] != nil }
    try check(startupReader.snapshot.levels == completeInitial && startupReader.snapshot.inputFreshness[0].peakAvailable &&
              startupReader.snapshot.outputFreshness[0].rmsAvailable && startupReader.snapshot.outputFreshness[0].peakAvailable,
              "First complete topology publishes buffered components once with available initial freshness")
    startupReader.stop(); startupTransport.complete(3, with: .success(completeInitial))
    let transport = SignalLevelsFixture()
    let controller = SignalLevelsController(transport: transport, wait: { try await transport.pause() })
    try check(!controller.snapshot.enabled && !controller.snapshot.reading && controller.snapshot.levels == nil, "Meters default Off without querying")
    controller.update(enabled: false, visible: true, profile: profile, ready: true)
    controller.update(enabled: true, visible: false, profile: profile, ready: true)
    controller.update(enabled: true, visible: true, profile: profile, ready: false)
    controller.update(enabled: true, visible: true, profile: nil, ready: true)
    await Task.yield()
    try check(transport.profiles.isEmpty && transport.reads == 0, "Off, closed, unready and missing profile issue zero meter queries")
    controller.update(enabled: true, visible: true, profile: profile, ready: true)
    controller.update(enabled: false, visible: true, profile: profile, ready: true)
    await Task.yield()
    try check(transport.profiles.isEmpty && transport.reads == 0, "Off before queued task starts prevents creating a meter connection")
    controller.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("First gated meter query missing") { transport.pending[1] != nil }
    for id in 1...2 {
        try check(transport.reads == id, "No overlapping current-chunk meter reads")
        transport.complete(id, with: .success(sample))
        try await eventually("Next gated meter query missing") { transport.pending[id + 1] != nil }
    }
    try check(controller.snapshot.levels == sample && transport.profiles.count == 1 && transport.waits == 2, "Repeated meter reads wait after each completed chunk and reuse one connection")
    let cancels = transport.cancellations
    controller.update(enabled: false, visible: true, profile: profile, ready: true)
    try check(transport.cancellations > cancels && controller.snapshot.levels == nil && controller.snapshot.numericPeakLevels == nil && !controller.snapshot.reading, "Off closes transport and clears meters synchronously")
    transport.complete(3, with: .success(sample))
    await Task.yield()
    try check(controller.snapshot.levels == nil && transport.reads == 3, "Off rejects a stale sample and stops all further reads")

    for cause in ["panel close", "readiness loss", "profile change", "shutdown"] {
        let fixture = SignalLevelsFixture()
        let reader = SignalLevelsController(transport: fixture, wait: { try await Task.sleep(nanoseconds: 1_000_000) })
        reader.update(enabled: true, visible: true, profile: profile, ready: true)
        try await eventually("Cancellation fixture did not read") { fixture.pending[1] != nil }
        switch cause {
        case "panel close": reader.update(enabled: true, visible: false, profile: profile, ready: true)
        case "readiness loss": reader.update(enabled: true, visible: true, profile: profile, ready: false)
        case "profile change":
            var replacement = profile; replacement.id = "replacement"
            reader.update(enabled: true, visible: true, profile: replacement, ready: true)
            try await eventually("Replacement profile did not connect") { fixture.pending[2] != nil }
        default: reader.stop()
        }
        fixture.complete(1, with: .success(sample))
        await Task.yield()
        try check(reader.snapshot.levels == nil && reader.snapshot.numericPeakLevels == nil && fixture.cancellations > 0, "\(cause) cancels authority and ignores the previous read")
        reader.stop()
        fixture.complete(2, with: .failure(SwitcherError.message("stale failure")))
        await Task.yield()
        try check(reader.snapshot.error != "Live Metering stopped: stale failure", "Stale failure cannot replace current status")
    }

    let connecting = SignalLevelsFixture(); connecting.holdConnect = true
    let connectingReader = SignalLevelsController(transport: connecting)
    connectingReader.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("Meter connect never suspended") { connecting.connection != nil }
    connectingReader.update(enabled: false, visible: true, profile: profile, ready: true)
    connecting.connection?.resume(); connecting.connection = nil
    await Task.yield()
    try check(connecting.reads == 0, "Off during connection prevents even the first meter query")

    let failing = SignalLevelsFixture()
    let failingReader = SignalLevelsController(transport: failing, wait: { try await failing.pause() })
    failingReader.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("Failure fixture did not read") { failing.pending[1] != nil }
    failing.complete(1, with: .failure(SwitcherError.message("fixture disconnected")))
    try await eventually("Meter error did not stop the reader") { failingReader.snapshot.error != nil }
    failingReader.update(enabled: true, visible: true, profile: profile, ready: true,
                         options: SignalMeterOptions(peakHoldMilliseconds: 0, falloffDBPerSecond: 80, refreshHz: 30))
    try await Task.sleep(nanoseconds: 40_000_000)
    try check(failing.reads == 1 && failing.profiles.count == 1 && failing.waits == 0 && !failingReader.snapshot.reading && failingReader.snapshot.numericPeakLevels == nil, "Error stops reads with no scheduled retry or settings-only restart")
    failingReader.retry()
    try await eventually("Manual Retry did not restart meters") { failing.pending[2] != nil }
    failing.complete(2, with: .failure(SwitcherError.message("fixture disconnected again")))
    try await eventually("Second error did not stop") { failingReader.snapshot.error != nil }
    failingReader.update(enabled: true, visible: false, profile: profile, ready: true)
    failingReader.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("Panel reopen did not restart meters") { failing.pending[3] != nil }
    failingReader.stop(); failing.complete(3, with: .success(sample))

    let numericFailure = SignalLevelsFixture()
    let numericFailureReader = SignalLevelsController(transport: numericFailure, wait: { try await numericFailure.pause() })
    numericFailureReader.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("Numeric failure fixture did not read") { numericFailure.pending[1] != nil }
    numericFailure.complete(1, with: .success(sample))
    try await eventually("Numeric failure fixture did not retain sample") { numericFailure.pending[2] != nil }
    try check(numericFailureReader.snapshot.numericPeakLevels?.output[0].peakDB == 1,
              "Controller publishes actual held numeric peaks alongside current samples")
    numericFailure.complete(2, with: .failure(SwitcherError.message("numeric failure")))
    try await eventually("Numeric failure did not stop") { numericFailureReader.snapshot.error != nil }
    try check(numericFailureReader.snapshot.numericPeakLevels != nil && numericFailureReader.snapshot.displayLevels != nil &&
              numericFailureReader.snapshot.levels == sample && numericFailureReader.snapshot.inputFreshness.allSatisfy({ !$0.peakAvailable && !$0.rmsAvailable }),
              "Reader failure retains dimmed measurements without fabricating silence")
    numericFailureReader.stop()

    let unavailableFixture = SignalLevelsFixture()
    let unavailableReader = SignalLevelsController(transport: unavailableFixture, wait: { try await unavailableFixture.pause() })
    unavailableReader.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("Unavailable fixture did not read") { unavailableFixture.pending[1] != nil }
    unavailableFixture.complete(1, with: .success(sample))
    try await eventually("Unavailable fixture did not receive sample") { unavailableFixture.pending[2] != nil }
    var clearedDuringAuthorityLoss = false
    unavailableReader.onChange = { if $0.levels == nil { clearedDuringAuthorityLoss = true } }
    unavailableReader.update(enabled: true, visible: true, profile: profile, ready: false)
    try check(!clearedDuringAuthorityLoss && unavailableReader.snapshot.levels == sample &&
              !unavailableReader.snapshot.inputFreshness[0].peakAvailable,
              "Same-profile readiness loss publishes only retained unavailable values, with no transient cleared geometry")
    unavailableReader.onChange = nil
    unavailableReader.stop(); unavailableFixture.complete(2, with: .success(sample))

    let boundedFixture = SignalLevelsFixture()
    let boundedReader = SignalLevelsController(transport: boundedFixture, now: { boundedFixture.clock }, wait: { _ in try await boundedFixture.pause() })
    boundedReader.update(enabled: true, visible: true, profile: profile, ready: true)
    for index in 1...140 {
        try await eventually("Bounded diagnostic fixture did not read") { boundedFixture.pending[index] != nil }
        boundedFixture.clock += 0.1
        boundedFixture.complete(index, with: .success(sample))
    }
    try await eventually("Bounded diagnostic fixture did not finish") { boundedFixture.pending[141] != nil }
    try check(boundedReader.snapshot.diagnostics.completedReads == 128 && boundedReader.snapshot.diagnostics.freshReads == 128 &&
              abs(boundedReader.snapshot.diagnostics.observedSuccessfulHz! - 10) < 1e-8 &&
              abs(boundedReader.snapshot.diagnostics.observationSeconds! - 12.8) < 1e-8,
              "Diagnostic window remains bounded at 128 reads and computes measured observation rate")
    let readsBeforeReport = boundedFixture.reads
    _ = boundedReader.snapshot.diagnostics.report
    boundedReader.stop()
    _ = boundedReader.snapshot.diagnostics.report
    try check(boundedFixture.reads == readsBeforeReport, "On-demand diagnostic reports never start or add meter reads")
    boundedFixture.complete(141, with: .success(sample))

    let connectionFailure = SignalLevelsFixture(); connectionFailure.connectError = SwitcherError.message("not ready")
    let connectionFailureReader = SignalLevelsController(transport: connectionFailure)
    connectionFailureReader.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("Connection error did not surface") { connectionFailureReader.snapshot.error != nil }
    try check(connectionFailure.reads == 0 && !connectionFailureReader.snapshot.reading, "Failed readiness or configuration never starts meter reads")
    connectionFailureReader.stop()
    let paced = SignalLevelsFixture()
    let pacedReader = SignalLevelsController(transport: paced, now: { paced.clock }, wait: { try await paced.pacingPause($0) })
    pacedReader.update(enabled: true, visible: true, profile: profile, ready: true)
    try await eventually("Paced reader did not query") { paced.pending[1] != nil }
    paced.clock = 0.03; paced.complete(1, with: .success(sample))
    try await eventually("Paced reader did not calculate wait") { paced.waitResume != nil }
    try check(abs(paced.requestedWaits[0] - 0.07) < 1e-9, "10 Hz target subtracts 30 ms response time")
    paced.clock = 0.1; paced.waitResume?.resume(); paced.waitResume = nil
    try await eventually("Paced reader did not issue second query") { paced.pending[2] != nil }
    paced.clock = 0.25; paced.complete(2, with: .success(sample))
    try await eventually("Slow response reader did not continue") { paced.pending[3] != nil }
    try check(paced.requestedWaits.count == 1, "Slow response uses zero extra period and starts only one next request")
    try check(pacedReader.snapshot.diagnostics.completedReads == 2 && pacedReader.snapshot.diagnostics.freshReads == 2 &&
              abs(pacedReader.snapshot.diagnostics.observedSuccessfulHz! - 1 / 0.22) < 1e-9 &&
              abs(pacedReader.snapshot.diagnostics.meanReadMilliseconds! - 90) < 1e-9,
              "Meter diagnostics measure completed successful reads and actual durations from existing clock")
    let emptyDisplay = pacedReader.snapshot.displayLevels
    let emptyNumeric = pacedReader.snapshot.numericPeakLevels
    pacedReader.update(enabled: true, visible: true, profile: profile, ready: true,
                       options: SignalMeterOptions(peakHoldMilliseconds: 0, falloffDBPerSecond: 80, refreshHz: 30))
    try check(paced.profiles.count == 1 && paced.pending.count == 1, "Changing meter settings retains one socket and one in-flight query")
    paced.clock = 0.26; paced.complete(3, with: .success(SignalLevels(input: [], output: [])))
    try await eventually("Changed cadence did not pace") { paced.waitResume != nil }
    try check(abs(paced.requestedWaits.last! - (1.0 / 30 - 0.01)) < 1e-9,
              "Updated 30 Hz cadence applies without reconnecting")
    try check(pacedReader.snapshot.displayLevels == emptyDisplay && pacedReader.snapshot.numericPeakLevels == emptyNumeric && pacedReader.snapshot.levels == sample,
              "Empty update retains sample values and held markers without fabricating silence")
    paced.clock = 4; paced.waitResume?.resume(); paced.waitResume = nil
    try await eventually("Freshness fixture did not continue") { paced.pending[4] != nil }
    paced.clock = 4.01
    paced.complete(4, with: .success(SignalLevels(input: [.init(label: "Left", rmsDB: -24, peakDB: -6, rmsUpdated: true, peakUpdated: false)], output: [])))
    try await eventually("Partial freshness was not published") { paced.waitResume != nil }
    try check(pacedReader.snapshot.inputFreshness[0].rmsAvailable && !pacedReader.snapshot.inputFreshness[0].peakAvailable &&
              !pacedReader.snapshot.outputFreshness[0].rmsAvailable && !pacedReader.snapshot.outputFreshness[0].peakAvailable,
              "RMS-only input restores RMS freshness while old input peaks and missing output remain unavailable")
    let retainedDiagnostics = pacedReader.snapshot.diagnostics
    pacedReader.stop(); paced.waitResume?.resume(throwing: CancellationError()); paced.waitResume = nil
    await Task.yield()
    try check(pacedReader.snapshot.displayLevels == nil && pacedReader.snapshot.numericPeakLevels == nil && paced.reads == 4,
              "Stop during pacing clears all meter history and prevents further reads")
    try check(!pacedReader.snapshot.diagnostics.running && pacedReader.snapshot.diagnostics.completedReads == retainedDiagnostics.completedReads &&
              pacedReader.snapshot.diagnostics.lastSuccessfulRead == retainedDiagnostics.lastSuccessfulRead,
              "Stopping retains the last diagnostic summary without extra reads")
    try check(SignalLevelsPanelVerification.warningCaptionsAndBelowRangeNumbers(), "Neutral RMS/Peak heading uses green Realtime and orange Peak Hold when focused and gray modes when inactive; Keep Active Colors preserves mode and readings while restoring caption colors without focus; below-range numbers preserve raw measurements and clipping")
    try check(SignalLevelsPanelVerification.completeDisplayActivatesOnce(), "Whole meter display toggles once, excludes native controls, ignores drags and permits local mode changes while DSP is unavailable")
    try check(SignalLevelsPanelVerification.unavailableReadingsStayStable(), "Partial stale readings dim and fresh reads restore retained rows and numbers")
    try check(SignalLevelsPanelVerification.offlineModeNeverSeedsStaleMaxima(), "Offline mode switches are local, clear held history, retain unavailable rows and initialize maxima only from fresh channel peaks")
    try check(SignalLevelsPanelVerification.numericModesStayStable(),
              "dBFS heading and channel numbers toggle numbers and markers with stable controls, observed maxima and fresh reset")
    try check(SignalLevelsPanelVerification.partialInitialIntervalsPreserveTopology(),
              "Partial initial intervals after reopening retain remembered rows and Peak Hold maxima with unavailable placeholders; confirmed topology changes replace rows")
    try check(SignalLevelsPanelVerification.peakHoldMarkersIgnoreTimedExpiry(),
              "Peak Hold markers and numbers retain per-channel maxima past zero and finite timed holds, accept fresh rises and restore timed Realtime markers")
    try check(SignalLevelsPanelVerification.displayRangeIsStable(),
              "Meter display range preserves measured values, held clipping, rows and height while formatting numbers below the current minimum")
    try check(SignalLevelsPanelVerification.verifyDisplayRangeRasterization(renderDirectory: ProcessInfo.processInfo.environment["AUTOSWITCH_PANEL_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }),
              "Light and dark meter rasters retain absolute cyan/green gradient, yellow/red thresholds, cropped scales, independent RMS/peak and clipped indicators; Keep Active Colors restores colored fills without actual focus or sample changes")
    try check(SignalLevelsPanelVerification.groupedRowsStayStable(), "Live Metering adds only an 8 point IN/OUT gap and preserves rows and geometry during samples")
    try runSignalLevelsProtocolChecks()
    print("Live Metering checks: gating, repeated reads, immediate cancellation, stale results, manual retry and protocol validation passed")
}

private func runSignalLevelsProtocolChecks() throws {
    func reply(_ command: String, _ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [command: ["result": "Ok", "value": value]])
    }
    func rejects(_ message: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try check(rejected, message)
    }
    let config: [String: Any] = ["devices": ["capture": ["channels": 2, "labels": ["Left", ""]], "playback": ["channels": 1, "labels": ["Main"]]]]
    let configJSON = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
    let labels = try SignalLevelsProtocol.labels(configuration: reply("GetConfigJson", configJSON))
    try check(labels.input == ["Left", "Channel 2"] && labels.output == ["Main"], "Configuration labels preserve names and supply missing-name fallback")
    let value: [String: Any] = ["capture_rms": [-96, -24], "capture_peak": [-80, -6], "playback_rms": [-18], "playback_peak": [1]]
    let levels = try SignalLevelsProtocol.decode(reply("GetSignalLevels", value), inputLabels: labels.input, outputLabels: labels.output)
    try check(levels.input[1].label == "Channel 2" && levels.input[1].rmsDB == -24 && levels.input[1].peakDB == -6 && levels.output[0].peakDB == 1, "Current chunk maps separate RMS and peak values without smoothing or clamping")
    var interval = SignalLevelsIntervalDecoder(inputLabels: labels.input, outputLabels: labels.output)
    let transient = try interval.decode(reply("GetSignalLevelsSinceLast", value))
    try check(transient == levels, "Combined interval values retain between-query peaks and RMS")
    let empty: [String: Any] = ["capture_rms": [], "capture_peak": [], "playback_rms": [], "playback_peak": []]
    let noNew = try interval.decode(reply("GetSignalLevelsSinceLast", empty))
    try check(noNew.input[0].rmsDB == levels.input[0].rmsDB && noNew.input.allSatisfy({ !$0.rmsUpdated && !$0.peakUpdated }),
              "No-new-data interval carries retained values with explicit unchanged flags")
    var partial = empty; partial["capture_peak"] = [-2, -1]
    let peakOnly = try interval.decode(reply("GetSignalLevelsSinceLast", partial))
    try check(peakOnly.input[1].peakDB == -1 && peakOnly.input[1].peakUpdated && !peakOnly.input[1].rmsUpdated,
              "Partial interval preserves RMS while exposing a fresh transient peak")
    var startup = SignalLevelsIntervalDecoder(inputLabels: labels.input, outputLabels: labels.output)
    let unpaired = try startup.decode(reply("GetSignalLevelsSinceLast", partial))
    try check(unpaired.input.isEmpty, "Missing initial RMS never invents a starting level")
    partial = empty; partial["capture_rms"] = [-30, -40]
    let stillUnpaired = try startup.decode(reply("GetSignalLevelsSinceLast", partial))
    try check(stillUnpaired.input.isEmpty && stillUnpaired.output.isEmpty,
              "An initial complete input pair waits for output history instead of confirming a smaller topology")
    partial = empty; partial["playback_rms"] = [-20]; partial["playback_peak"] = [-3]
    let completedPair = try startup.decode(reply("GetSignalLevelsSinceLast", partial))
    try check(completedPair.input[1].peakDB == -1 && completedPair.input[1].rmsDB == -40 &&
              (completedPair.input + completedPair.output).allSatisfy({ $0.rmsUpdated && $0.peakUpdated }),
              "Atomic initial publication retains buffered transients and makes every first observed component fresh")
    for outputFirst in [true, false] {
        var reopening = SignalLevelsIntervalDecoder(inputLabels: labels.input, outputLabels: labels.output)
        let missing = try reopening.decode(reply("GetSignalLevelsSinceLast", empty))
        try check(missing.input.isEmpty && missing.output.isEmpty, "All-missing initial history confirms no smaller topology")
        var first = empty
        first[outputFirst ? "playback_rms" : "capture_rms"] = outputFirst ? [-30] : [-40, -45]
        first[outputFirst ? "playback_peak" : "capture_peak"] = outputFirst ? [-2] : [-3, -4]
        let oneSide = try reopening.decode(reply("GetSignalLevelsSinceLast", first))
        try check(oneSide.input.isEmpty && oneSide.output.isEmpty, "Either initial side waits for the full configured topology")
        first[outputFirst ? "playback_peak" : "capture_peak"] = outputFirst ? [-20] : [-30, -35]
        _ = try reopening.decode(reply("GetSignalLevelsSinceLast", first))
        var last = empty
        last[outputFirst ? "capture_rms" : "playback_rms"] = outputFirst ? [-40, -45] : [-30]
        last[outputFirst ? "capture_peak" : "playback_peak"] = outputFirst ? [-3, -4] : [-2]
        let complete = try reopening.decode(reply("GetSignalLevelsSinceLast", last))
        try check(complete.input.count == 2 && complete.output.count == 1 && complete.input[0].peakDB == -3 &&
                  complete.output[0].peakDB == -2 && (complete.input + complete.output).allSatisfy({ $0.rmsUpdated && $0.peakUpdated }),
                  "Complete initial topology exposes buffered per-channel maxima from either side")
        var changed = empty; changed["capture_peak"] = [-1]
        try rejects("Changed nonempty interval count requires reconnect rather than silently retaining removed channels") {
            _ = try reopening.decode(reply("GetSignalLevelsSinceLast", changed))
        }
        var replacement = SignalLevelsIntervalDecoder(inputLabels: ["Replacement"], outputLabels: [])
        let reconfigured: [String: Any] = ["capture_rms": [-50], "capture_peak": [-40], "playback_rms": [], "playback_peak": []]
        let replaced = try replacement.decode(reply("GetSignalLevelsSinceLast", reconfigured))
        try check(replaced.input.count == 1 && replaced.output.isEmpty && replaced.input[0].label == "Replacement" && replaced.input[0].peakDB == -40,
                  "Reconnect initializes the actual new topology; a zero-label side completes without fabricated levels")
    }
    var outputOnlyDecoder = SignalLevelsIntervalDecoder(inputLabels: [], outputLabels: ["Only output"])
    let outputOnlyValue: [String: Any] = ["capture_rms": [], "capture_peak": [], "playback_rms": [-20], "playback_peak": [-10]]
    let outputOnlyLevels = try outputOnlyDecoder.decode(reply("GetSignalLevelsSinceLast", outputOnlyValue))
    try check(outputOnlyLevels.input.isEmpty && outputOnlyLevels.output.count == 1 && outputOnlyLevels.output[0].peakUpdated,
              "A zero-label input side does not block a configured output-only decoder")
    for (key, invalid) in [("capture_rms", [true, -24] as [Any]), ("capture_peak", [-6] as [Any]), ("playback_peak", ["1"] as [Any])] {
        var bad = value; bad[key] = invalid
        try rejects("Reject malformed or changed meter arrays") { _ = try SignalLevelsProtocol.decode(reply("GetSignalLevels", bad), inputLabels: labels.input, outputLabels: labels.output) }
    }
    try rejects("Reject wrong response command") { _ = try SignalLevelsProtocol.decode(reply("GetState", "Running"), inputLabels: labels.input, outputLabels: labels.output) }
    try rejects("Reject nonfinite JSON level") { _ = try SignalLevelsProtocol.decode(Data("{\"GetSignalLevels\":{\"result\":\"Ok\",\"value\":{\"capture_rms\":[NaN,0],\"capture_peak\":[0,0],\"playback_rms\":[0],\"playback_peak\":[0]}}}".utf8), inputLabels: labels.input, outputLabels: labels.output) }
    for count in [true, 0, 65, 1.5] as [Any] {
        let badConfig: [String: Any] = ["devices": ["capture": ["channels": count], "playback": ["channels": 1]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: badConfig), encoding: .utf8)!
        try rejects("Reject invalid meter channel counts") { _ = try SignalLevelsProtocol.labels(configuration: reply("GetConfigJson", json)) }
    }
    try rejects("Reject array count differing from cached channel configuration") { _ = try SignalLevelsProtocol.decode(reply("GetSignalLevels", value), inputLabels: ["Left"], outputLabels: labels.output) }
}

@MainActor private func runSignalMeterBallisticsChecks() throws {
    func sample(_ rms: Double, _ peak: Double, secondPeak: Double = -10) -> SignalLevels {
        SignalLevels(input: [.init(label: "A", rmsDB: rms, peakDB: peak), .init(label: "B", rmsDB: -40, peakDB: secondPeak)], output: [])
    }
    let options = SignalMeterOptions()
    var meter = SignalMeterBallistics()
    _ = meter.consume(sample(-20, -3), at: 0, options: options)
    var shown = meter.consume(sample(-80, -50), at: 0.1, options: options)
    try check(abs(shown.input[0].rmsDB - (-24)) < 1e-9 && shown.input[0].peakDB == -3,
              "RMS release uses actual elapsed time while peak holds for 3000 ms")
    shown = meter.consume(sample(-80, -50, secondPeak: -1), at: 2, options: options)
    shown = meter.consume(sample(-80, -50, secondPeak: -60), at: 3.25, options: options)
    try check(abs(shown.input[0].peakDB - (-13)) < 1e-9 && shown.input[1].peakDB == -1,
              "Higher peak resets only its channel hold and release starts after its deadline")
    shown = meter.consume(sample(-80, -50, secondPeak: -60), at: 3.75, options: options)
    try check(abs(shown.input[0].peakDB - (-33)) < 1e-9, "Peak falloff remains 40 dB per second at variable cadence")
    shown = meter.consume(sample(-10, 2), at: 3.8, options: options)
    try check(shown.input[0].rmsDB == -10 && shown.input[0].peakDB == 2, "Rising RMS and transient peak respond immediately")
    let unchanged = meter.consume(SignalLevels(input: [], output: []), at: 20, options: options)
    try check(unchanged == shown, "An empty sample cannot reset held peaks or synthesize silence")
    var noHold = SignalMeterBallistics()
    let zero = SignalMeterOptions(peakHoldMilliseconds: 0)
    _ = noHold.consume(sample(-20, -3), at: 0, options: zero)
    let released = noHold.consume(sample(-80, -50), at: 0.1, options: zero)
    try check(abs(released.input[0].peakDB - (-7)) < 1e-9, "Zero peak hold releases immediately at the selected falloff")
    let backward = noHold.consume(sample(-80, -50), at: 0.05, options: zero)
    try check(backward.input[0].peakDB == released.input[0].peakDB, "Backward clock input cannot reverse meter release")
    try check(options.peakHoldMilliseconds == 3000 && options.numberHoldMilliseconds == 500 && options.numericPeakHoldMilliseconds == 5000,
              "Realtime number hold defaults to 500 ms independently of legacy numeric and marker holds")
    var numeric = SignalMeterBallistics()
    _ = numeric.consume(sample(-20, -3), at: 0, options: options)
    _ = numeric.consume(sample(-80, -50), at: 0.49, options: options)
    try check(numeric.numericPeakLevels.input[0].peakDB == -3, "Lower peak waits for number hold expiry")
    _ = numeric.consume(sample(-80, -50), at: 0.5, options: options)
    _ = numeric.consume(sample(-80, -60), at: 0.6, options: options)
    try check(numeric.numericPeakLevels.input[0].peakDB == -50, "Lower value after expiry rearms its number hold")
    _ = numeric.consume(sample(-80, -2, secondPeak: -1), at: 0.7, options: options)
    _ = numeric.consume(sample(-80, -60, secondPeak: -60), at: 1.19, options: options)
    try check(numeric.numericPeakLevels.input[0].peakDB == -2 && numeric.numericPeakLevels.input[1].peakDB == -1,
              "Higher fresh peaks appear immediately and rearm each independent channel")
    _ = numeric.consume(SignalLevels(input: [.init(label: "A", rmsDB: -50, peakDB: 30, rmsUpdated: true, peakUpdated: false)], output: []),
                        at: 2, options: options)
    try check(numeric.numericPeakLevels.input[0].peakDB == -2, "RMS-only arrival after expiry cannot reset or fabricate peak")
    _ = numeric.consume(SignalLevels(input: [.init(label: "A", rmsDB: -50, peakDB: -40, rmsUpdated: false, peakUpdated: true)], output: []),
                        at: 2.1, options: options)
    try check(numeric.numericPeakLevels.input[0].peakDB == -40, "Fresh peak-only arrival after expiry accepts lower value")
    let retained = numeric.numericPeakLevels
    _ = numeric.consume(SignalLevels(input: [], output: []), at: 100, options: options)
    try check(numeric.numericPeakLevels == retained, "Empty sides preserve timed held peaks")
    var numericZero = SignalMeterBallistics()
    let instant = SignalMeterOptions(numberHoldMilliseconds: 0)
    _ = numericZero.consume(sample(-20, -3), at: 0, options: instant)
    let marker = numericZero.consume(sample(-40, -40), at: 0.1, options: instant)
    try check(numericZero.numericPeakLevels.input[0].peakDB == -40 && marker.input[0].peakDB == -3,
              "Zero Number hold follows fresh samples while marker remains held")
    for value in [-1.0, 5001, Double.infinity] {
        var invalid = false
        do { _ = try SignalMeterOptions(numberHoldMilliseconds: value).validated() } catch { invalid = true }
        try check(invalid, "Number hold rejects nonfinite or outside 0...5000 values")
    }
    _ = try SignalMeterOptions(refreshHz: 120).validated()
    var rejectsTooFast = false
    do { _ = try SignalMeterOptions(refreshHz: 120.01).validated() } catch { rejectsTooFast = true }
    try check(rejectsTooFast, "Meter cadence validates the confirmed maximum of 120 Hz")
    for hz in [1.0, 10, 30, 60, 120] {
        try check(abs(SignalLevelsController.pacingDelay(refreshHz: hz, started: 2, completed: 2.01) - max(0, 1 / hz - 0.01)) < 1e-9,
                  "Cadence subtracts response time throughout the supported range")
    }
    try check(abs(SignalLevelsController.pacingDelay(refreshHz: 120, started: 2, completed: 2.002) - (1.0 / 120 - 0.002)) < 1e-9,
              "120 Hz target preserves positive wait after a two millisecond response")
    try check(SignalLevelsController.pacingDelay(refreshHz: 120, started: 2, completed: 2.02) == 0,
              "120 Hz slow response waits zero extra time without a catch-up burst")
}
