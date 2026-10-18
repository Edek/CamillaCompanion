import Foundation
import CoreFoundation

public struct PresetImpact: Codable, Equatable, Sendable {
    public var requiresAudioRestart: Bool
    public var settingChanges: [String]
    public init(requiresAudioRestart: Bool = false, settingChanges: [String] = []) {
        self.requiresAudioRestart = requiresAudioRestart; self.settingChanges = settingChanges
    }
}

/// Classification uses daemon-normalized configurations. CamillaDSP v4.1.3
/// restarts processing whenever its devices structure differs, even when an
/// optional setting only changes from implicit default to an explicit value.
public enum PresetCompatibility {
    public static let supportedSettingKeys: Set<String> = ["adjust_period", "enable_rate_adjust", "rate_measure_interval",
        "chunksize", "queuelimit", "target_level"]
    public static func classify(activeConfiguration: String, candidateConfiguration: String) throws -> PresetImpact {
        func devices(_ source: String) throws -> [String: Any] {
            guard let config = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any],
                  let devices = config["devices"] as? [String: Any] else {
                throw SwitcherError.message("Preset has no normalized devices block.")
            }
            return devices
        }
        func encoded(_ value: Any?) throws -> Data {
            try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
        }
        func display(_ value: Any?) throws -> String {
            guard let value, !(value is NSNull) else { return "default" }
            return String(decoding: try encoded(value), as: UTF8.self)
        }
        func numeric(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        let old = try devices(activeConfiguration), new = try devices(candidateConfiguration)
        for key in ["capture", "playback"] {
            guard let oldDevice = old[key] as? [String: Any], let newDevice = new[key] as? [String: Any],
                  oldDevice["type"] as? String == "CoreAudio", newDevice["type"] as? String == "CoreAudio" else {
                throw SwitcherError.message("Preset \(key) backend must remain CoreAudio for this profile.")
            }
            for field in Set(oldDevice.keys).union(newDevice.keys).sorted() {
                guard try encoded(oldDevice[field]) == encoded(newDevice[field]) else {
                    throw SwitcherError.message("Preset changes unsupported field \(key).\(field). Keep the active device, channels and format.")
                }
            }
        }
        guard let rate = numeric(new["samplerate"]), rate > 0, rate.rounded() == rate,
              try encoded(old["samplerate"]) == encoded(new["samplerate"]) else {
            throw SwitcherError.message("Preset changes or invalidates nominal samplerate. Keep the active sample rate.")
        }
        var changes: [String] = []
        for key in Set(old.keys).union(new.keys).sorted() where key != "capture" && key != "playback" {
            guard try encoded(old[key]) != encoded(new[key]) else { continue }
            guard supportedSettingKeys.contains(key) else {
                throw SwitcherError.message("Preset changes unsupported devices field \(key).")
            }
            if let value = new[key], !(value is NSNull) {
                switch key {
                case "enable_rate_adjust":
                    guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
                        throw SwitcherError.message("enable_rate_adjust must be a boolean.")
                    }
                case "chunksize", "queuelimit", "target_level":
                    guard let number = numeric(value), number.rounded() == number,
                          number >= (key == "target_level" ? 0 : 1) else {
                        throw SwitcherError.message("\(key) must be a valid nonnegative integer buffer setting.")
                    }
                default:
                    guard let number = numeric(value), number > 0 else {
                        throw SwitcherError.message("\(key) must be a positive finite period.")
                    }
                }
            } else if key == "chunksize" {
                throw SwitcherError.message("chunksize must remain an explicit positive integer.")
            }
            let unit: String
            switch key {
            case "adjust_period", "rate_measure_interval": unit = " seconds"
            case "chunksize", "target_level": unit = " frames"
            case "queuelimit": unit = " chunks"
            default: unit = ""
            }
            changes.append("\(key): \(try display(old[key])) → \(try display(new[key]))\(unit)")
        }
        return PresetImpact(requiresAudioRestart: !changes.isEmpty, settingChanges: changes)
    }
}

public struct PresetEntry: Codable, Equatable, Sendable {
    public var path: String
    public var title: String
    public var available: Bool
    public var reason: String?
    public var requiresAudioRestart: Bool
    public var settingChanges: [String]
    public var impact: PresetImpact { PresetImpact(requiresAudioRestart: requiresAudioRestart, settingChanges: settingChanges) }
    public init(path: String, title: String, available: Bool = true, reason: String? = nil,
                requiresAudioRestart: Bool = false, settingChanges: [String] = []) {
        self.path = path; self.title = String(title.prefix(160)); self.available = available
        self.reason = reason.map { String($0.prefix(600)) }
        self.requiresAudioRestart = requiresAudioRestart; self.settingChanges = settingChanges
    }
    private enum CodingKeys: String, CodingKey { case path, title, available, reason, requiresAudioRestart, settingChanges }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try values.decode(String.self, forKey: .path), title: try values.decode(String.self, forKey: .title),
            available: try values.decodeIfPresent(Bool.self, forKey: .available) ?? true,
            reason: try values.decodeIfPresent(String.self, forKey: .reason),
            requiresAudioRestart: try values.decodeIfPresent(Bool.self, forKey: .requiresAudioRestart) ?? false,
            settingChanges: try values.decodeIfPresent([String].self, forKey: .settingChanges) ?? [])
    }
}
public struct PresetDSPState: Equatable, Sendable {
    public var activePath: String?
    public var activeTitle: String?
    public var entries: [PresetEntry]
    public init(activePath: String? = nil, activeTitle: String? = nil, entries: [PresetEntry] = []) {
        self.activePath = activePath; self.activeTitle = activeTitle.map { String($0.prefix(160)) }; self.entries = entries
    }
}
public enum PresetFailure: Error, LocalizedError, Sendable {
    /// Recovery confirmed this actual configuration, which may have been edited
    /// externally since the last menu inspection.
    case restored(String, PresetDSPState)
    public var errorDescription: String? {
        switch self { case .restored(let reason, _): return reason }
    }
}
public struct PresetSnapshot: Codable, Equatable, Sendable {
    public var profileID: String?
    public var entries: [PresetEntry]
    public var activePath: String?
    public var activeTitle: String?
    public var ready: Bool
    public var busy: Bool
    public var error: String?
    public init(profileID: String? = nil, entries: [PresetEntry] = [], activePath: String? = nil,
                activeTitle: String? = nil, ready: Bool = false, busy: Bool = false, error: String? = nil) {
        self.profileID = profileID; self.entries = entries; self.activePath = activePath
        self.activeTitle = activeTitle; self.ready = ready; self.busy = busy; self.error = error
    }
}
@MainActor public protocol PresetDSPTransport: AnyObject {
    func inspect(profile: Profile, paths: [String]) async throws -> PresetDSPState
    func apply(path: String, profile: Profile) async throws -> PresetDSPState
    func apply(path: String, profile: Profile, expectedImpact: PresetImpact) async throws -> PresetDSPState
    func cancel()
}
public extension PresetDSPTransport {
    func apply(path: String, profile: Profile, expectedImpact: PresetImpact) async throws -> PresetDSPState {
        try await apply(path: path, profile: profile)
    }
}

/// Finite, flat discovery from the user-selected folder. No watchers or recursion.
public enum PresetCatalog {
    public static func paths(folderPath: String?) throws -> [String] {
        guard let folderPath, !folderPath.isEmpty else {
            throw SwitcherError.message("Choose a presets folder in Settings first.")
        }
        let expanded = (folderPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw SwitcherError.message("Presets folder must be an absolute path.") }
        let folder = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else {
            throw SwitcherError.message("The presets folder is missing or is not a directory.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        let paths = try files.filter { url in
            guard ["yaml", "yml"].contains(url.pathExtension.lowercased()) else { return false }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.map { $0.standardizedFileURL.path }.sorted()
        guard paths.count <= 64 else { throw SwitcherError.message("Presets folder contains more than 64 YAML files. Use a smaller listening folder.") }
        return paths
    }
}

/// The session wraps these methods in the lifecycle lease used by controller/CLI.
@MainActor public final class PresetController {
    public private(set) var snapshot = PresetSnapshot()
    public var onChange: ((PresetSnapshot) -> Void)?
    private let transport: PresetDSPTransport
    private var profile: Profile?
    private var folderPath: String?
    private var eligible = false
    private var generation = 0
    public init(transport: PresetDSPTransport) { self.transport = transport }
    public func activate(profile: Profile?, ready: Bool, folderPath: String?) {
        guard self.profile != profile || self.eligible != (ready && profile != nil) || self.folderPath != folderPath else { return }
        generation += 1; transport.cancel()
        self.profile = profile; self.folderPath = folderPath; eligible = ready && profile != nil
        snapshot = PresetSnapshot(profileID: profile?.id)
        publish()
    }
    public func cancel() {
        generation += 1; transport.cancel(); snapshot.ready = false; snapshot.busy = false; publish()
    }
    public func refreshForUser() async throws {
        try await perform { profile in
            try await self.transport.inspect(profile: profile, paths: PresetCatalog.paths(folderPath: self.folderPath))
        }
    }
    public func selectForUser(path: String) async throws {
        let expectedImpact = try selectionImpact(path: path)
        try await perform { profile in
            let paths = try PresetCatalog.paths(folderPath: self.folderPath)
            guard paths.contains(path) else { throw SwitcherError.message("Preset is no longer present in the selected folder. Refresh presets.") }
            // Availability shown earlier is advisory. The transport validates again
            // against actual devices, pipeline and faders immediately before writing.
            let state = try await self.transport.apply(path: path, profile: profile, expectedImpact: expectedImpact)
            return state
        }
    }
    public func selectionImpact(path: String) throws -> PresetImpact {
        guard snapshot.ready, !snapshot.busy, let entry = snapshot.entries.first(where: { $0.path == path }) else {
            throw SwitcherError.message("Refresh presets before selecting a configuration.")
        }
        guard entry.available else { throw SwitcherError.message(entry.reason ?? "This preset is unavailable.") }
        return entry.impact
    }
    private func perform(_ operation: (Profile) async throws -> PresetDSPState) async throws {
        guard let profile, eligible, !snapshot.busy else {
            throw SwitcherError.message(snapshot.busy ? "Wait for the current preset command." : "Presets require a ready DSP profile.")
        }
        let token = generation
        snapshot.busy = true; snapshot.error = nil; publish()
        defer { if generation == token { snapshot.busy = false; publish() } }
        do {
            let state = try await operation(profile)
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            snapshot.entries = state.entries; snapshot.activePath = state.activePath
            snapshot.activeTitle = state.activeTitle; snapshot.ready = true
        } catch {
            if generation == token {
                if let failure = error as? PresetFailure, case .restored(_, let state) = failure {
                    snapshot.ready = true; snapshot.activePath = state.activePath; snapshot.activeTitle = state.activeTitle
                    snapshot.entries = state.entries
                } else {
                    snapshot.ready = false; snapshot.activePath = nil; snapshot.activeTitle = nil
                }
                snapshot.error = error is CancellationError ? "Preset command canceled because DSP authority changed." : error.localizedDescription
            }
            throw error
        }
    }
    private func publish() { onChange?(snapshot) }
}
