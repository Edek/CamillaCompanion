// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runApplicationEntryChecks() async throws {
    let app = URL(fileURLWithPath: "/temporary/CamillaCompanion.app")
    try check(ApplicationEntry.usesNativeLaunch(arguments: [], bundleURL: app, packageType: "APPL"),
              "No-argument native application entry opens the companion")
    try check(ApplicationEntry.usesNativeLaunch(arguments: ["-psn_0_123"], bundleURL: app, packageType: "APPL"),
              "Legacy Finder process serial argument uses native entry")
    try check(!ApplicationEntry.usesNativeLaunch(arguments: [], bundleURL: URL(fileURLWithPath: "/tmp/camillacompanion"), packageType: nil),
              "No-argument development CLI preserves help")
    try check(!ApplicationEntry.usesNativeLaunch(arguments: ["--help"], bundleURL: app, packageType: "APPL") &&
              !ApplicationEntry.usesNativeLaunch(arguments: ["launch", "--state", "/tmp/custom"], bundleURL: app, packageType: "APPL"),
              "Explicit bundle CLI arguments and custom state remain explicit")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("application-entry-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("runtime.json")
    try check(GUICommandServer.socketURL(stateURL: state).deletingLastPathComponent().lastPathComponent.hasPrefix("camillacompanion-"),
              "Controller IPC uses the current application namespace")
    var owner: ControllerInstanceLock? = try ControllerInstanceLock(stateURL: state)
    do {
        _ = try ControllerInstanceLock(stateURL: state)
        throw CheckFailure.failed("Concurrent launcher acquired the controller lock")
    } catch ControllerInstanceLock.AcquisitionError.inUse { }
    try check(!FileManager.default.fileExists(atPath: state.path), "Acquiring ownership does not create runtime state or change audio")
    withExtendedLifetime(owner) { }
    owner = nil
    let successor = try ControllerInstanceLock(stateURL: state)
    withExtendedLifetime(successor) { }

    var requests = 0; var pauses = 0
    let eventual = await ApplicationLaunchHandoff.showExisting(show: {
        requests += 1
        return requests == 3
    }, pause: { pauses += 1 })
    try check(eventual && requests == 3 && pauses == 2,
              "Concurrent startup retries only until the owner's show request succeeds")
    requests = 0; pauses = 0
    let unavailable = await ApplicationLaunchHandoff.showExisting(show: {
        requests += 1; return false
    }, pause: { pauses += 1 })
    try check(!unavailable && requests == 4 && pauses == 3,
              "Unresponsive-owner handoff stops after a finite number of requests")

    let server = GUICommandServer(stateURL: state, controllerHandler: { _ in
        // Simulate an unresponsive handler using only this owned private fixture.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return ControllerReply(error: "Fixture did not show a panel")
    }, handler: { _ in GUIReply(error: "Unused fixture command") })
    try server.start()
    defer { server.stop() }
    let began = ProcessInfo.processInfo.systemUptime
    let timedOut = await Task.detached {
        do {
            _ = try ControllerCommandClient.send(.init(command: .show), stateURL: state, timeout: 1)
            return false
        } catch { return true }
    }.value
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    try check(timedOut && elapsed < 1.5, "Launch show uses a short bounded IPC timeout")
    // Let the owned handler finish before removing its private socket directory.
    try? await Task.sleep(nanoseconds: 600_000_000)
    let socketRoot = GUICommandServer.socketURL(stateURL: state).deletingLastPathComponent()
    server.stop()
    try? FileManager.default.removeItem(at: socketRoot)
}
