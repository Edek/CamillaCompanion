import Foundation

public struct SignalChannelLevel: Equatable, Sendable {
    public var label: String
    public var rmsDB: Double
    public var peakDB: Double
    public var rmsUpdated: Bool
    public var peakUpdated: Bool
    public init(label: String, rmsDB: Double, peakDB: Double, rmsUpdated: Bool = true, peakUpdated: Bool = true) {
        self.label = label; self.rmsDB = rmsDB; self.peakDB = peakDB
        self.rmsUpdated = rmsUpdated; self.peakUpdated = peakUpdated
    }
}
public struct SignalLevels: Equatable, Sendable {
    public var input: [SignalChannelLevel]
    public var output: [SignalChannelLevel]
    public init(input: [SignalChannelLevel], output: [SignalChannelLevel]) { self.input = input; self.output = output }
}
public struct SignalChannelFreshness: Equatable, Sendable {
    public var rmsAvailable: Bool
    public var peakAvailable: Bool
    public init(rmsAvailable: Bool, peakAvailable: Bool) {
        self.rmsAvailable = rmsAvailable; self.peakAvailable = peakAvailable
    }
}

/// A bounded trailing window of completed reads, distinct from fresh DSP components.
public struct SignalLevelsDiagnostics: Equatable, Sendable {
    public var requestedRefreshHz: Double = 10
    public private(set) var running = false
    public private(set) var lastSuccessfulRead: Date?
    private struct Read: Equatable, Sendable { var started: Double; var completed: Double; var fresh: Bool }
    private var reads: [Read] = []
    public init() {}
    public var completedReads: Int { reads.count }
    public var freshReads: Int { reads.filter(\.fresh).count }
    public var observationSeconds: Double? {
        guard let first = reads.first, let last = reads.last else { return nil }
        return max(0, last.completed - first.started)
    }
    public var observedSuccessfulHz: Double? {
        guard reads.count > 1, let first = reads.first, let last = reads.last,
              last.completed > first.completed else { return nil }
        return Double(reads.count - 1) / (last.completed - first.completed)
    }
    public var meanReadMilliseconds: Double? {
        guard !reads.isEmpty else { return nil }
        return reads.reduce(0) { $0 + max(0, $1.completed - $1.started) } / Double(reads.count) * 1000
    }
    public var maximumReadMilliseconds: Double? { reads.map { max(0, $0.completed - $0.started) * 1000 }.max() }
    public var report: String {
        func value(_ number: Double?, suffix: String) -> String { number.map { String(format: "%.2f", $0) + suffix } ?? "Unavailable" }
        let last = lastSuccessfulRead.map { ISO8601DateFormatter().string(from: $0) } ?? "Unavailable"
        return "Live Metering: " + (running ? "reading" : "stopped; last session retained")
            + "\nRequested refresh: " + value(requestedRefreshHz, suffix: " Hz")
            + "\nObserved successful reads: " + value(observedSuccessfulHz, suffix: " Hz")
            + "\nObservation window: " + value(observationSeconds, suffix: " s") + " (last \(completedReads) successful reads, maximum 128)"
            + "\nReads with fresh DSP components: \(freshReads); read frequency does not prove DSP sample frequency"
            + "\nLast successful read: " + last
            + "\nRead duration mean / maximum: " + value(meanReadMilliseconds, suffix: " ms") + " / " + value(maximumReadMilliseconds, suffix: " ms")
    }
    mutating func start(refreshHz: Double) { self = .init(); requestedRefreshHz = refreshHz; running = true }
    mutating func stop() { running = false }
    mutating func record(started: Double, completed: Double, fresh: Bool) {
        reads.append(Read(started: started, completed: completed, fresh: fresh))
        if reads.count > 128 { reads.removeFirst(reads.count - 128) }
        lastSuccessfulRead = Date()
    }
}

public struct SignalLevelsSnapshot: Equatable, Sendable {
    public var enabled = false
    public var reading = false
    public var levels: SignalLevels?
    public var displayLevels: SignalLevels?
    /// Independent held numeric peaks; marker falloff stays in displayLevels.
    public var numericPeakLevels: SignalLevels?
    public var error: String?
    public var inputFreshness: [SignalChannelFreshness] = []
    public var outputFreshness: [SignalChannelFreshness] = []
    public var diagnostics = SignalLevelsDiagnostics()
    public init() {}
}
@MainActor public protocol SignalLevelsTransport: AnyObject {
    func connect(profile: Profile) async throws
    func read() async throws -> SignalLevels
    func cancel()
}

/// Sample-driven display history. Empty sides leave both samples and holds intact.
public struct SignalMeterBallistics: Sendable {
    private struct Channel: Sendable {
        var level: SignalChannelLevel
        var rmsTime: Double
        var peakTime: Double
        var holdUntil: Double
        var numericPeakDB: Double
        var latestPeakDB: Double
        var numericHoldUntil: Double
    }
    private var input: [Channel] = []
    private var output: [Channel] = []
    public init() {}
    public var numericPeakLevels: SignalLevels {
        func values(_ channels: [Channel]) -> [SignalChannelLevel] {
            channels.map { channel in
                var level = channel.level
                level.peakDB = channel.numericPeakDB
                return level
            }
        }
        return SignalLevels(input: values(input), output: values(output))
    }
    public mutating func reset() { input = []; output = [] }
    public mutating func consume(_ sample: SignalLevels, at time: Double, options: SignalMeterOptions) -> SignalLevels {
        func apply(_ fresh: [SignalChannelLevel], previous: [Channel]) -> [Channel] {
            guard !fresh.isEmpty else { return previous }
            return fresh.enumerated().map { index, level in
                guard index < previous.count, previous[index].level.label == level.label else {
                    return Channel(level: level, rmsTime: time, peakTime: time, holdUntil: time + options.peakHoldMilliseconds / 1000,
                                   numericPeakDB: level.peakDB, latestPeakDB: level.peakDB,
                                   numericHoldUntil: time + options.numberHoldMilliseconds / 1000)
                }
                let prior = previous[index]
                guard level.rmsUpdated || level.peakUpdated else { return prior }
                let now = max(max(prior.rmsTime, prior.peakTime), time)
                var result = level
                result.rmsDB = level.rmsUpdated ? max(level.rmsDB,
                    prior.level.rmsDB - options.falloffDBPerSecond * (now - prior.rmsTime)) : prior.level.rmsDB
                let raisedPeak = level.peakUpdated && level.peakDB > prior.level.peakDB
                let hold = raisedPeak ? now + options.peakHoldMilliseconds / 1000 : prior.holdUntil
                result.peakDB = !level.peakUpdated ? prior.level.peakDB : (raisedPeak ? level.peakDB : max(level.peakDB,
                    prior.level.peakDB - options.falloffDBPerSecond * max(0, now - max(prior.peakTime, hold))))
                let latestPeak = level.peakUpdated ? level.peakDB : prior.latestPeakDB
                // Only fresh peaks advance numbers. Every accepted value rearms the
                // deadline, including lower values accepted after expiry.
                let numericRaised = level.peakUpdated && level.peakDB > prior.numericPeakDB
                let numericExpired = now >= prior.numericHoldUntil
                let acceptsNumeric = level.peakUpdated && (numericRaised || numericExpired)
                let numericPeak = acceptsNumeric ? latestPeak : prior.numericPeakDB
                let numericHold = acceptsNumeric ? now + options.numberHoldMilliseconds / 1000 : prior.numericHoldUntil
                return Channel(level: result, rmsTime: level.rmsUpdated ? now : prior.rmsTime,
                               peakTime: level.peakUpdated ? now : prior.peakTime, holdUntil: hold,
                               numericPeakDB: numericPeak, latestPeakDB: latestPeak, numericHoldUntil: numericHold)
            }
        }
        input = apply(sample.input, previous: input)
        output = apply(sample.output, previous: output)
        return SignalLevels(input: input.map(\.level), output: output.map(\.level))
    }
    /// Apply a changed hold time to retained history without reconnecting or adding timers.
    public mutating func adjustHold(from old: SignalMeterOptions, to new: SignalMeterOptions) {
        let delta = (new.peakHoldMilliseconds - old.peakHoldMilliseconds) / 1000
        let numericDelta = (new.numberHoldMilliseconds - old.numberHoldMilliseconds) / 1000
        for index in input.indices { input[index].holdUntil += delta; input[index].numericHoldUntil += numericDelta }
        for index in output.indices { output[index].holdUntil += delta; output[index].numericHoldUntil += numericDelta }
    }
}

/// The sole recurring reader is opt-in, and only lives while its panel is visible.
/// A failure stops it. Opening the panel again or Retry starts a new attempt.
@MainActor public final class SignalLevelsController {
    public private(set) var snapshot = SignalLevelsSnapshot()
    public var onChange: ((SignalLevelsSnapshot) -> Void)?
    private let transport: SignalLevelsTransport
    private let wait: @Sendable (Double) async throws -> Void
    private let now: @MainActor () -> Double
    private var options = SignalMeterOptions()
    private var ballistics = SignalMeterBallistics()
    private var enabled = false
    private var visible = false
    private var profile: Profile?
    private var ready = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var inputTimes: [(rms: Double?, peak: Double?)] = []
    private var outputTimes: [(rms: Double?, peak: Double?)] = []
    public init(transport: SignalLevelsTransport,
                now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                wait: @escaping @Sendable (Double) async throws -> Void = { duration in
                    try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
                }) {
        self.transport = transport; self.wait = wait; self.now = now
    }
    public convenience init(transport: SignalLevelsTransport, wait: @escaping @Sendable () async throws -> Void) {
        self.init(transport: transport, wait: { _ in try await wait() })
    }
    public func update(enabled: Bool, visible: Bool, profile: Profile?, ready: Bool, options: SignalMeterOptions = .init()) {
        do { _ = try options.validated() }
        catch { stop(); snapshot.error = "Live Metering settings are invalid: " + error.localizedDescription; publish(); return }
        if self.options != options {
            ballistics.adjustHold(from: self.options, to: options)
            self.options = options
            snapshot.diagnostics.requestedRefreshHz = options.refreshHz
        }
        guard self.enabled != enabled || self.visible != visible || self.profile != profile || self.ready != ready else { return }
        let unavailableLevels = enabled && !ready && self.profile == profile ? snapshot : nil
        stop(publishChange: false)
        if let retained = unavailableLevels {
            snapshot.levels = retained.levels; snapshot.displayLevels = retained.displayLevels
            snapshot.numericPeakLevels = retained.numericPeakLevels
            snapshot.inputFreshness = (retained.levels?.input ?? []).map { _ in .init(rmsAvailable: false, peakAvailable: false) }
            snapshot.outputFreshness = (retained.levels?.output ?? []).map { _ in .init(rmsAvailable: false, peakAvailable: false) }
        }
        self.enabled = enabled; self.visible = visible; self.profile = profile; self.ready = ready
        snapshot.enabled = enabled
        snapshot.error = enabled && !ready ? "DSP levels are unavailable while DSP is stopped or disconnected." : nil
        publish()
        startIfAllowed()
    }
    public func retry() {
        stop(); snapshot.error = nil; publish(); startIfAllowed()
    }
    public func stop(publishChange: Bool = true) {
        generation += 1
        task?.cancel(); task = nil; transport.cancel()
        ballistics.reset(); inputTimes = []; outputTimes = []
        snapshot.inputFreshness = []; snapshot.outputFreshness = []
        snapshot.diagnostics.stop()
        snapshot.reading = false; snapshot.levels = nil; snapshot.displayLevels = nil; snapshot.numericPeakLevels = nil
        if publishChange { publish() }
    }
    public static func pacingDelay(refreshHz: Double, started: Double, completed: Double) -> Double {
        max(0, 1 / refreshHz - max(0, completed - started))
    }
    private func startIfAllowed() {
        guard enabled, visible, ready, let profile else { return }
        let token = generation
        snapshot.diagnostics.start(refreshHz: options.refreshHz)
        snapshot.reading = true; publish()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, token == self.generation else { return }
            do {
                try await self.transport.connect(profile: profile)
                while !Task.isCancelled, token == self.generation {
                    let started = self.now()
                    let sample = try await self.transport.read()
                    guard !Task.isCancelled, token == self.generation else { return }
                    let completed = self.now()
                    let fresh = (sample.input + sample.output).contains(where: { $0.rmsUpdated || $0.peakUpdated })
                    self.snapshot.diagnostics.record(started: started, completed: completed, fresh: fresh)
                    if fresh {
                        let previous = self.snapshot.levels
                        self.snapshot.levels = SignalLevels(input: sample.input.isEmpty ? previous?.input ?? [] : sample.input,
                            output: sample.output.isEmpty ? previous?.output ?? [] : sample.output)
                        self.snapshot.displayLevels = self.ballistics.consume(sample, at: completed, options: self.options)
                        self.snapshot.numericPeakLevels = self.ballistics.numericPeakLevels
                        self.snapshot.error = nil
                    }
                    self.refreshFreshness(sample: sample, at: completed)
                    self.publish()
                    let delay = Self.pacingDelay(refreshHz: self.options.refreshHz, started: started, completed: completed)
                    // Even slow reads yield, with no queued catch-up burst.
                    if delay > 0 { try await self.wait(delay) } else { await Task.yield() }
                }
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.transport.cancel(); self.task = nil; self.ballistics.reset()
                self.snapshot.reading = false; self.snapshot.diagnostics.stop()
                self.snapshot.inputFreshness = (self.snapshot.levels?.input ?? []).map { _ in .init(rmsAvailable: false, peakAvailable: false) }
                self.snapshot.outputFreshness = (self.snapshot.levels?.output ?? []).map { _ in .init(rmsAvailable: false, peakAvailable: false) }
                self.snapshot.error = "Live Metering stopped: " + error.localizedDescription
                self.publish()
            }
        }
    }
    private func refreshFreshness(sample: SignalLevels, at time: Double) {
        // Evaluate age only on existing read arrivals. Request failures mark every
        // retained component unavailable immediately, without a stale watcher.
        func update(_ fresh: [SignalChannelLevel], count: Int, times: inout [(rms: Double?, peak: Double?)]) -> [SignalChannelFreshness] {
            if times.count != count { times = Array(repeating: (nil, nil), count: count) }
            for index in fresh.indices where index < times.count {
                if fresh[index].rmsUpdated { times[index].rms = time }
                if fresh[index].peakUpdated { times[index].peak = time }
            }
            return times.map { .init(rmsAvailable: $0.rms.map { time - $0 < 3 } ?? false,
                                     peakAvailable: $0.peak.map { time - $0 < 3 } ?? false) }
        }
        snapshot.inputFreshness = update(sample.input, count: snapshot.levels?.input.count ?? 0, times: &inputTimes)
        snapshot.outputFreshness = update(sample.output, count: snapshot.levels?.output.count ?? 0, times: &outputTimes)
    }
    private func publish() { onChange?(snapshot) }
}
