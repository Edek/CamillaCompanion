import Foundation

public enum FallbackOutputMode: String, Codable, Sendable { case automatic, manual, off }
public enum FallbackOutputSelection: String, Codable, Sendable { case automatic, device }

/// A saved device identity, never a mutable CoreAudio device number.
public struct FallbackOutputPreference: Codable, Equatable, Sendable {
    public var mode: FallbackOutputMode
    public var outputSelection: FallbackOutputSelection
    public var outputUID: String?
    public var outputName: String?
    public init(mode: FallbackOutputMode = .automatic, outputUID: String? = nil, outputName: String? = nil) {
        self.mode = mode
        outputSelection = mode != .automatic && outputUID != nil ? .device : .automatic
        self.outputUID = outputUID; self.outputName = outputName
    }
    public init(mode: FallbackOutputMode, outputSelection: FallbackOutputSelection,
                outputUID: String? = nil, outputName: String? = nil) {
        self.mode = mode; self.outputSelection = outputSelection
        self.outputUID = outputUID; self.outputName = outputName
    }
    private enum CodingKeys: String, CodingKey {
        case mode, outputSelection, outputUID, outputName
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacyMode = try values.decodeIfPresent(FallbackOutputMode.self, forKey: .mode) ?? .automatic
        let uid = try values.decodeIfPresent(String.self, forKey: .outputUID)
        let name = try values.decodeIfPresent(String.self, forKey: .outputName)
        self.init(mode: legacyMode, outputUID: uid, outputName: name)
        if let selection = try values.decodeIfPresent(FallbackOutputSelection.self, forKey: .outputSelection) {
            outputSelection = selection
        }
        _ = try validated()
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // Mode and selected output are independent, including Auto with a saved
        // explicit Bypassed output. Old readers retain the existing v1 mode key.
        try values.encode(mode, forKey: .mode)
        try values.encode(outputSelection, forKey: .outputSelection)
        try values.encodeIfPresent(outputUID, forKey: .outputUID)
        try values.encodeIfPresent(outputName, forKey: .outputName)
    }
    public func validated() throws -> Self {
        if let outputUID {
            guard !outputUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !outputUID.contains("\0") else {
                throw SwitcherError.message("Fallback output requires a valid device UID.")
            }
        }
        if let outputName, outputName.contains("\0") {
            throw SwitcherError.message("Fallback output name is invalid.")
        }
        return self
    }
}

public struct FallbackOutputPreferences: Codable, Equatable, Sendable {
    public var version: Int
    public var profiles: [String: FallbackOutputPreference]
    public init(profiles: [String: FallbackOutputPreference] = [:]) {
        version = 1; self.profiles = profiles
    }
    public func preference(profileID: String) -> FallbackOutputPreference { profiles[profileID] ?? .init() }
    public func validated() throws -> Self {
        guard version == 1 else { throw SwitcherError.message("Unsupported fallback preferences version.") }
        for (id, preference) in profiles {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SwitcherError.message("Fallback settings require a profile ID.")
            }
            _ = try preference.validated()
        }
        return self
    }
    private enum CodingKeys: String, CodingKey { case version, profiles }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try values.decodeIfPresent([String: FallbackOutputPreference].self, forKey: .profiles) ?? [:]
        _ = try validated()
    }
}
