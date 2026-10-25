import Foundation
import AutoAudioCore
import Yams

public enum DeviceMappingResolution: Equatable, Sendable {
    case matched(uid: String)
    case missing
    case ambiguous(candidates: [String])
    case unsupported(reason: String)
}

public struct DeviceMappingSuggestion: Equatable, Sendable {
    public let selector: String?
    public let channels: Int?
    public let resolution: DeviceMappingResolution
    public var suggestedUID: String? {
        if case .matched(let uid) = resolution { return uid }
        return nil
    }
    public var candidateUID: String? { suggestedUID }

    public init(selector: String?, channels: Int?, resolution: DeviceMappingResolution) {
        self.selector = selector; self.channels = channels; self.resolution = resolution
    }
}

public struct ProfileDeviceMappingSuggestions: Equatable, Sendable {
    public let capture: DeviceMappingSuggestion
    public let playback: DeviceMappingSuggestion
    public let managedFeed: DeviceMappingSuggestion
    public init(capture: DeviceMappingSuggestion, playback: DeviceMappingSuggestion, managedFeed: DeviceMappingSuggestion) {
        self.capture = capture; self.playback = playback; self.managedFeed = managedFeed
    }
}

/// Read-only, finite interpretation of the selected YAML's existing CoreAudio mappings.
public enum ProfileDeviceMapping {
    private struct SelectorDetails {
        let type: String?
        let device: String?
        let channels: Int?
    }

    public static func suggestions(configurationPath: String, devices: [AudioDevice]) throws -> ProfileDeviceMappingSuggestions {
        guard configurationPath.hasPrefix("/"),
              (try URL(fileURLWithPath: configurationPath).resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw SwitcherError.message("Choose an existing CamillaDSP YAML configuration.")
        }
        let url = URL(fileURLWithPath: configurationPath)
        let bytes = try Data(contentsOf: url)
        guard let yaml = String(data: bytes, encoding: .utf8),
              let root = try Yams.load(yaml: yaml) as? [String: Any],
              let config = root["devices"] as? [String: Any] else {
            throw SwitcherError.message("Choose a CamillaDSP YAML configuration with a devices section.")
        }
        let capture = details(config["capture"])
        let playback = details(config["playback"])
        guard try Data(contentsOf: url) == bytes else {
            throw SwitcherError.message("The DSP configuration changed while its device mappings were being read. Review it again.")
        }
        return ProfileDeviceMappingSuggestions(
            capture: resolve(capture, devices: devices, input: true, role: "capture"),
            playback: resolve(playback, devices: devices, input: false, role: "playback"),
            managedFeed: resolve(capture, devices: devices, input: false, role: "managed system feed"))
    }

    /// Compares the current editor choices with the inspected YAML, without rereading or writing it.
    public static func review(_ draft: InterfaceProfileDraft, suggestions: ProfileDeviceMappingSuggestions,
                              devices: [AudioDevice]) -> [String] {
        [("DSP input", draft.captureUID, suggestions.capture),
         ("DSP output", draft.playbackUID, suggestions.playback)].compactMap { label, uid, suggestion in
            guard !uid.isEmpty else { return "Choose a \(label.lowercased()) matching the YAML." }
            if case .unsupported(let reason) = suggestion.resolution { return reason }
            if case .ambiguous = suggestion.resolution { return "The YAML \(label.lowercased()) selector is ambiguous. Use an explicit UID in the YAML." }
            guard let device = devices.first(where: { $0.uid == uid }) else { return nil }
            guard suggestion.selector == uid || suggestion.selector == device.name else {
                return "\(label) differs from the YAML selector: \(suggestion.selector ?? "not specified")."
            }
            if let channels = suggestion.channels {
                let available = label == "DSP input" ? device.inputChannels : device.outputChannels
                if available < channels { return "\(label) does not provide the \(channels) channels required by the YAML." }
            }
            return nil
        }
    }

    /// Picks the active saved profile's installed DSP executable first, then other saved profiles in order.
    /// The stored YAML path is returned alongside it for callers that need it, but YAML validity does not
    /// disqualify an installed executable. This never reads an unsaved draft or invokes setup discovery.
    public static func savedDSPPaths(profiles: [InterfaceProfileDraft], activeProfileID: String?) -> (executablePath: String, configurationPath: String)? {
        let ordered = profiles.first(where: { $0.id == activeProfileID }).map { active in
            [active] + profiles.filter { $0.id != active.id }
        } ?? profiles
        for profile in ordered where isValidExecutable(profile.executablePath) {
            return (profile.executablePath, profile.configurationPath)
        }
        return nil
    }

    public static func isValidExecutable(_ executablePath: String) -> Bool {
        guard executablePath.hasPrefix("/"), URL(fileURLWithPath: executablePath).lastPathComponent == "camilladsp",
              FileManager.default.isExecutableFile(atPath: executablePath) else { return false }
        return true
    }

    private static func details(_ value: Any?) -> SelectorDetails {
        guard let value = value as? [String: Any] else { return SelectorDetails(type: nil, device: nil, channels: nil) }
        let channels = value["channels"] as? Int
        return SelectorDetails(type: value["type"] as? String, device: value["device"] as? String, channels: channels)
    }

    private static func resolve(_ details: SelectorDetails, devices: [AudioDevice], input: Bool, role: String) -> DeviceMappingSuggestion {
        guard details.type == "CoreAudio" else {
            return DeviceMappingSuggestion(selector: details.device, channels: details.channels,
                resolution: .unsupported(reason: "The YAML uses a non-CoreAudio \(role) source, which is outside the device browser."))
        }
        if let channels = details.channels, channels <= 0 {
            return DeviceMappingSuggestion(selector: details.device, channels: channels,
                resolution: .unsupported(reason: "The YAML \(role) channel count must be positive."))
        }
        guard let selector = details.device, !selector.isEmpty, !selector.contains("\0") else {
            return DeviceMappingSuggestion(selector: details.device, channels: details.channels, resolution: .missing)
        }
        let uidMatches = devices.filter { $0.uid == selector }
        if uidMatches.count > 1 {
            return DeviceMappingSuggestion(selector: selector, channels: details.channels,
                resolution: .ambiguous(candidates: uidMatches.map(\.uid).sorted()))
        }
        if let exact = uidMatches.first {
            guard capable(exact, input: input, channels: details.channels) else {
                return DeviceMappingSuggestion(selector: selector, channels: details.channels,
                    resolution: .unsupported(reason: "The selected \(role) device does not provide the required channels."))
            }
            return DeviceMappingSuggestion(selector: selector, channels: details.channels, resolution: .matched(uid: exact.uid))
        }
        let named = devices.filter { $0.name == selector }
        if named.count > 1 {
            return DeviceMappingSuggestion(selector: selector, channels: details.channels,
                resolution: .ambiguous(candidates: named.map(\.uid).sorted()))
        }
        let candidates = named.filter {
            $0.name == selector && capable($0, input: input, channels: details.channels)
        }.map(\.uid).sorted()
        switch candidates.count {
        case 0:
            let resolution: DeviceMappingResolution = named.isEmpty ? .missing :
                .unsupported(reason: "The named \(role) device does not provide the required channels.")
            return DeviceMappingSuggestion(selector: selector, channels: details.channels, resolution: resolution)
        case 1: return DeviceMappingSuggestion(selector: selector, channels: details.channels, resolution: .matched(uid: candidates[0]))
        default: return DeviceMappingSuggestion(selector: selector, channels: details.channels, resolution: .ambiguous(candidates: candidates))
        }
    }

    private static func capable(_ device: AudioDevice, input: Bool, channels: Int?) -> Bool {
        let available = input ? device.inputChannels : device.outputChannels
        return available > 0 && channels.map { available >= $0 } ?? true
    }
}
