// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AutoAudioPlatform

@MainActor func runApplicationLaunchPathsChecks() async throws {
    try runApplicationSupportPathsChecks()
    let home = URL(fileURLWithPath: "/Users/launch-path-fixture")
    let directory = home.appendingPathComponent("Library/LaunchAgents")
    let defaultDirectory = home.appendingPathComponent("Library/Application Support/CamillaCompanion")
    let bundle = URL(fileURLWithPath: "/Applications/Fixture Companion.app")
    let executable = bundle.appendingPathComponent("Contents/MacOS/camillacompanion")
    let current = "org.camillacompanion.login"
    let customConfiguration = "/Users/launch-path-fixture/Studio/configuration.json"
    let customState = "/Users/launch-path-fixture/Studio/runtime.json"
    var reads: [String] = []
    var scans = 0
    var inspections: [String] = []
    let missing = ProcessResult(status: 113, stdout: "", stderr: "Could not find service")

    func propertyList(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
    func job(_ label: String = "org.camillacompanion.login", origin: URL? = nil) -> [String: Any] {
        ["Label": label,
         "ProgramArguments": [(origin ?? executable).path, "run", "--config", customConfiguration,
                              "--state", customState, "--menu-bar", "true"],
         "RunAtLoad": true, "ProcessType": "Interactive", "Disabled": true,
         "EnvironmentVariables": ["UNCHANGED": "fixture"]]
    }
    @MainActor func resolver(_ files: [String: Data], unreadable: Set<String> = [],
                  bundleURL: URL? = nil, bundleExecutableURL: URL? = nil,
                  loaded: [String: ProcessResult] = [:]) -> ApplicationLaunchPathResolver {
        ApplicationLaunchPathResolver(homeDirectory: home, bundleURL: bundleURL ?? bundle, bundleExecutableURL: bundleExecutableURL ?? executable,
            listFiles: { inspectedDirectory in
                scans += 1
                try check(inspectedDirectory == directory, "Discovery is confined to the injected per-user LaunchAgents directory")
                return Array(Set(files.keys).union(unreadable)).map { directory.appendingPathComponent($0) }
            }, readFile: { url in
                reads.append(url.lastPathComponent)
                if unreadable.contains(url.lastPathComponent) { throw CheckFailure.failed("Injected unreadable fixture") }
                return files[url.lastPathComponent]
            }, inspectLoadedJob: { label in
                inspections.append(label)
                return loaded[label] ?? missing
            })
    }
    @MainActor func rejects(_ files: [String: Data], _ message: String) async throws {
        do {
            _ = try await resolver(files).resolve()
            throw CheckFailure.failed(message)
        } catch is CheckFailure { throw CheckFailure.failed(message) }
        catch {
            try check(error.localizedDescription.contains("login configuration"), "A rejected job explains its startup conflict")
        }
    }

    let defaults = try await resolver([:]).resolve()
    try check(defaults.configurationURL == defaultDirectory.appendingPathComponent("config.json") &&
              defaults.runtimeStateURL == defaultDirectory.appendingPathComponent("runtime-state.json") &&
              defaults.adoptedLaunchAgentURL == nil, "A fresh native launch defaults to CamillaCompanion configuration and state paths")

    let currentBytes = try propertyList(job())
    let currentFiles = [current + ".plist": currentBytes]
    let adopted = try await resolver(currentFiles).resolve()
    try check(adopted.configurationURL.path == customConfiguration && adopted.runtimeStateURL.path == customState &&
              adopted.adoptedLaunchAgentURL == directory.appendingPathComponent(current + ".plist"),
              "A single validated current app job supplies both active custom paths even when login startup is disabled")
    var extraArguments = job()
    extraArguments["ProgramArguments"] = (extraArguments["ProgramArguments"] as! [String]) + ["--profile", "studio", "--mode", "force-on"]
    let extra = try await resolver([current + ".plist": propertyList(extraArguments)]).resolve()
    try check(extra.configurationURL == adopted.configurationURL && extra.runtimeStateURL == adopted.runtimeStateURL &&
              extra.sessionArguments == ["--profile", "studio", "--mode", "force-on"],
              "Valid optional profile and mode arguments retain the startup session policy")

    let startupArguments = job()["ProgramArguments"] as! [String]
    let startupPath = directory.appendingPathComponent(current + ".plist").path
    func loadedJob(path: String? = nil, program: String? = nil,
                   arguments: [String]? = nil) -> ProcessResult {
        ProcessResult(status: 0,
            stdout: "path = \(path ?? startupPath)\nprogram = \(program ?? executable.path)\narguments = {\n" + (arguments ?? startupArguments).joined(separator: "\n") + "\n}\npid = 42\n",
            stderr: "")
    }
    let inspectionsBeforeMatching = inspections.count
    let matchingLoaded = try await resolver(currentFiles, loaded: [current: loadedJob()]).resolve()
    try check(matchingLoaded == adopted && inspections.count == inspectionsBeforeMatching + 1 &&
              Array(inspections.suffix(1)) == [current],
              "A matching loaded job permits adoption after one finite inspection per known label")
    var changedState = startupArguments; changedState[5] = "/Different/runtime.json"
    for loadedValue in [loadedJob(path: "/Different/job.plist"), loadedJob(program: "/bin/sh"),
                        loadedJob(arguments: changedState), ProcessResult(status: 0, stdout: "malformed loaded output", stderr: ""),
                        ProcessResult(status: 1, stdout: "", stderr: "Permission denied")] {
        do {
            _ = try await resolver(currentFiles, loaded: [current: loadedValue]).resolve()
            throw CheckFailure.failed("A mismatched or uninspectable loaded job authorized adoption")
        } catch is CheckFailure { throw CheckFailure.failed("A mismatched or uninspectable loaded job authorized adoption") } catch { }
    }
    do {
        _ = try await resolver([:], loaded: [current: loadedJob()]).resolve()
        throw CheckFailure.failed("A loaded known job without its matching saved job fell back to defaults or another job")
    } catch is CheckFailure {
        throw CheckFailure.failed("A loaded known job without its matching saved job fell back to defaults or another job")
    } catch { }
    let failedInspection = ApplicationLaunchPathResolver(homeDirectory: home, listFiles: { _ in [] }, readFile: { _ in nil },
        inspectLoadedJob: { _ in throw CheckFailure.failed("Injected loaded-job inspection failure") })
    do {
        _ = try await failedInspection.resolve()
        throw CheckFailure.failed("A thrown loaded-job inspection error fell back to defaults")
    } catch is CheckFailure { throw CheckFailure.failed("A thrown loaded-job inspection error fell back to defaults") } catch { }

    let unrelated = try propertyList(["Label": "org.example.other", "ProgramArguments": [executable.path, "run", "--config", customConfiguration]])
    let ignored = try await resolver(["other.plist": unrelated, "broken.plist": Data("invalid plist".utf8)],
                               unreadable: ["protected.plist"]).resolve()
    try check(ignored == defaults, "Other labels and other applications' damaged or protected files confer no app ownership")

    try await rejects([current + ".plist": Data("invalid plist".utf8)], "Malformed reserved app file fell back to defaults")
    try await rejects([current + ".plist": propertyList(["not a dictionary"])], "Non-dictionary reserved app file fell back to defaults")
    var wrongLabel = job(); wrongLabel["Label"] = "org.example.other"
    try await rejects([current + ".plist": propertyList(wrongLabel)], "A reserved filename accepted an unrelated label")
    try await rejects(["renamed.plist": currentBytes], "A reserved label under an unrelated filename was adopted")
    for origin in [URL(fileURLWithPath: "/bin/sh"), URL(fileURLWithPath: "/tmp/camillacompanion"),
                   URL(fileURLWithPath: "/Applications/Other.app/Contents/MacOS/camillacompanion")] {
        try await rejects([current + ".plist": propertyList(job(origin: origin))], "An unrelated executable origin was adopted")
    }
    let development = URL(fileURLWithPath: "/tmp/development/camillacompanion")
    do {
        _ = try await resolver([current + ".plist": propertyList(job(current, origin: development))],
                         bundleURL: development.deletingLastPathComponent(), bundleExecutableURL: development).resolve()
        throw CheckFailure.failed("A development executable was trusted as an app bundle origin")
    } catch is CheckFailure { throw CheckFailure.failed("A development executable was trusted as an app bundle origin") } catch { }
    do {
        _ = try await resolver([current + ".plist": currentBytes], unreadable: [current + ".plist"]).resolve()
        throw CheckFailure.failed("Unreadable reserved job fell back to defaults")
    } catch is CheckFailure { throw CheckFailure.failed("Unreadable reserved job fell back to defaults") } catch { }
    let unreadableDirectory = ApplicationLaunchPathResolver(homeDirectory: home,
        listFiles: { _ in throw CheckFailure.failed("Injected unreadable LaunchAgents directory") }, readFile: { _ in
            throw CheckFailure.failed("A failed directory inspection unexpectedly read a file")
        }, inspectLoadedJob: { _ in
            throw CheckFailure.failed("A failed directory inspection unexpectedly inspected a loaded job")
        })
    do {
        _ = try await unreadableDirectory.resolve()
        throw CheckFailure.failed("A failed directory inspection fell back to defaults")
    } catch is CheckFailure { throw CheckFailure.failed("A failed directory inspection fell back to defaults") } catch { }

    var invalidArguments: [[String]] = []
    let validArguments = job()["ProgramArguments"] as! [String]
    for (index, value) in [(0, "relative/camillacompanion"), (1, "launch"), (3, "relative/config.json"),
                           (5, "~/runtime.json"), (7, "false")] {
        var arguments = validArguments; arguments[index] = value; invalidArguments.append(arguments)
    }
    invalidArguments += [Array(validArguments.dropLast()), validArguments + ["--config", customConfiguration],
                         validArguments + ["--unknown", "value"], validArguments + ["--mode", "invalid"],
                         validArguments + ["--mode", "force-on"]]
    for arguments in invalidArguments {
        var value = job(); value["ProgramArguments"] = arguments
        try await rejects([current + ".plist": propertyList(value)], "Invalid, relative or ambiguous startup arguments were adopted")
    }
    for (key, value) in [("Program", "/bin/sh" as Any), ("BundleProgram", "Contents/Helper" as Any),
                         ("RunAtLoad", false as Any), ("ProcessType", "Background" as Any)] {
        var propertyListValue = job(); propertyListValue[key] = value
        try await rejects([current + ".plist": propertyList(propertyListValue)], "An incompatible startup job was adopted")
    }

    let scansBeforeOverrides = scans
    let readsBeforeOverrides = reads.count
    let inspectionsBeforeOverrides = inspections.count
    let malformed = resolver([current + ".plist": Data("invalid".utf8)])
    let explicitConfiguration = try await malformed.resolve(arguments: ["--config", "/Explicit/config.json"])
    let explicitState = try await malformed.resolve(arguments: ["--state", "/Explicit/runtime.json"])
    let explicitBoth = try await malformed.resolve(arguments: ["--config", "/Explicit/config.json", "--state", "/Explicit/runtime.json"])
    let setup = try await malformed.resolve(setupOnly: true)
    try check(explicitConfiguration.configurationURL.path == "/Explicit/config.json" &&
              explicitConfiguration.runtimeStateURL == defaults.runtimeStateURL &&
              explicitState.configurationURL == defaults.configurationURL && explicitState.runtimeStateURL.path == "/Explicit/runtime.json" &&
              explicitBoth.configurationURL.path == "/Explicit/config.json" && explicitBoth.runtimeStateURL.path == "/Explicit/runtime.json" &&
              setup == defaults, "Explicit path overrides and Setup preserve their existing default-path contract")
    try check(scans == scansBeforeOverrides && reads.count == readsBeforeOverrides && inspections.count == inspectionsBeforeOverrides,
              "Explicit path overrides and Setup never inspect saved or loaded login jobs")
    do {
        _ = try await malformed.resolve(arguments: ["--state", "/one", "--state", "/two"])
        throw CheckFailure.failed("Duplicate explicit options were accepted")
    } catch is CheckFailure { throw CheckFailure.failed("Duplicate explicit options were accepted") } catch { }
    try check(currentFiles[current + ".plist"] == currentBytes,
              "Path discovery leaves all injected launch configuration bytes unchanged")
}
