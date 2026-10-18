import Foundation
import AutoAudioCore

@MainActor public final class JSONRouteStore: RouteStoring {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> RouteRecord? {
        do {
            return try JSONDecoder().decode(RouteRecord.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func save(_ record: RouteRecord?) throws {
        guard let record else {
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory != true else {
                    throw SwitcherError.message("Route state path is a directory; refusing to remove it.")
                }
                try FileManager.default.removeItem(at: url)
            }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
