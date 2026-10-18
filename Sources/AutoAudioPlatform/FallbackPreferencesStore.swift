import Foundation
import AutoAudioCore

/// On-demand atomic routing preference persistence. Unreadable files are preserved.
@MainActor public final class JSONFallbackPreferencesStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public convenience init(runtimeStateURL: URL) {
        self.init(url: runtimeStateURL.appendingPathExtension("fallback-preferences.json"))
    }
    public func load() throws -> FallbackOutputPreferences {
        do { return try JSONDecoder().decode(FallbackOutputPreferences.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init() }
    }
    public func save(_ preferences: FallbackOutputPreferences) throws {
        _ = try preferences.validated()
        _ = try load()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
