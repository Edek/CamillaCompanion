import Foundation
import Darwin
import AutoAudioCore

/// Copies one preset without rewriting DSP content or changing the running profile.
package enum PresetFileDuplication {
    package static func copy(source: URL, to destination: URL) throws -> URL {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        let directory = source.deletingLastPathComponent().resolvingSymlinksInPath()
        guard source.isFileURL, destination.isFileURL,
              ["yaml", "yml"].contains(source.pathExtension.lowercased()),
              ["yaml", "yml"].contains(destination.pathExtension.lowercased()),
              directory == destination.deletingLastPathComponent().resolvingSymlinksInPath() else {
            throw SwitcherError.message("Save the copy beside the original YAML preset so relative coefficient-file references keep working.")
        }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size <= 2_000_000 else {
            throw SwitcherError.message("Choose a regular YAML preset smaller than 2 MB to duplicate.")
        }
        let bytes = try Data(contentsOf: source)
        guard bytes.count <= 2_000_000 else {
            throw SwitcherError.message("The preset is too large to duplicate.")
        }
        let temporary = directory.appendingPathComponent(".preset-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard try Data(contentsOf: source) == bytes else {
            throw SwitcherError.message("The source preset changed. Choose it again before duplicating.")
        }
        guard link(temporary.path, destination.path) == 0 else {
            throw SwitcherError.message("Could not save the preset copy. Choose a new filename in the original folder; existing files are kept.")
        }
        return destination
    }
}
