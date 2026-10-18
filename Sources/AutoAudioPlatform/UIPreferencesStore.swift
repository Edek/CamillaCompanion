import Foundation
import AutoAudioCore

/// On-demand atomic sidecar persistence. Existing unreadable files are preserved.
@MainActor public final class JSONUIPreferencesStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public convenience init(runtimeStateURL: URL) {
        self.init(url: runtimeStateURL.appendingPathExtension("ui-preferences.json"))
    }

    public func load() throws -> UIPreferences {
        do {
            return try JSONDecoder().decode(UIPreferences.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return UIPreferences()
        }
    }

    public func save(_ preferences: UIPreferences) throws {
        // Validate before replacing so load errors cannot silently destroy user data.
        _ = try preferences.validated()
        _ = try load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
