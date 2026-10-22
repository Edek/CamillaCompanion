import Foundation

/// Explicit app metadata shared by the command line and native About window.
public enum ApplicationMetadata {
    public static let name = "CamillaCompanion"
    public static let description = "A macOS companion for CamillaDSP."
    public static let version = "0.1.0-beta.2"
    public static let buildIdentifier = "beta"
    public static let copyright = "© 2026 Thiago Baldissarelli"
    public static let supportURL = URL(string: "https://ko-fi.com/camillacompanion")!
    public static let githubURL = URL(string: "https://github.com/Edek/CamillaCompanion")!
}

public struct TransitionTiming: Equatable, Sendable {
    public let label: String
    public let seconds: TimeInterval
    public let outcome: String
}

/// Receives existing lifecycle events. Reading diagnostics is the only time
/// ongoing durations are computed; it installs no timer or monitoring task.
@MainActor public final class SessionTransitionTimings {
    private struct Pending { let label: String; let started: TimeInterval }
    private var pending: [String: Pending] = [:]
    public private(set) var samples: [TransitionTiming] = []
    private let now: () -> TimeInterval
    private let capacity: Int

    public init(capacity: Int = 12, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    public func begin(_ key: String, label: String) {
        if pending[key]?.label == label { return }
        if pending[key] != nil { finish(key, outcome: "superseded") }
        pending[key] = Pending(label: label, started: now())
    }

    public func finish(_ key: String, outcome: String) {
        guard let event = pending.removeValue(forKey: key) else { return }
        samples.append(TransitionTiming(label: event.label, seconds: elapsed(event.started), outcome: outcome))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    private func elapsed(_ started: TimeInterval) -> TimeInterval {
        let value = now() - started
        return value.isFinite ? max(0, value) : 0
    }

    public var diagnosticText: String {
        let completed = samples.map { "\($0.label): \(String(format: "%.3f", $0.seconds)) s (\($0.outcome))" }
        let ongoing = pending.keys.sorted().compactMap { key -> String? in
            guard let event = pending[key] else { return nil }
            return "\(event.label): \(String(format: "%.3f", elapsed(event.started))) s (in progress)"
        }
        let lines = completed + ongoing
        return lines.isEmpty ? "No transition samples in this session." : lines.joined(separator: "\n")
    }
}
