import Foundation
import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class MemoryLoginBackend: LoginItemBackend {
    var data: [String: Data] = [:]
    var loaded: [String: String] = [:]
    var overrides: [String: Bool] = [:]
    var commands: [[String]] = []
    var backups: [Data] = []
    var failMutation = false
    var failReadback = false
    var writeCount = 0
    var extraFiles: [URL] = []
    var unreadable = Set<String>()
    func files(in directory: URL) throws -> [URL] {
        data.keys.filter { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path }
            .map { URL(fileURLWithPath: $0) } + extraFiles
    }
    func read(_ url: URL) throws -> Data? {
        if unreadable.contains(url.path) { throw CheckFailure.failed("Fixture file is unreadable") }
        return data[url.path]
    }
    func executableExists(_ url: URL) -> Bool { url.path == "/Applications/camillacompanion" }
    func writeAtomically(_ value: Data, to url: URL) throws { data[url.path] = value; writeCount += 1 }
    func remove(_ url: URL) throws { data.removeValue(forKey: url.path) }
    func backup(_ value: Data, name: String, directory: URL) throws { backups.append(value) }
    func launchctl(_ arguments: [String]) async throws -> ProcessResult {
        commands.append(arguments)
        switch arguments[0] {
        case "print":
            if let output = loaded[arguments[1]] { return ProcessResult(status: 0, stdout: output, stderr: "") }
            return ProcessResult(status: 113, stdout: "", stderr: "Could not find service")
        case "print-disabled":
            if failReadback && writeCount > 0 { return ProcessResult(status: 1, stdout: "", stderr: "readback failure") }
            return ProcessResult(status: 0, stdout: "disabled services = {\n" + overrides.sorted(by: { $0.key < $1.key }).map { "\"\($0.key)\" => \($0.value ? "disabled" : "enabled")" }.joined(separator: "\n") + "\n}", stderr: "")
        case "enable", "disable":
            if failMutation { failMutation = false; return ProcessResult(status: 1, stdout: "", stderr: "mutation denied") }
            let label = String(arguments[1].split(separator: "/").last!)
            overrides[label] = arguments[0] == "disable"
            return ProcessResult(status: 0, stdout: "", stderr: "")
        default: throw CheckFailure.failed("Login manager attempted a live-session operation: \(arguments)")
        }
    }
}

@MainActor func runLoginItemChecks(includeNative: Bool = false) async throws {
    let directory = URL(fileURLWithPath: "/Users/test/Library/LaunchAgents")
    let executable = URL(fileURLWithPath: "/Applications/camillacompanion")
    let config = URL(fileURLWithPath: "/Users/test/App/config.json")
    let state = URL(fileURLWithPath: "/Users/test/App/runtime-state.json")
    let current = "org.camillacompanion.login"
    func backend() -> MemoryLoginBackend {
        let value = MemoryLoginBackend(); value.data[config.path] = Data("{}".utf8); return value
    }
    func manager(_ backend: MemoryLoginBackend) -> LoginItemManager {
        LoginItemManager(executableURL: executable, configURL: config, stateURL: state,
            launchAgentsDirectory: directory, domain: "gui/123", backend: backend)
    }
    func plist(_ label: String, extraArguments: [String] = []) -> [String: Any] {
        ["Label": label, "ProgramArguments": [executable.path, "run", "--config", config.path, "--state", state.path, "--menu-bar", "true"] + extraArguments,
         "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive",
         "EnvironmentVariables": ["KEEP_POLICY": "yes"], "ThrottleInterval": 30]
    }
    func save(_ plist: [String: Any], _ backend: MemoryLoginBackend) throws -> Data {
        let value = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        backend.data[directory.appendingPathComponent((plist["Label"] as! String) + ".plist").path] = value
        return value
    }
    func parsed(_ backend: MemoryLoginBackend, label: String) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: backend.data[directory.appendingPathComponent(label + ".plist").path]!, format: nil) as! [String: Any]
    }
    func refuses(_ manager: LoginItemManager, _ message: String) async throws {
        var rejected = false
        do { _ = try await manager.setEnabled(true) } catch { rejected = true }
        try check(rejected, message)
    }

    let clean = backend(); let first = manager(clean)
    let initial = await first.refresh()
    try check(initial.state == .disabled && initial.canChange && clean.writeCount == 0, "Clean install defaults Off without writes")
    _ = try await first.setEnabled(true)
    let new = try parsed(clean, label: current)
    try check(first.status.state == .enabled && clean.overrides[current] == false, "Enabling saves a future-login job and macOS override")
    try check(new["ProcessType"] as? String == "Interactive" && new["RunAtLoad"] as? Bool == true, "New job retains interactive login behavior")
    try check((new["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false, "New job keeps crash recovery while allowing clean exit")
    try check(new["StandardOutPath"] as? String == "/Users/test/App/camillacompanion.stdout.log" &&
              new["StandardErrorPath"] as? String == "/Users/test/App/camillacompanion.stderr.log",
              "New login logs use the current application name")
    _ = try await first.setEnabled(false)
    try check(first.status.state == .disabled && clean.overrides[current] == true, "Disable is reflected by launchd's persisted override")
    try check(clean.commands.allSatisfy { ["print", "print-disabled", "enable", "disable"].contains($0[0]) }, "Login toggles never load, stop or restart a process")

    let unrelatedDamage = backend()
    unrelatedDamage.data[directory.appendingPathComponent("other.broken.plist").path] = Data("broken".utf8)
    let protectedPath = directory.appendingPathComponent("other.protected.plist").path
    unrelatedDamage.data[protectedPath] = Data("private".utf8)
    unrelatedDamage.unreadable.insert(protectedPath)
    let damageManager = manager(unrelatedDamage)
    _ = await damageManager.refresh()
    try check(damageManager.status.state == .disabled && damageManager.status.canChange,
        "Unrelated malformed and unreadable login files do not block app startup settings")
    _ = try await damageManager.setEnabled(true)
    try check(damageManager.status.isEnabled,
        "App login startup can be enabled without changing unrelated damaged files")
    try check(unrelatedDamage.data[directory.appendingPathComponent("other.broken.plist").path] == Data("broken".utf8) &&
        unrelatedDamage.data[protectedPath] == Data("private".utf8), "Unrelated damaged login files remain untouched")
    let reservedDamage = backend()
    reservedDamage.data[directory.appendingPathComponent(current + ".plist").path] = Data("broken".utf8)
    try await refuses(manager(reservedDamage), "Malformed reserved login file still fails closed")
    let reservedUnreadable = backend(); _ = try save(plist(current), reservedUnreadable)
    reservedUnreadable.unreadable.insert(directory.appendingPathComponent(current + ".plist").path)
    try await refuses(manager(reservedUnreadable), "Unreadable reserved login file still fails closed")

    let saved = backend(); let original = try save(plist(current, extraArguments: ["--profile", "bedroom"]), saved)
    let existingChoice = manager(saved)
    _ = await existingChoice.refresh()
    try check(existingChoice.status.state == .enabled && saved.writeCount == 0, "Existing login choice is preserved on refresh")
    _ = try await existingChoice.setEnabled(false)
    let preserved = try parsed(saved, label: current)
    let baseline = try PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
    for key in baseline.keys {
        try check(NSDictionary(dictionary: [key: preserved[key]!]).isEqual(to: [key: baseline[key]!]), "Existing field retained: \(key)")
    }
    try check(saved.backups == [original], "Existing login configuration is backed up before a change")
    try check(saved.data.keys.filter { $0.hasSuffix(".plist") }.count == 1, "Updating startup keeps one startup authority")
    saved.overrides[current] = false
    _ = await existingChoice.refresh()
    try check(existingChoice.status.state == .enabled, "OS enabled override takes precedence over Disabled plist field")
    saved.overrides[current] = true
    _ = await existingChoice.refresh()
    try check(existingChoice.status.state == .disabled, "OS disabled override is reflected without auto-enabling")

    let denied = backend(); let deniedOriginal = try save(plist(current), denied)
    denied.failMutation = true
    do { _ = try await manager(denied).setEnabled(false); throw CheckFailure.failed("Mutation failure was swallowed") }
    catch is CheckFailure { throw CheckFailure.failed("Mutation failure was swallowed") }
    catch {}
    try check(denied.data[directory.appendingPathComponent(current + ".plist").path] == deniedOriginal, "Failed command restores original configuration bytes")
    try check(denied.overrides[current] == false, "Failed disable restores the effective previous launchd choice")

    let duplicate = backend(); let duplicateData = try save(plist(current), duplicate)
    duplicate.data[directory.appendingPathComponent("alias.plist").path] = duplicateData
    try await refuses(manager(duplicate), "Duplicate jobs must fail closed")
    try check(duplicate.writeCount == 0, "Duplicate detection has no file mutations")
    let unrelated = backend(); var wrong = plist(current); wrong["ProgramArguments"] = ["/bin/echo", "run"]
    _ = try save(wrong, unrelated)
    try await refuses(manager(unrelated), "Reserved label occupied by unrelated job must fail closed")
    let foreign = backend(); _ = try save(plist("custom.other.label"), foreign)
    try await refuses(manager(foreign), "Equivalent job under unrecognized label must not gain another startup authority")

    let missingFile = backend()
    missingFile.loaded["gui/123/" + current] = "program = \(executable.path)"
    try await refuses(manager(missingFile), "Loaded job without its saved plist cannot be replaced")
    let mismatch = backend(); _ = try save(plist(current), mismatch)
    mismatch.loaded["gui/123/" + current] = "path = /wrong.plist\nprogram = \(executable.path)"
    try await refuses(manager(mismatch), "Loaded job with mismatched ownership must fail closed")

    let matched = backend(); let matchingPlist = plist(current); _ = try save(matchingPlist, matched)
    let args = matchingPlist["ProgramArguments"] as! [String]
    matched.loaded["gui/123/" + current] = "path = \(directory.appendingPathComponent(current + ".plist").path)\nprogram = \(executable.path)\narguments = {\n" + args.joined(separator: "\n") + "\n}"
    let existing = manager(matched); _ = await existing.refresh()
    try check(existing.status.state == .enabled, "Matching loaded current job remains the sole startup authority")

    let readback = backend(); let readbackOriginal = try save(plist(current), readback)
    readback.failReadback = true
    do { _ = try await manager(readback).setEnabled(false); throw CheckFailure.failed("Readback failure was swallowed") }
    catch is CheckFailure { throw CheckFailure.failed("Readback failure was swallowed") }
    catch {}
    try check(readback.data[directory.appendingPathComponent(current + ".plist").path] == readbackOriginal, "Failed confirmation restores saved login job")
    if includeNative { try await checkNativeLoginSettings(backend: backend(), manager: manager) }
    print("Start at Login checks passed: future-login behavior, preserved current job, OS overrides, rollback and conflict refusal.")
}


@MainActor private func checkNativeLoginSettings(backend: MemoryLoginBackend,
    manager makeManager: (MemoryLoginBackend) -> LoginItemManager) async throws {
    _ = NSApplication.shared
    let login = makeManager(backend)
    var preferenceWrites = 0
    var setupActions = 0
    let settings = NativeSettingsWindow(preferences: UIPreferences(), loginItemManager: login,
        onSetup: { setupActions += 1 }, onChange: { _ in preferenceWrites += 1 })
    defer { settings.close() }
    settings.refreshStartupStatus()
    await settings.waitForStartupUpdate()
    try check(settings.startAtLoginButton.state == .off && settings.startAtLoginButton.isEnabled,
        "Native startup checkbox shows actual clean-install choice")
    settings.startAtLoginButton.performClick(nil)
    try check(!settings.startAtLoginButton.isEnabled, "Native startup checkbox is disabled during an update")
    await settings.waitForStartupUpdate()
    try check(settings.startAtLoginButton.state == .on && login.status.isEnabled,
        "Clicking Start at Login persists and renders the actual registration")
    try check(preferenceWrites == 0, "Login choice does not persist through unrelated UI preferences")
    let writesAfterEnable = backend.writeCount
    let commandsAfterEnable = backend.commands.count

    // Opening Settings refreshes a choice changed in macOS without registering it again.
    backend.overrides["org.camillacompanion.login"] = true
    settings.show(tab: .general)
    await settings.waitForStartupUpdate()
    try check(settings.startAtLoginButton.state == .off && settings.startAtLoginButton.isEnabled,
        "Showing Settings reflects an externally disabled login job")
    try check(backend.writeCount == writesAfterEnable &&
        backend.commands.dropFirst(commandsAfterEnable).allSatisfy { ["print", "print-disabled"].contains($0[0]) },
        "Settings show only reads registration and does not undo macOS's choice")

    backend.overrides["org.camillacompanion.login"] = false
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    await settings.waitForStartupUpdate()
    try check(settings.startAtLoginButton.state == .on,
        "App activation refreshes OS startup status while Settings is visible")
    let commandsAfterActivation = backend.commands.count
    settings.updatePreferences(UIPreferences())
    await Task.yield()
    try check(backend.commands.count == commandsAfterActivation && backend.writeCount == writesAfterEnable,
        "Ordinary preference and audio updates do not poll or mutate startup")

    backend.failMutation = true
    settings.startAtLoginButton.performClick(nil)
    await settings.waitForStartupUpdate()
    try check(settings.startAtLoginButton.state == .on && settings.startAtLoginButton.isEnabled,
        "Failed disable returns the checkbox to the verified enabled choice")
    try check(settings.startupMessage.stringValue.contains("mutation denied") &&
        settings.startupMessage.textColor == .systemRed,
        "Native startup update failure remains visible")
    try check(preferenceWrites == 0, "Failed startup changes do not alter UI preferences")

    settings.setupButton.performClick(nil)
    try check(setupActions == 1, "Setup button dispatches exactly one setup action")
    let commandsBeforeClose = backend.commands.count
    settings.close()
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    await Task.yield()
    try check(backend.commands.count == commandsBeforeClose, "Hidden Settings does not refresh startup on activation")
}
