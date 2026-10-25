import Foundation

public enum DeviceRole: Sendable {
    case dspInput, dspOutput, managedFeed, trigger
    public func accepts(_ device: AudioDevice) -> Bool {
        switch self {
        case .dspInput: return device.hasInput
        case .dspOutput: return device.hasOutput
        case .managedFeed: return device.hasInput && device.hasOutput
        case .trigger: return true
        }
    }
    public func unavailableReason(for device: AudioDevice) -> String? {
        guard !accepts(device) else { return nil }
        switch self {
        case .dspInput: return "This device has no input channels."
        case .dspOutput: return "This device has no output channels."
        case .managedFeed: return "Automatic Switching requires a device with both input and output channels."
        case .trigger: return "This device is unavailable."
        }
    }
}

public struct AudioDevice: Equatable, Sendable {
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }
    public let isBuiltIn: Bool
    public init(uid: String, name: String, hasOutput: Bool, isBuiltIn: Bool = false) {
        // Legacy fixtures treated configured capture devices as duplex. Keep
        // that source compatibility while real inventory uses channel counts.
        self.init(uid: uid, name: name, inputChannels: hasOutput ? 1 : 0,
                  outputChannels: hasOutput ? 1 : 0, isBuiltIn: isBuiltIn)
    }
    public init(uid: String, name: String, inputChannels: Int, outputChannels: Int, isBuiltIn: Bool = false) {
        self.uid = uid; self.name = name
        self.inputChannels = max(0, inputChannels); self.outputChannels = max(0, outputChannels)
        self.isBuiltIn = isBuiltIn
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
    /// Legacy v1 field retained as the CamillaDSP capture device identity.
    public var captureUID: String
    /// macOS output used to feed processed audio in Automatic Switching.
    /// Nil is valid for Companion-only profiles.
    public var managedFeedUID: String?
    public var dspInputUID: String { captureUID }
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
        self.init(id: id, name: name, triggerUID: triggerUID, captureUID: captureUID,
                  managedFeedUID: captureUID, playbackUID: playbackUID,
                  launchAgentLabel: launchAgentLabel, launchAgentPath: launchAgentPath,
                  websocketURL: websocketURL, expectedCaptureDevice: expectedCaptureDevice,
                  expectedPlaybackDevice: expectedPlaybackDevice, routeAlerts: routeAlerts,
                  autoActivate: autoActivate, startupDelayMilliseconds: startupDelayMilliseconds,
                  gui: gui, requiresExclusiveDSP: requiresExclusiveDSP)
    }
    /// Explicit role-aware initializer. Passing nil opts out of system-output routing.
    public init(id: String, name: String, triggerUID: String, captureUID: String, managedFeedUID: String?,
                playbackUID: String, launchAgentLabel: String, launchAgentPath: String,
                websocketURL: String, expectedCaptureDevice: String, expectedPlaybackDevice: String,
                routeAlerts: Bool = false, autoActivate: Bool = true, startupDelayMilliseconds: Int = 1500,
                gui: GUIConfiguration? = nil, requiresExclusiveDSP: Bool? = nil) {
        self.requiresExclusiveDSP = requiresExclusiveDSP
        self.gui = gui
        self.id = id; self.name = name; self.triggerUID = triggerUID; self.captureUID = captureUID
        self.managedFeedUID = managedFeedUID
        self.playbackUID = playbackUID; self.launchAgentLabel = launchAgentLabel
        self.launchAgentPath = launchAgentPath; self.websocketURL = websocketURL
        self.expectedCaptureDevice = expectedCaptureDevice; self.expectedPlaybackDevice = expectedPlaybackDevice
        self.routeAlerts = routeAlerts; self.autoActivate = autoActivate
        self.startupDelayMilliseconds = startupDelayMilliseconds
    }

    public func uid(for role: DeviceRole) -> String? {
        switch role {
        case .dspInput: return captureUID
        case .dspOutput: return playbackUID
        case .managedFeed: return managedFeedUID
        case .trigger: return triggerUID
        }
    }
    public func deviceAvailable(for role: DeviceRole, in snapshot: AudioSnapshot) -> Bool {
        guard let uid = uid(for: role), let device = snapshot.devices.first(where: { $0.uid == uid }) else { return false }
        return role.accepts(device)
    }
    public func deviceRolesAvailable(in snapshot: AudioSnapshot, automaticSwitching: Bool,
                                     requireTrigger: Bool = true) -> Bool {
        guard deviceAvailable(for: .dspInput, in: snapshot),
              deviceAvailable(for: .dspOutput, in: snapshot) else { return false }
        guard !automaticSwitching || deviceAvailable(for: .managedFeed, in: snapshot) else { return false }
        return !requireTrigger || deviceAvailable(for: .trigger, in: snapshot)
    }

    private enum CodingKeys: String, CodingKey {
        case requiresExclusiveDSP, gui, id, name, triggerUID, captureUID, managedFeedUID, playbackUID
        case launchAgentLabel, launchAgentPath, websocketURL, expectedCaptureDevice, expectedPlaybackDevice
        case routeAlerts, autoActivate, startupDelayMilliseconds
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requiresExclusiveDSP = try values.decodeIfPresent(Bool.self, forKey: .requiresExclusiveDSP)
        gui = try values.decodeIfPresent(GUIConfiguration.self, forKey: .gui)
        id = try values.decode(String.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        triggerUID = try values.decode(String.self, forKey: .triggerUID)
        captureUID = try values.decode(String.self, forKey: .captureUID)
        managedFeedUID = values.contains(.managedFeedUID)
            ? try values.decodeIfPresent(String.self, forKey: .managedFeedUID) : captureUID
        playbackUID = try values.decode(String.self, forKey: .playbackUID)
        launchAgentLabel = try values.decode(String.self, forKey: .launchAgentLabel)
        launchAgentPath = try values.decode(String.self, forKey: .launchAgentPath)
        websocketURL = try values.decode(String.self, forKey: .websocketURL)
        expectedCaptureDevice = try values.decode(String.self, forKey: .expectedCaptureDevice)
        expectedPlaybackDevice = try values.decode(String.self, forKey: .expectedPlaybackDevice)
        routeAlerts = try values.decodeIfPresent(Bool.self, forKey: .routeAlerts) ?? false
        autoActivate = try values.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? true
        startupDelayMilliseconds = try values.decodeIfPresent(Int.self, forKey: .startupDelayMilliseconds) ?? 1500
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(requiresExclusiveDSP, forKey: .requiresExclusiveDSP)
        try values.encodeIfPresent(gui, forKey: .gui)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
        try values.encode(triggerUID, forKey: .triggerUID); try values.encode(captureUID, forKey: .captureUID)
        if let managedFeedUID { try values.encode(managedFeedUID, forKey: .managedFeedUID) }
        else { try values.encodeNil(forKey: .managedFeedUID) }
        try values.encode(playbackUID, forKey: .playbackUID)
        try values.encode(launchAgentLabel, forKey: .launchAgentLabel); try values.encode(launchAgentPath, forKey: .launchAgentPath)
        try values.encode(websocketURL, forKey: .websocketURL)
        try values.encode(expectedCaptureDevice, forKey: .expectedCaptureDevice)
        try values.encode(expectedPlaybackDevice, forKey: .expectedPlaybackDevice)
        try values.encode(routeAlerts, forKey: .routeAlerts); try values.encode(autoActivate, forKey: .autoActivate)
        try values.encode(startupDelayMilliseconds, forKey: .startupDelayMilliseconds)
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
