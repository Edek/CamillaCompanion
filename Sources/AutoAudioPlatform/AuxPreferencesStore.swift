import Foundation
import AutoAudioCore

/// Separate from route ownership and DSP configuration; nil means first use, [] means hidden.
@MainActor public final class JSONAuxPreferencesStore: AuxPreferencesStoring {
    private let url: URL
    private struct Document: Codable {
        var version: Int = 1
        var profiles: [String: AuxPreferences] = [:]
    }
    public init(url: URL) { self.url = url }
    public convenience init(runtimeStateURL: URL) {
        self.init(url: runtimeStateURL.appendingPathExtension("aux-preferences.json"))
    }
    private func read() throws -> Document {
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw SwitcherError.message("Unsupported Aux preferences version") }
            return document
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Document()
        }
    }
    public func load(profileID: String) throws -> AuxPreferences? {
        try read().profiles[profileID]?.validated()
    }
    public func save(_ preferences: AuxPreferences, profileID: String) throws {
        guard !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SwitcherError.message("Aux preferences require a profile ID")
        }
        let validated = try preferences.validated()
        // Read before writing so a corrupt or inaccessible existing document is preserved.
        var document = try read()
        document.profiles[profileID] = validated
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
