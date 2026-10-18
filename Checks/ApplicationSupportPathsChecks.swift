// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AutoAudioPlatform

func runApplicationSupportPathsChecks() throws {
    let home = URL(fileURLWithPath: "/Users/support-path-fixture")
    let expected = home.appendingPathComponent("Library/Application Support/CamillaCompanion", isDirectory: true)
    let defaults = ApplicationSupportPaths.select(homeDirectory: home)
    try check(defaults.supportDirectoryURL == expected &&
              defaults.configurationURL == expected.appendingPathComponent("config.json") &&
              defaults.runtimeStateURL == expected.appendingPathComponent("runtime-state.json"),
              "Default configuration and runtime state use the CamillaCompanion support directory")
    try check(ApplicationSupportPaths.select(homeDirectory: home) == defaults,
              "Default paths are deterministic without filesystem discovery")
}
