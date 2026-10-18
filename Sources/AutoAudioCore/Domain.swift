import Foundation

public struct AudioDevice: Equatable, Sendable {
    public let uid: String
    public let name: String
    public let hasOutput: Bool
    public let isBuiltIn: Bool
    public init(uid: String, name: String, hasOutput: Bool, isBuiltIn: Bool = false) {
        self.uid = uid; self.name = name; self.hasOutput = hasOutput; self.isBuiltIn = isBuiltIn
    }
}

public struct AudioSnapshot: Equatable, Sendable {
    public var devices: [AudioDevice]
    public var outputUID: String?
    public var alertUID: String?
    public init(devices: [AudioDevice], outputUID: String?, alertUID: String?) {
        self.devices = devices; self.outputUID = outputUID; self.alertUID = alertUID
    }
}

public struct Profile: Codable, Equatable, Sendable {
    /// First-run profiles refuse separately managed DSP processes at activation.
    /// Optional for compatibility with existing configuration documents.
    public var requiresExclusiveDSP: Bool?
    public var gui: GUIConfiguration?
    public var id: String
    public var name: String
    public var triggerUID: String
    public var captureUID: String
    public var playbackUID: String
    public var launchAgentLabel: String
    public var launchAgentPath: String
    public var websocketURL: String
    /// Exact CamillaDSP configuration selectors (UID or name, depending on its config).
    public var expectedCaptureDevice: String
    public var expectedPlaybackDevice: String
    public var routeAlerts: Bool
    public var autoActivate: Bool
    public var startupDelayMilliseconds: Int
    public init(id: String, name: String, triggerUID: String, captureUID: String,
                playbackUID: String, launchAgentLabel: String, launchAgentPath: String,
                websocketURL: String, expectedCaptureDevice: String, expectedPlaybackDevice: String,
                routeAlerts: Bool = false, autoActivate: Bool = true, startupDelayMilliseconds: Int = 1500, gui: GUIConfiguration? = nil,
                requiresExclusiveDSP: Bool? = nil) {
        self.requiresExclusiveDSP = requiresExclusiveDSP
        self.gui = gui
        self.id = id; self.name = name; self.triggerUID = triggerUID; self.captureUID = captureUID
        self.playbackUID = playbackUID; self.launchAgentLabel = launchAgentLabel
        self.launchAgentPath = launchAgentPath; self.websocketURL = websocketURL
        self.expectedCaptureDevice = expectedCaptureDevice; self.expectedPlaybackDevice = expectedPlaybackDevice
        self.routeAlerts = routeAlerts; self.autoActivate = autoActivate
        self.startupDelayMilliseconds = startupDelayMilliseconds
    }
}

public struct Configuration: Codable, Sendable {
    public var feedback: FeedbackSettings?
    public var version: Int
    public var profiles: [Profile]
    public init(version: Int = 1, profiles: [Profile]) { self.version = version; self.profiles = profiles }
}

public enum AutomationMode: String, Codable, Sendable { case automatic, forceOn, forceOff }
/// Only transient service failures enter bounded recovery. Configuration errors remain fatal.
public enum DSPFailure: Error, LocalizedError, Equatable {
    case starting
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .starting: return "CamillaDSP is still starting"
        case .unavailable(let reason): return reason
        }
    }
}
public enum RuntimeState: Equatable, Sendable {
    case idle
    case starting(String)
    case active(String)
    case stopping(String)
    case needsSelection
    case suspended
    case failed(String)
}

public struct RouteRecord: Codable, Equatable, Sendable {
    public var profileID: String
    public var captureUID: String
    public var previousOutputUID: String?
    public var previousAlertUID: String?
    public var ownsOutput: Bool
    public var ownsAlerts: Bool
    public init(profileID: String, captureUID: String, previousOutputUID: String?, previousAlertUID: String?,
                ownsOutput: Bool, ownsAlerts: Bool) {
        self.profileID = profileID; self.captureUID = captureUID
        self.previousOutputUID = previousOutputUID; self.previousAlertUID = previousAlertUID
        self.ownsOutput = ownsOutput; self.ownsAlerts = ownsAlerts
    }
}

public enum AudioEvent: Sendable { case devicesChanged, outputChanged, woke }
public enum SwitcherError: Error, LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor public protocol AudioManaging: AnyObject {
    func snapshot() throws -> AudioSnapshot
    func setOutput(uid: String) throws
    func setAlertOutput(uid: String) throws
    func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws
    func stopMonitoring()
}

@MainActor public protocol DSPManaging: AnyObject {
    /// Start or adopt the configured job. Does not itself change audio routing.
    func start(_ profile: Profile) async throws
    /// One finite verification, no repeated queries; monitor failures after success.
    func verifyReadiness(_ profile: Profile) async throws
    func stop(_ profile: Profile) async throws
    var onFailure: (@MainActor (String) -> Void)? { get set }
}

@MainActor public protocol RouteStoring: AnyObject {
    func load() throws -> RouteRecord?
    func save(_ record: RouteRecord?) throws
}

@MainActor public protocol TransitionSleeping: AnyObject {
    func sleep(milliseconds: Int) async throws
}

@MainActor public final class TaskSleeper: TransitionSleeping {
    public init() {}
    public func sleep(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}

public struct GUIConfiguration: Codable, Equatable, Sendable {
    public var executablePath: String
    public var configPath: String
    public var url: String
    public var autoStart: Bool
    public init(executablePath: String, configPath: String, url: String, autoStart: Bool = false) {
        self.executablePath = executablePath; self.configPath = configPath
        self.url = url; self.autoStart = autoStart
    }
    private enum CodingKeys: String, CodingKey { case executablePath, configPath, url, autoStart }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        executablePath = try values.decode(String.self, forKey: .executablePath)
        configPath = try values.decode(String.self, forKey: .configPath)
        url = try values.decode(String.self, forKey: .url)
        autoStart = try values.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}
public enum GUICommand: String, Codable, Sendable { case start, stop, auto, status, retry }
public enum GUIPolicy: String, Codable, Sendable { case automatic, manualOn, manualOff }
public enum GUIServiceState: String, Codable, Sendable { case stopped, starting, running, stopping, failed }
public struct GUIStatus: Codable, Sendable {
    public let profileID: String
    public let policy: GUIPolicy
    public let autoStart: Bool
    public let desiredRunning: Bool
    public var observed: GUIServiceState
    public let url: String
    public var lastError: String?
    public var recovering: Bool?
    public init(profileID: String, policy: GUIPolicy, autoStart: Bool, desiredRunning: Bool,
                observed: GUIServiceState, url: String, lastError: String?, recovering: Bool? = nil) {
        self.profileID = profileID; self.policy = policy; self.autoStart = autoStart
        self.desiredRunning = desiredRunning; self.observed = observed; self.url = url; self.lastError = lastError; self.recovering = recovering
    }
}
public enum GUIFailure: Error, LocalizedError, Equatable {
    case starting(String)
    case transient(String)
    case permanent(String)
    public var errorDescription: String? {
        switch self { case .starting(let reason), .transient(let reason), .permanent(let reason): return reason }
    }
    public var recoverable: Bool {
        switch self { case .starting, .transient: return true; case .permanent: return false }
    }
}
@MainActor public protocol GUIManaging: AnyObject {
    var onExit: (@MainActor (String, String) -> Void)? { get set }
    func start(_ profile: Profile) async throws
    func verifyReadiness(_ profile: Profile) async throws
    func beginRecovery(_ profile: Profile, deadline: TimeInterval)
    func stop(_ profile: Profile) async throws
}
public extension GUIManaging {
    func beginRecovery(_ profile: Profile, deadline: TimeInterval) {}
    func verifyReadiness(_ profile: Profile) async throws {}
}
