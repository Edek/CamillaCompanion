// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runSetupDiscoveryChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("setup-discovery-" + UUID().uuidString)
    let home = root.appendingPathComponent("home")
    let prefix = root.appendingPathComponent("homebrew")
    let support = home.appendingPathComponent("Library/Application Support")
    let agents = home.appendingPathComponent("Library/LaunchAgents")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func write(_ text: String, _ file: URL, executable: Bool = false) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: file.path)
    }
    func binary(_ file: URL) throws {
        try write("#!/bin/sh\necho DISCOVERY_MUST_NOT_EXECUTE >&2\nexit 99\n", file, executable: true)
    }
    func plist(_ name: String, _ dictionary: [String: Any], directory: URL? = nil) throws -> URL {
        let file = (directory ?? agents).appendingPathComponent(name + ".plist")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: file)
        return file
    }
    func search(_ limits: SetupDiscoveryLimits = .init()) -> SetupDiscoveryResult {
        SetupDiscovery.find(homeDirectory: home, installationRoots: [prefix], limits: limits)
    }
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let file as URL in enumerator {
            let type = try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            if type == .typeRegular { result[file.path] = try Data(contentsOf: file) }
            else if type == .typeSymbolicLink { result[file.path] = Data(try fm.destinationOfSymbolicLink(atPath: file.path).utf8) }
        }
        return result
    }
    let empty = search()
    try check(empty.dsp.isEmpty && empty.gui.isEmpty && !empty.searchTruncated,
              "An empty isolated home returns no invented installations")

    let legacy = support.appendingPathComponent("Bedroom EQ")
    let dspBinary = legacy.appendingPathComponent("camilladsp")
    let yaml = root.appendingPathComponent("explicit-configs/current.yml")
    let state = root.appendingPathComponent("explicit-state/state.yml")
    try binary(dspBinary)
    let dspText = "devices:\n  capture:\n    type: CoreAudio\n    device: Fixture Virtual\n  playback:\n    type: CoreAudio\n    device: Fixture Physical\n"
    try write(dspText, yaml)
    try write("config_path: '\(yaml.path)'\n", state)
    let legacyJob: [String: Any] = ["Label": "com.fixture.legacy-dsp", "ProgramArguments":
        [dspBinary.path, "-s", state.path, "-a", "127.0.0.1", "-p", "3210", "-o", root.appendingPathComponent("fixture.log").path,
         "--log_rotate_size", "2000000", "--log_keep_nbr", "3"], "RunAtLoad": true, "KeepAlive": true]
    _ = try plist("legacy-dsp", legacyJob)
    let backend = legacy.appendingPathComponent("camillagui/camillagui_backend/camillagui_backend")
    let guiConfig = backend.deletingLastPathComponent().appendingPathComponent("_internal/config/camillagui.yml")
    try binary(backend)
    try write("{\"bind_address\":\"127.0.0.1\",\"port\":8181,\"camilla_host\":\"127.0.0.1\",\"camilla_port\":3210}", guiConfig)
    let before = try snapshot()
    let discovered = search()
    try check(discovered.dsp.contains(where: { $0.executablePath == dspBinary.path && $0.configurationPath == yaml.path &&
        $0.websocketPort == 3210 && $0.launchAgentPath == nil }),
        "Legacy logging arguments resolve an explicit state outside the scanned tree without importing a self-starting job")
    try check(discovered.gui.contains(where: { $0.executablePath == backend.path && $0.configurationPath == guiConfig.path &&
        $0.url == "http://127.0.0.1:8181" }), "Depth-four legacy GUI backend pairs with its deeper internal configuration")
    let after = try snapshot()
    try check(after == before, "Discovery leaves all installation, state, configuration and job bytes unchanged")
    try check(search() == discovered, "Repeated bounded discovery returns deterministic candidate ordering")

    let directJob = try plist("on-demand", ["Label": "com.fixture.on-demand", "ProgramArguments":
        [dspBinary.path, "-a", "localhost", "-p", "4321", yaml.path], "RunAtLoad": false, "KeepAlive": false])
    let imported = search()
    try check(imported.dsp.contains(where: { $0.launchAgentPath == directJob.path && $0.configurationPath == yaml.path && $0.websocketPort == 4321 }),
              "A direct on-demand loopback job provides one complete import candidate including its nondefault port")

    let standard = prefix.appendingPathComponent("bin/camilladsp")
    try fm.createDirectory(at: standard.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: standard, withDestinationURL: dspBinary)
    let standardGUI = prefix.appendingPathComponent("bin/camillagui.py")
    try binary(standardGUI)
    let another = support.appendingPathComponent("CamillaDSP/other/camilladsp")
    try binary(another)
    let anotherConfig = another.deletingLastPathComponent().appendingPathComponent("second.yaml")
    try write(dspText, anotherConfig)
    let multiple = search()
    let canonicalDSP = Set(multiple.dsp.map { URL(fileURLWithPath: $0.executablePath).resolvingSymlinksInPath().path })
    try check(canonicalDSP == [dspBinary.path, another.path] &&
              multiple.dsp.contains(where: { $0.configurationPath == anotherConfig.path }),
              "Multiple real DSP installations remain explicit choices while Homebrew executable symlinks deduplicate")
    try check(multiple.gui.contains(where: { $0.executablePath == standardGUI.path && $0.configurationPath == nil }),
              "A standard executable Python GUI entry can be found without guessing its configuration")

    let unsafeGUI = legacy.appendingPathComponent("camillagui_backend")
    try binary(unsafeGUI)
    let unsafeConfig = unsafeGUI.deletingLastPathComponent().appendingPathComponent("camillagui.yaml")
    try write("bind_address: 0.0.0.0\nport: 8888\ncamilla_host: 127.0.0.1\n", unsafeConfig)
    try check(search().gui.contains(where: { $0.executablePath == unsafeGUI.path && $0.configurationPath == unsafeConfig.path && $0.url == nil }),
              "Wildcard bind configuration never invents a loopback GUI URL")

    let badState = root.appendingPathComponent("explicit-state/broken.yml")
    try write("config_path: [unclosed", badState)
    let badExecutable = root.appendingPathComponent("malformed/camilladsp")
    try binary(badExecutable)
    _ = try plist("broken-state", ["Label": "com.fixture.broken", "ProgramArguments": [badExecutable.path, "-s", badState.path, "-p", "3210"]])
    _ = try plist("wrapper", ["Label": "com.fixture.wrapper", "ProgramArguments": ["/bin/sh", dspBinary.path, yaml.path]])
    try write("not a property list", agents.appendingPathComponent("broken.plist"))
    let malformed = search()
    try check(malformed.dsp.contains(where: { $0.executablePath == badExecutable.path && $0.configurationPath == nil && $0.launchAgentPath == nil }),
              "Malformed state remains an executable-only candidate rather than a guessed YAML/import")
    try check(!malformed.dsp.contains(where: { $0.executablePath == "/bin/sh" || $0.configurationPath == badState.path }),
              "Shell wrappers and malformed state files are never presented as DSP configurations")

    let outside = root.appendingPathComponent("outside-tree")
    try binary(outside.appendingPathComponent("camilladsp"))
    let link = support.appendingPathComponent("symlink-directory")
    try fm.createSymbolicLink(at: link, withDestinationURL: outside)
    let backup = support.appendingPathComponent("Backups/old/camilladsp")
    try binary(backup)
    let vendor = support.appendingPathComponent("vendor/package/camilladsp")
    try binary(vendor)
    let ignored = search()
    try check(!ignored.dsp.contains(where: { $0.executablePath == backup.path || $0.executablePath == vendor.path || $0.executablePath.hasPrefix(link.path + "/") }),
              "Backup, dependency and symlink directories are not scanned as installations")

    let appConfig = support.appendingPathComponent("CamillaCompanion/config.json")
    let referencedBackend = root.appendingPathComponent("explicit-gui/camillagui_backend")
    let referencedGUIConfig = root.appendingPathComponent("explicit-gui/settings.yml")
    try binary(referencedBackend)
    try write("bind_address: localhost\nport: 9191\ncamilla_host: 127.0.0.1\ncamilla_port: 4321\n", referencedGUIConfig)
    let profile = Profile(id: "fixture", name: "Fixture", triggerUID: "physical", captureUID: "virtual", playbackUID: "physical",
        launchAgentLabel: "com.fixture.on-demand", launchAgentPath: directJob.path, websocketURL: "ws://127.0.0.1:4321",
        expectedCaptureDevice: "Fixture Virtual", expectedPlaybackDevice: "Fixture Physical",
        gui: .init(executablePath: referencedBackend.path, configPath: referencedGUIConfig.path, url: "http://localhost:9191"))
    try fm.createDirectory(at: appConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(Configuration(profiles: [profile])).write(to: appConfig)
    try check(search().gui.contains(where: { $0.executablePath == referencedBackend.path && $0.configurationPath == referencedGUIConfig.path && $0.url == "http://localhost:9191" }),
              "A structurally valid existing app configuration seeds explicit GUI references outside the shallow search")

    try check(search(.init(maxEntries: 5)).searchTruncated, "Directory-entry budget exhaustion is reported")
    let limited = search(.init(maxConfigReads: 1, maxConfigBytes: 16))
    try check(limited.searchTruncated, "Read-count and configuration-byte limits are reported without unbounded reads")
    let finalBefore = try snapshot()
    _ = search()
    let finalAfter = try snapshot()
    try check(finalAfter == finalBefore, "Discovery creates no registry, backups, configuration, services or executable side effects")
}
