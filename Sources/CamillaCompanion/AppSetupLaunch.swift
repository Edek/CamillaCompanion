// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor final class ApplicationReopenDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let session = Application.session { session.showPanel() }
        else if let previewMenu = Application.previewMenu { previewMenu.show() }
        else { Application.setupWindow?.showSetup() }
        return false
    }
}

@MainActor extension Application {
    /// Native bundle entry and explicit development launch share one route.
    static func openApplication(arguments: [String], setupOnly: Bool) throws {
        let resolver = ApplicationLaunchPathResolver(homeDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            bundleURL: Bundle.main.bundleURL, bundleExecutableURL: Bundle.main.executableURL)
        // Preserve explicit CLI validation and Setup's default paths. Only an
        // implicit application entry inspects the user's known login job.
        let explicitPaths = try resolver.resolveExplicitPaths(arguments: arguments, setupOnly: setupOnly)
        NSApplication.shared.delegate = applicationDelegate
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let paths: ApplicationLaunchPaths
            do {
                if let explicitPaths { paths = explicitPaths }
                else { paths = try await resolver.resolve() }
            }
            catch { showLaunchFailure(error.localizedDescription) }
            let configurationURL = paths.configurationURL
            let runtimeStateURL = paths.runtimeStateURL
            if setupOnly {
                showSetup(configurationURL: configurationURL, runtimeStateURL: runtimeStateURL)
                return
            }
            do {
                // Acquire ownership before inspecting configuration. A live or
                // starting owner must never be mistaken for missing setup.
                var ownership: ControllerInstanceLock? = try ControllerInstanceLock(stateURL: runtimeStateURL)
                let configuration: Configuration
                do { configuration = try ConfigurationLoader.load(from: configurationURL) }
                catch {
                    // Release before Setup, whose save has its own lock guard.
                    // Invalid/inaccessible files remain preserved by Setup.
                    ownership = nil
                    showSetup(configurationURL: configurationURL, runtimeStateURL: runtimeStateURL)
                    return
                }
                try startConfiguredSession(configuration, configurationURL: configurationURL,
                                           runtimeStateURL: runtimeStateURL, instanceLock: ownership,
                                           sessionArguments: paths.sessionArguments)
            } catch ControllerInstanceLock.AcquisitionError.inUse {
                let stateURL = runtimeStateURL
                let shown = await ApplicationLaunchHandoff.showExisting(show: {
                    await Task.detached {
                        guard let reply = try? ControllerCommandClient.send(.init(command: .show),
                            stateURL: stateURL, timeout: 1) else { return false }
                        return reply.status != nil && reply.error == nil
                    }.value
                })
                if shown { exit(EXIT_SUCCESS) }
                showLaunchFailure("The running controller did not reveal its panel. It may still be starting or be unresponsive. Try opening the app again.")
            } catch {
                showLaunchFailure(error.localizedDescription)
            }
        }
        NSApplication.shared.run()
    }

    private static func showLaunchFailure(_ message: String) -> Never {
        let alert = NSAlert()
        alert.messageText = "Cannot open CamillaCompanion"
        alert.informativeText = message
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(EXIT_FAILURE)
    }

    static func showSetup(configurationURL: URL, runtimeStateURL: URL) {
        if let setupWindow { setupWindow.showSetup(); return }
        setupWindow = SetupWindowController(configurationURL: configurationURL,
            runtimeStateURL: runtimeStateURL, devices: { try CoreAudioManager().snapshot().devices },
            onClose: {
                setupWindow = nil
                if session == nil { exit(EXIT_SUCCESS) }
            },
            onActivate: { configuration in
                guard session == nil else { throw SwitcherError.message("The current session is already configured.") }
                try startConfiguredSession(configuration, configurationURL: configurationURL,
                                           runtimeStateURL: runtimeStateURL)
                setupWindow = nil
            })
        setupWindow?.showSetup()
    }

    static func startConfiguredSession(_ configuration: Configuration, configurationURL: URL,
                                       runtimeStateURL: URL, instanceLock: ControllerInstanceLock? = nil,
                                       sessionArguments: [String] = []) throws {
        let saved = try ConfigurationLoader.load(from: configurationURL)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(saved) == encoder.encode(configuration) else {
            throw SwitcherError.message("The saved configuration changed. Reopen setup before activating.")
        }
        let options = try Options(["--config", configurationURL.path, "--state", runtimeStateURL.path,
                                   "--menu-bar", "true"] + sessionArguments)
        if let profileID = options.profileID, !configuration.profiles.contains(where: { $0.id == profileID }) {
            throw SwitcherError.message("Unknown startup profile: " + profileID)
        }
        guard options.mode != .forceOn || options.profileID != nil else {
            throw SwitcherError.message("Startup force-on mode requires a profile.")
        }
        let live = try InteractiveSession(configuration: configuration, options: options, instanceLock: instanceLock)
        session = live
        Task { @MainActor in await live.start(); live.showPanel() }
    }
}
