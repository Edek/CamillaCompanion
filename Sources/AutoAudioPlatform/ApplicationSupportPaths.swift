// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct ApplicationDefaultPaths: Sendable, Equatable {
    public let supportDirectoryURL: URL
    public var configurationURL: URL { supportDirectoryURL.appendingPathComponent("config.json") }
    public var runtimeStateURL: URL { supportDirectoryURL.appendingPathComponent("runtime-state.json") }
}

/// Shared defaults without filesystem reads or automatic data migration.
public enum ApplicationSupportPaths {
    public static let currentDirectoryName = "CamillaCompanion"

    public static func select(homeDirectory: URL) -> ApplicationDefaultPaths {
        ApplicationDefaultPaths(supportDirectoryURL: homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(currentDirectoryName, isDirectory: true))
    }
}
