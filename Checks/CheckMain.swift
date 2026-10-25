import Foundation
import Darwin
import AppKit
import AutoAudioPlatform

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
enum CheckMain {
    nonisolated static func main() {
        if ProcessInfo.processInfo.environment["AUTOSWITCH_NATIVE_PANEL_ACCESS_ONLY"] == "1" {
            MainActor.assumeIsolated { runNativePanelAccess() }
            return
        }
        if ProcessInfo.processInfo.environment["AUTOSWITCH_NATIVE_SETUP_DISCOVERY_ONLY"] == "1" {
            MainActor.assumeIsolated { runNativeSetupDiscovery() }
            return
        }
        Task { @MainActor in
            await runChecks()
            exit(EXIT_SUCCESS)
        }
        // URLSession and AppKit fixtures also require the main CFRunLoop.
        RunLoop.main.run()
    }

    /// AppKit owns the native event loop from the synchronous entry boundary.
    /// Completion must come from the verification task, never an early loop exit.
    @MainActor private static func runNativePanelAccess() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            FileHandle.standardError.write(Data("CHECK FAILED: Native panel access exceeded its finite 30-second deadline.\n".utf8))
            exit(EXIT_FAILURE)
        }
        Task { @MainActor in
            let results = await PanelAccessVerification.nativeInteractionChecks()
            let failures = results.filter { !$0.value }.map(\.key).sorted()
            if !failures.isEmpty {
                for scenario in failures {
                    FileHandle.standardError.write(Data("CHECK FAILED: Native panel access: \(scenario)\n".utf8))
                }
                exit(EXIT_FAILURE)
            }
            print("Native panel access interaction passed. (\(results.count) checks completed.)")
            fflush(stdout)
            exit(EXIT_SUCCESS)
        }
        application.run()
        FileHandle.standardError.write(Data("CHECK FAILED: Native application loop stopped before verification completed.\n".utf8))
        exit(EXIT_FAILURE)
    }

    @MainActor private static func runNativeSetupDiscovery() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            FileHandle.standardError.write(Data("CHECK FAILED: Setup discovery exceeded its finite 30-second deadline.\n".utf8))
            exit(EXIT_FAILURE)
        }
        Task { @MainActor in
            do { try await runNativeSetupDiscoveryChecks(); exit(EXIT_SUCCESS) }
            catch {
                FileHandle.standardError.write(Data("CHECK FAILED: \(error)\n".utf8)); exit(EXIT_FAILURE)
            }
        }
        application.run()
        FileHandle.standardError.write(Data("CHECK FAILED: Native Setup loop stopped before completion.\n".utf8))
        exit(EXIT_FAILURE)
    }

    @MainActor private static func runChecks() async {
        do {
            if ProcessInfo.processInfo.environment["AUTOSWITCH_APPLICATION_ENTRY_ONLY"] == "1" {
                _ = NSApplication.shared
                try await runApplicationEntryChecks()
                try await runApplicationLaunchPathsChecks()
                print("Application entry and finite handoff checks passed.")
                return
            }
            // Showing/activating real Settings changes AppKit's run-loop state.
            // Keep this finite interaction separate from the asynchronous suite.
            if ProcessInfo.processInfo.environment["AUTOSWITCH_NATIVE_STARTUP_ONLY"] == "1" {
                try await runLoginItemChecks(includeNative: true)
                print("Native startup Settings interaction passed.")
                return
            }
            if ProcessInfo.processInfo.environment["AUTOSWITCH_COMPANION_ONLY"] == "1" {
                try await runCompanionChecks()
                return
            }
            if ProcessInfo.processInfo.environment["AUTOSWITCH_WEBSOCKET_CLEANUP_ONLY"] == "1" {
                _ = NSApplication.shared
                try await runWebSocketCleanupChecks()
                return
            }
            // Native popup tracking changes NSApplication's run-loop state.
            // Run this interaction in its own finite process, separately from
            // the asynchronous portable suite.
            if ProcessInfo.processInfo.environment["AUTOSWITCH_NATIVE_PRESET_POPUP_ONLY"] == "1" {
                try check(PresetPopupVerification.externalSelectionOpens(),
                    "Native External popup opens and keyboard selection activates a local preset")
                print("Native preset popup interaction passed.")
                return
            }
            if ProcessInfo.processInfo.environment["CAMILLACOMPANION_INTERFACES_ONLY"] == "1" {
                _ = NSApplication.shared
                try await runDeviceRoleChecks()
                try await runInterfaceSettingsChecks()
                try await runInterfaceProfileStoreChecks()
                try await runPresetPlatformChecks()
                try await runReconcilerChecks()
                print("Interfaces, preset and automatic handoff regression checks passed. No live audio or service changes.")
                return
            }
            try runDiagnosticsChecks()
            // Run real socket timing before native focus/layout fixtures change
            // process-wide AppKit state. Keep every teardown assertion intact.
            _ = NSApplication.shared
            try await runWebSocketCleanupChecks()
            try await runApplicationEntryChecks()
            try await runApplicationLaunchPathsChecks()
            for (scenario, passed) in PanelAccessVerification.syntheticChecks() {
                try check(passed, "Panel access: \(scenario)")
            }
            try await runSetupChecks()
            try runSetupDiscoveryChecks()
            try await runLoginItemChecks()
            try runGUIInstallationChecks()
            try runFeedbackChecks()
            try await runUIPreferencesChecks()
            try runMeterModePreferencesChecks()
            try await runSilentHUDChecks()
            try await runAuxSettingsChecks()
            try runMenuPresentationChecks()
            for (scenario, passed) in await MenuBarVerification.verifyRecoveredCommandFeedback() {
                try check(passed, "Recovered command feedback: \(scenario)")
            }
            for (scenario, passed) in await MenuBarVerification.verifyCompanionDSPModeMapping() {
                try check(passed, "Companion DSP mode control: \(scenario)")
            }
            for (scenario, passed) in await MenuBarVerification.verifyPresetMenuPreparation() {
                try check(passed, "Preset menu preparation: \(scenario)")
            }
            for (scenario, passed) in try await MenuBarVerification.verifyAuxRefreshDispatch() {
                try check(passed, "Settings refresh and menu actions: \(scenario)")
            }
            for (scenario, passed) in await MenuBarVerification.verifyPresetMenuAuthority() {
                try check(passed, "Preset menu authority: \(scenario)")
            }
            for (scenario, passed) in await MenuBarVerification.verifyPresetRestartRefresh() {
                try check(passed, "Preset restart refresh: \(scenario)")
            }
            for (scenario, passed) in await MenuBarVerification.verifyPresetCoordinationOrdering() {
                try check(passed, "Preset coordination ordering: \(scenario)")
            }
            try runNativeInterfaceChecks()
            try await runDeviceRoleChecks()
            try await runInterfaceSettingsChecks()
            try await runInterfaceProfileStoreChecks()
            try runScrollablePresetChecks()
            try await runAuxFaderChecks()
            try runAuxFaderScaleChecks()
            try await runAuxFaderDisplayChecks()
            try await runAuxPlatformChecks()
            try await runCamillaDSPProtocolChecks()
            try await runMainVolumeChecks()
            try await runSignalLevelsChecks()
            try await runPresetChecks()
            try await runGUIChecks()
            try await runPlatformChecks()
            try await runLifecycleChecks()
            try await runRecoveryChecks()
            try await runReconcilerChecks()
            try await runCompanionChecks()
            try await runReconcilerWorkAuthorityChecks()
            try await runFallbackOutputChecks()
            print("All portable checks passed. No live audio routing or launchd service mutations were performed.")
        } catch {
            FileHandle.standardError.write(Data("CHECK FAILED: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
