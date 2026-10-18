import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runLifecycleChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("camillacompanion-lifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("camilladsp")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let arguments = [executable.path, "-p", "1234"]
    let plistURL = root.appendingPathComponent("dsp.plist")
    try PropertyListSerialization.data(fromPropertyList: ["Label": "test.dsp", "ProgramArguments": arguments], format: .xml, options: 0).write(to: plistURL)
    let profile = Profile(id: "test", name: "Test", triggerUID: "p", captureUID: "v", playbackUID: "p",
                          launchAgentLabel: "test.dsp", launchAgentPath: plistURL.path,
                          websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "v", expectedPlaybackDevice: "p")
    let present = ProcessResult(status: 0, stdout: (["path = " + plistURL.path,
        "program = " + executable.path, "arguments = {"] + arguments + ["}", "state = running"]).joined(separator: "\n"), stderr: "")
    let missing = ProcessResult(status: 113, stdout: "", stderr: "Could not find service")
    var operations: [String] = []
    var waited = false
    let manager = LaunchdDSPManager(runCommand: { args in
        operations.append(args[0])
        // Registration remains until the one-shot wait has completed.
        return waited ? missing : present
    }, sleep: { milliseconds in
        try check(milliseconds == 1000, "Shutdown uses one bounded grace period")
        waited = true
    })
    try await manager.stop(profile)
    try check(operations == ["print", "bootout", "print"], "Exactly one shutdown verification, no polling")

    var waits = 0
    let stuck = LaunchdDSPManager(runCommand: { _ in present }, sleep: { _ in waits += 1 })
    var failed = false
    do { try await stuck.stop(profile) }
    catch { failed = error.localizedDescription.contains("shutdown could not be confirmed") }
    try check(failed && waits == 1, "A stuck shutdown fails after a single wait")

    let absent = LaunchdDSPManager(runCommand: { _ in missing }, sleep: { _ in
        throw CheckFailure.failed("Absent service must not wait")
    })
    try await absent.stop(profile)
    do {
        try DSPReadiness.validateState("Starting")
        throw CheckFailure.failed("Starting must enter transient recovery")
    } catch DSPFailure.starting { }
    do {
        try DSPReadiness.validateState("Stalled")
        throw CheckFailure.failed("Stalled capture must not be treated as verified playback")
    } catch let error as DSPFailure {
        try check(error.localizedDescription.contains("Stalled"), "Readiness error includes the actual state")
    }
    print("Lifecycle checks: delayed unload, stuck unload, absent service, and readiness diagnostics passed")
}
