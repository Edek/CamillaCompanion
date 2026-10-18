import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runPlatformChecks() async throws {
    var assertions = 0
    func expect(_ condition: Bool, _ message: String) throws {
        try check(condition, message)
        assertions += 1
    }
    func rejects(_ message: String, _ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try expect(rejected, message)
    }
    func profile() -> Profile {
        Profile(id: "home", name: "Home", triggerUID: "physical", captureUID: "virtual",
                playbackUID: "physical", launchAgentLabel: "test.home", launchAgentPath: "/tmp/home.plist",
                websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "Virtual",
                expectedPlaybackDevice: "Physical")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("camillacompanion-checks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let stateURL = root.appendingPathComponent("nested/route.json")
    let store = JSONRouteStore(url: stateURL)
    try expect(try store.load() == nil, "Missing route state should be absent")
    let record = RouteRecord(profileID: "home", captureUID: "virtual", previousOutputUID: "headphones",
                             previousAlertUID: "builtin", ownsOutput: true, ownsAlerts: false)
    try store.save(record)
    try expect(try store.load() == record, "Route state round trip should preserve separate outputs and ownership")
    let other = stateURL.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
    try Data("keep".utf8).write(to: other)
    try store.save(nil)
    try expect(try store.load() == nil, "Removed route state should be absent")
    try expect(try String(contentsOf: other, encoding: .utf8) == "keep", "State removal must preserve unrelated files")
    try store.save(nil)
    assertions += 1
    try Data("{broken".utf8).write(to: stateURL)
    try rejects("Corrupt route state must fail explicitly") { _ = try store.load() }
    try rejects("Route-state removal must refuse directories") { try JSONRouteStore(url: root).save(nil) }
    try expect(FileManager.default.fileExists(atPath: other.path), "Directory protection must preserve its contents")
    let storeCount = assertions
    print("Platform checks: \(storeCount) route persistence assertions passed")

    try ConfigurationLoader.validate(Configuration(profiles: [profile()]))
    assertions += 1
    try rejects("Duplicate profile IDs must fail") {
        try ConfigurationLoader.validate(Configuration(profiles: [profile(), profile()]))
    }
    var second = profile(); second.id = "studio"
    try rejects("Shared LaunchAgent labels must fail") {
        try ConfigurationLoader.validate(Configuration(profiles: [profile(), second]))
    }
    var item = profile(); item.playbackUID = item.captureUID
    try rejects("Playback cannot be the virtual capture route") {
        try ConfigurationLoader.validate(Configuration(profiles: [item]))
    }
    try rejects("Unsupported configuration version must fail") {
        try ConfigurationLoader.validate(Configuration(version: 99, profiles: [profile()]))
    }
    try rejects("Empty configuration must fail") {
        try ConfigurationLoader.validate(Configuration(profiles: []))
    }
    for endpoint in ["ws://example.com:1234", "http://127.0.0.1:1234", "ws://127.0.0.1",
                     "ws://user:secret@localhost:1234", "ws://localhost:1234/?command=start"] {
        var item = profile(); item.websocketURL = endpoint
        try rejects("Unsafe control endpoint should fail: \(endpoint)") {
            try ConfigurationLoader.validate(Configuration(profiles: [item]))
        }
    }
    for endpoint in ["ws://127.0.0.1:1234", "ws://localhost:1234", "ws://[::1]:1234"] {
        var item = profile(); item.websocketURL = endpoint
        try ConfigurationLoader.validate(Configuration(profiles: [item]))
        assertions += 1
    }
    item = profile(); item.launchAgentPath = "~/Library/LaunchAgents/test.home.plist"
    let configurationURL = root.appendingPathComponent("profiles.json")
    try JSONEncoder().encode(Configuration(profiles: [item])).write(to: configurationURL)
    let loaded = try ConfigurationLoader.load(from: configurationURL)
    try expect(loaded.profiles.first?.launchAgentPath == NSHomeDirectory() + "/Library/LaunchAgents/test.home.plist",
               "Configuration loading must expand home paths")
    let configCount = assertions - storeCount
    print("Platform checks: \(configCount) configuration assertions passed")

    for state in ["Running", "Paused"] { try DSPReadiness.validateState(state); assertions += 1 }
    for state in ["Inactive", "Starting", "Stalled", "Unknown"] {
        try rejects("Non-ready DSP state must fail: \(state)") { try DSPReadiness.validateState(state) }
    }
    let reply = Data(#"{"GetState":{"result":"Ok","value":"Paused"}}"#.utf8)
    try expect(try DSPReadiness.value(from: reply, command: "GetState") as? String == "Paused", "Readiness envelope parsing")
    for reply in [#"{"GetState":{"result":"Error","value":"Running"}}"#,
                  #"{"GetVersion":{"result":"Ok","value":"Running"}}"#, "garbage"] {
        try rejects("Invalid readiness reply must fail") {
            _ = try DSPReadiness.value(from: Data(reply.utf8), command: "GetState")
        }
    }
    func dspConfiguration(_ capture: Any, _ playback: Any, type: String = "CoreAudio") throws -> String {
        let object: [String: Any] = ["devices": ["capture": ["type": type, "device": capture],
                                                     "playback": ["type": type, "device": playback]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    try DSPReadiness.validateConfiguration(dspConfiguration("Virtual", "Physical"), profile: profile())
    assertions += 1
    try rejects("Wrong DSP playback endpoint must fail") {
        try DSPReadiness.validateConfiguration(dspConfiguration("Virtual", "Wrong"), profile: profile())
    }
    try rejects("Implicit DSP capture endpoint must fail") {
        try DSPReadiness.validateConfiguration(dspConfiguration(NSNull(), "Physical"), profile: profile())
    }
    try rejects("Non-CoreAudio DSP endpoints must fail") {
        try DSPReadiness.validateConfiguration(dspConfiguration("Virtual", "Physical", type: "File"), profile: profile())
    }
    let readinessCount = assertions - storeCount - configCount
    print("Platform checks: \(readinessCount) DSP readiness assertions passed")

    let executable = root.appendingPathComponent("camilladsp")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var managedProfile = profile()
    managedProfile.launchAgentPath = root.appendingPathComponent("managed-dsp.plist").path
    let arguments = [executable.path, "-p", "1234", "/test/config.yml"]
    let plist: [String: Any] = ["Label": managedProfile.launchAgentLabel, "ProgramArguments": arguments]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: URL(fileURLWithPath: managedProfile.launchAgentPath))
    func loadedJob(path: String? = nil, program: String? = nil, args: [String]? = nil) -> ProcessResult {
        let lines = ["path = " + (path ?? managedProfile.launchAgentPath),
                     "program = " + (program ?? executable.path), "arguments = {"]
            + (args ?? arguments) + ["}", "state = running"]
        return ProcessResult(status: 0, stdout: lines.joined(separator: "\n"), stderr: "")
    }
    let missingJob = ProcessResult(status: 113, stdout: "", stderr: "Could not find service")
    for (name, loaded) in [("source path", loadedJob(path: "/external/job.plist")),
                           ("program", loadedJob(program: "/external/camilladsp")),
                           ("arguments", loadedJob(args: arguments + ["--extra"]))] {
        for starting in [true, false] {
            var calls: [[String]] = []
            let manager = LaunchdDSPManager(runCommand: { args in calls.append(args); return loaded },
                                           sleep: { _ in throw CheckFailure.failed("Unrelated DSP job must not wait") })
            var rejected = false
            do {
                if starting { try await manager.start(managedProfile) }
                else { try await manager.stop(managedProfile) }
            } catch {
                rejected = error.localizedDescription.contains("Refusing unrelated DSP job") && !(error is DSPFailure)
            }
            try expect(rejected, "DSP \(starting ? "start" : "stop") rejects a mismatched loaded \(name)")
            try expect(calls.map { $0[0] } == ["print"], "Mismatched DSP \(name) must not mutate services")
        }
    }
    var changedAfterStart = false
    var calls: [[String]] = []
    let changedManager = LaunchdDSPManager(runCommand: { args in
        calls.append(args)
        return changedAfterStart ? loadedJob(path: "/replaced/job.plist") : loadedJob()
    })
    try await changedManager.start(managedProfile)
    try expect(calls.map { $0[0] } == ["print", "kickstart"] && calls.last?.contains("-k") == false,
               "Exact managed DSP adoption retains non-restarting kickstart")
    changedAfterStart = true
    calls.removeAll()
    var replacementRejected = false
    do { try await changedManager.stop(managedProfile) }
    catch { replacementRejected = error.localizedDescription.contains("Refusing unrelated DSP job") }
    try expect(replacementRejected && calls.map { $0[0] } == ["print"],
               "DSP stop revalidates identity after a successful start")

    calls.removeAll()
    var unloaded = false
    var gracePeriods = 0
    let ownedManager = LaunchdDSPManager(runCommand: { args in
        calls.append(args)
        if args[0] == "bootout" {
            unloaded = true
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        return unloaded ? missingJob : loadedJob()
    }, sleep: { milliseconds in
        try expect(milliseconds == 1000, "DSP shutdown retains its single grace period")
        gracePeriods += 1
    })
    try await ownedManager.stop(managedProfile)
    try expect(calls.map { $0[0] } == ["print", "bootout", "print"] && gracePeriods == 1,
               "Exact configured DSP job unloads with bounded verification")
    calls.removeAll()
    let absentManager = LaunchdDSPManager(runCommand: { args in calls.append(args); return missingJob })
    var absentProfile = managedProfile
    absentProfile.launchAgentPath = root.appendingPathComponent("missing.plist").path
    try await absentManager.stop(absentProfile)
    try expect(calls.map { $0[0] } == ["print"], "Missing DSP service needs no plist or service mutation")
    for removedURL in [URL(fileURLWithPath: managedProfile.launchAgentPath), executable] {
        let original = try Data(contentsOf: removedURL)
        for replaced in [false, true] {
            var stopping = false
            var didUnload = false
            calls.removeAll()
            let cachedManager = LaunchdDSPManager(runCommand: { args in
                calls.append(args)
                if args[0] == "bootout" { didUnload = true; return ProcessResult(status: 0, stdout: "", stderr: "") }
                if didUnload { return missingJob }
                return stopping && replaced ? loadedJob(args: arguments + ["--foreign"]) : loadedJob()
            }, sleep: { _ in })
            try await cachedManager.start(managedProfile)
            try FileManager.default.removeItem(at: removedURL)
            stopping = true
            calls.removeAll()
            var refused = false
            do { try await cachedManager.stop(managedProfile) } catch { refused = true }
            try original.write(to: removedURL)
            if removedURL == executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
            try expect(replaced ? refused && !didUnload : !refused && didUnload,
                       "Cached DSP identity permits disappeared-file cleanup only for the same loaded job")
            try expect(calls.map { $0[0] } == (replaced ? ["print"] : ["print", "bootout", "print"]),
                       "Cached DSP cleanup remains bounded and refuses replacement mutations")
        }
    }
    let savedPlist = try Data(contentsOf: URL(fileURLWithPath: managedProfile.launchAgentPath))
    try FileManager.default.removeItem(atPath: managedProfile.launchAgentPath)
    calls.removeAll()
    let unknownManager = LaunchdDSPManager(runCommand: { args in calls.append(args); return loadedJob() })
    var unknownRejected = false
    do { try await unknownManager.stop(managedProfile) } catch { unknownRejected = true }
    try savedPlist.write(to: URL(fileURLWithPath: managedProfile.launchAgentPath))
    try expect(unknownRejected && calls.map { $0[0] } == ["print"],
               "Unknown loaded DSP with missing configuration never unloads by label")

    calls.removeAll()
    var partiallyLoaded = false
    var partialUnloaded = false
    let partialManager = LaunchdDSPManager(runCommand: { args in
        calls.append(args)
        if args[0] == "bootstrap" {
            partiallyLoaded = true
            try FileManager.default.removeItem(atPath: managedProfile.launchAgentPath)
            return ProcessResult(status: 1, stdout: "", stderr: "simulated partial bootstrap failure")
        }
        if args[0] == "bootout" { partialUnloaded = true; return ProcessResult(status: 0, stdout: "", stderr: "") }
        return partiallyLoaded && !partialUnloaded ? loadedJob() : missingJob
    }, sleep: { _ in })
    var partialFailed = false
    do { try await partialManager.start(managedProfile) } catch { partialFailed = true }
    try await partialManager.stop(managedProfile)
    try savedPlist.write(to: URL(fileURLWithPath: managedProfile.launchAgentPath))
    try expect(partialFailed && partialUnloaded && calls.map { $0[0] } == ["print", "bootstrap", "print", "bootout", "print"],
               "Identity cached before bootstrap safely cleans a partial start after configuration disappears")
    let ownershipCount = assertions - storeCount - configCount - readinessCount
    print("Platform checks: \(ownershipCount) DSP ownership assertions passed")

    let success = try await ProcessRunner.run("/usr/bin/printf", arguments: ["hello"])
    try expect(success.status == 0 && success.stdout == "hello" && success.stderr.isEmpty,
               "Command success must return captured output")
    let failure = try await ProcessRunner.run("/bin/ls", arguments: [root.appendingPathComponent("does-not-exist").path])
    try expect(failure.status != 0 && !failure.stderr.isEmpty, "Command failure must preserve stderr and nonzero status")
    let bounded = try await ProcessRunner.run("/usr/bin/head", arguments: ["-c", "200000", "/dev/zero"])
    try expect(bounded.status == 0 && bounded.stdout.utf8.count == 128 * 1024,
               "Large command output must be bounded without pipe deadlock")
    var launchRejected = false
    do { _ = try await ProcessRunner.run(root.appendingPathComponent("missing-command").path, arguments: []) }
    catch { launchRejected = true }
    try expect(launchRejected, "Missing executable must throw")

    // Both children have finite lifetimes even if timeout/cancellation regresses.
    // An outer runner deadline also protects against a continuation that never resumes.
    let began = ProcessInfo.processInfo.systemUptime
    var timedOut = false
    do { _ = try await ProcessRunner.run("/bin/sleep", arguments: ["2"], timeout: 0.05) }
    catch { timedOut = error.localizedDescription.contains("timed out") }
    try expect(timedOut, "Command timeout must produce a timeout error")
    try expect(ProcessInfo.processInfo.systemUptime - began < 1.5, "Command timeout must return promptly")

    let cancellationBegan = ProcessInfo.processInfo.systemUptime
    let task = Task { try await ProcessRunner.run("/bin/sleep", arguments: ["2"], timeout: 3) }
    try await Task.sleep(nanoseconds: 20_000_000)
    task.cancel()
    var cancelled = false
    do { _ = try await task.value } catch { cancelled = error is CancellationError }
    try expect(cancelled, "Command cancellation must throw CancellationError")
    try expect(ProcessInfo.processInfo.systemUptime - cancellationBegan < 1.5, "Command cancellation must return promptly")
    let processCount = assertions - storeCount - configCount - readinessCount - ownershipCount
    print("Platform checks: \(processCount) process assertions passed")
    print("Platform checks: \(assertions) assertions total; no live audio or service mutations")
}
