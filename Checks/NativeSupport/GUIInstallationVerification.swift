import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor enum GUIInstallationVerification {
    static func verifyAvailabilityTransitions() -> [(String, Bool)] {
        let panel = AudioControlPanel()
        var actions: [Int] = []
        panel.onGUIMode = { actions.append($0) }
        func model(_ installation: GUIInstallationState, policy: GUIPolicy = .manualOff,
                   observed: GUIServiceState = .stopped) -> MenuBarPresentation {
            let gui = GUIStatus(profileID: "fixture", policy: policy, autoStart: false, desiredRunning: false,
                                observed: observed, url: "http://localhost:5005", lastError: nil)
            return MenuBarPresentation(mode: .automatic, state: .active("fixture"), preferredProfileID: "fixture",
                outputName: "BlackHole", suspended: false, released: false, recovering: false,
                profiles: [ControllerProfile(id: "fixture", name: "Fixture", available: true,
                    guiUnavailableReason: nil, gui: gui, captureUID: "virtual", guiInstallationState: installation)],
                outputUID: "virtual")
        }
        panel.render(model(.configured), error: nil)
        let size = panel.measureNaturalSize()
        let controlFrame = panel.guiControl.frame
        var checks: [(String, Bool)] = []
        for availability in [GUIInstallationState.notConfigured, .uninstalled, .notFound] {
            panel.render(model(availability), error: nil)
            let unchanged = panel.measureNaturalSize() == size && panel.guiControl.frame == controlFrame
            checks.append((availability.rawValue + " retains bounds and neutral disabled label",
                unchanged && panel.guiControl.segmentCount == 1 && !panel.guiControl.isEnabled
                && panel.guiControl.selectedSegment == -1
                && panel.guiControl.label(forSegment: 0) == availability.unavailableLabel
                && panel.guiControl.accessibilityHelp()?.contains(availability.unavailableLabel!) == true
                && !panel.openButton.isEnabled && panel.guiStatusLabel.textColor == .secondaryLabelColor))
            // Even synthetic actions cannot reinterpret the status segment as Auto.
            panel.guiControl.isEnabled = true
            panel.guiControl.selectedSegment = 0
            _ = panel.guiControl.sendAction(panel.guiControl.action, to: panel.guiControl.target)
            checks.append((availability.rawValue + " cannot dispatch a GUI policy", actions.isEmpty))
            panel.render(model(.configured), error: nil)
            checks.append((availability.rawValue + " restores retained Off selection without changing layout",
                panel.measureNaturalSize() == size && panel.guiControl.frame == controlFrame
                && panel.guiControl.segmentCount == 3 && panel.guiControl.isEnabled
                && panel.guiControl.selectedSegment == 2 && actions.isEmpty))
        }
        for (policy, segment) in [(GUIPolicy.automatic, 0), (.manualOn, 1), (.manualOff, 2)] {
            panel.render(model(.configured, policy: policy), error: nil)
            checks.append(("configured " + policy.rawValue + " retains normal control mapping",
                panel.guiControl.selectedSegment == segment && panel.guiControl.isEnabled))
        }
        panel.render(model(.configured, policy: .manualOn, observed: .failed), error: nil)
        checks.append(("runtime failure retains normal segments", panel.guiControl.segmentCount == 3 && panel.guiControl.isEnabled))
        panel.render(model(.configured, policy: .manualOn, observed: .running), error: nil)
        checks.append(("installed running GUI restores browser", panel.openButton.isEnabled && actions.isEmpty))
        return checks
    }
}
