import Foundation

public enum ControllerCommand: String, Codable, Sendable {
    case status, profiles, show, auto, on, off, retry, resume, release, reconnect, presets, preset
}
public struct ControllerRequest: Codable, Sendable {
    public let scope: String
    public let command: ControllerCommand
    public let profileID: String?
    public let presetPath: String?
    public let presetImpact: PresetImpact?
    public init(command: ControllerCommand, profileID: String? = nil, presetPath: String? = nil, presetImpact: PresetImpact? = nil) {
        self.scope = "controller"; self.command = command; self.profileID = profileID; self.presetPath = presetPath
        self.presetImpact = presetImpact
    }
}
/// Availability is independent of the GUI's retained startup policy and runtime state.
public enum GUIInstallationState: String, Codable, Sendable {
    case configured, notConfigured, uninstalled, notFound

    public var unavailableLabel: String? {
        switch self {
        case .configured: return nil
        case .notConfigured: return "Not configured"
        case .uninstalled: return "Uninstalled"
        case .notFound: return "Not found"
        }
    }
}

public struct ControllerProfile: Codable, Sendable {
    public let id: String
    public let name: String
    public let captureUID: String?
    public let available: Bool
    public let guiUnavailableReason: String?
    public let gui: GUIStatus?
    /// Optional so status replies from older controllers remain decodable.
    public let guiInstallationState: GUIInstallationState?
    public init(id: String, name: String, available: Bool, guiUnavailableReason: String?, gui: GUIStatus?, captureUID: String? = nil, guiInstallationState: GUIInstallationState? = nil) {
        self.id = id; self.name = name; self.captureUID = captureUID; self.available = available
        self.guiUnavailableReason = guiUnavailableReason; self.gui = gui
        self.guiInstallationState = guiInstallationState
    }
}
public struct ControllerStatus: Codable, Sendable {
    public let mode: String
    public let selectedProfileID: String?
    public let dspState: String
    public let outputName: String?
    public let outputUID: String?
    public let suspended: Bool
    public let profiles: [ControllerProfile]
    public let released: Bool?
    public let recovering: Bool?
    public let routingRestoring: Bool?
    public let routingError: String?
    public let dspPlaybackUID: String?
    public let dspPlaybackName: String?
    public let automaticSwitching: Bool?
    public init(mode: String, selectedProfileID: String?, dspState: String, outputName: String?, outputUID: String?, suspended: Bool, profiles: [ControllerProfile], released: Bool? = nil, recovering: Bool? = nil, routingRestoring: Bool? = nil, routingError: String? = nil, dspPlaybackUID: String? = nil, dspPlaybackName: String? = nil, automaticSwitching: Bool? = nil) {
        self.mode = mode; self.selectedProfileID = selectedProfileID; self.dspState = dspState
        self.outputName = outputName; self.outputUID = outputUID; self.suspended = suspended; self.profiles = profiles; self.released = released; self.recovering = recovering
        self.routingRestoring = routingRestoring; self.routingError = routingError
        self.dspPlaybackUID = dspPlaybackUID; self.dspPlaybackName = dspPlaybackName
        self.automaticSwitching = automaticSwitching
    }
}
public struct ControllerReply: Codable, Sendable {
    public let status: ControllerStatus?
    public let error: String?
    public let presets: PresetSnapshot?
    public init(status: ControllerStatus? = nil, error: String? = nil, presets: PresetSnapshot? = nil) {
        self.status = status; self.error = error; self.presets = presets
    }
}
