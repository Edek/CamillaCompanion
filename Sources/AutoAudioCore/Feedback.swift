import Foundation

public struct FeedbackSettings: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case off, errorsOnly, allChanges }
    public enum Position: String, Codable, Sendable { case lowerCenter, center }
    public var mode: Mode = .off
    public var outputChanges = true
    public var guiChanges = true
    public var durationSeconds: Double = 4
    public var errorDurationSeconds: Double = 6
    public var position: Position = .lowerCenter
    public init() {}
    private enum CodingKeys: String, CodingKey { case mode, outputChanges, guiChanges, durationSeconds, errorDurationSeconds, position }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .off
        outputChanges = try c.decodeIfPresent(Bool.self, forKey: .outputChanges) ?? true
        guiChanges = try c.decodeIfPresent(Bool.self, forKey: .guiChanges) ?? true
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 4
        errorDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .errorDurationSeconds) ?? 6
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? .lowerCenter
    }
}
public enum FeedbackEvent {
    case output(uid: String, name: String, restored: Bool)
    case gui(profile: String, running: Bool)
    case failure(source: String, message: String)
}
public struct FeedbackMessage: Equatable {
    public enum Category: Equatable { case output, gui, other }
    public let category: Category
    public let text: String
    public let symbol: String
    public let isError: Bool
    public init(text: String, symbol: String, isError: Bool = false, category: Category = .other) {
        self.category = category
        self.text = text; self.symbol = symbol; self.isError = isError
    }
}
/// Pure event filtering; no timers or service references.
public struct FeedbackPolicy {
    public let settings: FeedbackSettings
    public private(set) var silentMode = false
    private var lastOutput: String?
    private var guiStates: [String: Bool] = [:]
    private var failures: [String: String] = [:]
    public init(settings: FeedbackSettings) { self.settings = settings }
    public mutating func setSilentMode(_ enabled: Bool) { silentMode = enabled }
    public mutating func seedOutput(_ uid: String?) { if lastOutput == nil { lastOutput = uid } }
    public mutating func message(for event: FeedbackEvent) -> FeedbackMessage? {
        switch event {
        case let .output(uid, name, restored):
            failures.removeValue(forKey: "dsp")
            guard lastOutput != uid else { return nil }; lastOutput = uid
            guard !silentMode, settings.mode == .allChanges, settings.outputChanges else { return nil }
            return FeedbackMessage(text: "Output \(restored ? "restored" : "changed") to \(name)", symbol: "speaker.wave.2.fill", category: .output)
        case let .gui(profile, running):
            failures.removeValue(forKey: "gui:" + profile)
            guard guiStates[profile] != running else { return nil }; guiStates[profile] = running
            guard !silentMode, settings.mode == .allChanges, settings.guiChanges else { return nil }
            return FeedbackMessage(text: "CamillaGUI \(running ? "started" : "stopped")", symbol: "slider.horizontal.3", category: .gui)
        case let .failure(source, message):
            if source.hasPrefix("gui:") { guiStates.removeValue(forKey: String(source.dropFirst(4))) }
            guard failures[source] != message else { return nil }; failures[source] = message
            guard !silentMode, settings.mode != .off else { return nil }
            if source.hasPrefix("gui:"), !settings.guiChanges { return nil }
            return FeedbackMessage(text: source.hasPrefix("gui:") ? "CamillaGUI failed" : "CamillaDSP routing failed", symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }
}

/// A bounded event burst: latest output and GUI state, or the latest failure.
/// The HUD can retain this while an error is visible without building a queue.
public struct FeedbackBurst {
    private var messages: [FeedbackMessage] = []
    public init() {}
    public var isEmpty: Bool { messages.isEmpty }
    public mutating func append(_ message: FeedbackMessage) {
        if message.isError { messages = [message]; return }
        guard !messages.contains(where: { $0.isError }) else { return }
        messages.removeAll { $0.category == message.category }
        messages.append(message)
    }
    public mutating func take() -> FeedbackMessage? {
        defer { messages.removeAll() }
        guard let first = messages.first else { return nil }
        guard messages.count > 1 else { return first }
        return FeedbackMessage(text: messages.map(\.text).joined(separator: " · "), symbol: "speaker.wave.2.fill")
    }
}

/// Presentation state is independent of clocks. The platform dismisses only
/// after the current message's full duration, then asks for retained successes.
public struct FeedbackPresentation {
    private var pending = FeedbackBurst()
    private var deferredSuccess = FeedbackBurst()
    private var visibleError = false
    public init() {}
    public mutating func reset() { self = FeedbackPresentation() }
    /// Whether this event needs a short coalescing deadline.
    public mutating func append(_ message: FeedbackMessage) -> Bool {
        if message.isError { deferredSuccess = FeedbackBurst() }
        if visibleError && !message.isError {
            deferredSuccess.append(message)
            return false
        }
        pending.append(message)
        return true
    }
    public mutating func takePending() -> FeedbackMessage? { pending.take() }
    public mutating func displayed(_ message: FeedbackMessage) { visibleError = message.isError }
    public mutating func dismissed() -> FeedbackMessage? {
        visibleError = false
        return deferredSuccess.take()
    }
}
