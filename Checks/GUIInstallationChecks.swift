import Foundation
import AutoAudioCore

@MainActor func runGUIInstallationChecks() throws {
    func service(_ observed: GUIServiceState = .stopped, policy: GUIPolicy = .manualOff) -> GUIStatus {
        GUIStatus(profileID: "fixture", policy: policy, autoStart: false, desiredRunning: false,
                  observed: observed, url: "http://localhost:5005", lastError: observed == .failed ? "Failed to start" : nil)
    }
    func model(_ installation: GUIInstallationState?, gui: GUIStatus?) -> MenuBarPresentation {
        MenuBarPresentation(mode: .automatic, state: .active("fixture"), preferredProfileID: "fixture",
            outputName: "BlackHole", suspended: false, released: false, recovering: false,
            profiles: [ControllerProfile(id: "fixture", name: "Fixture", available: true,
                guiUnavailableReason: nil, gui: gui, captureUID: "virtual", guiInstallationState: installation)],
            outputUID: "virtual")
    }
    let oldPayload = Data(#"{"id":"fixture","name":"Fixture","available":true}"#.utf8)
    let decoded = try JSONDecoder().decode(ControllerProfile.self, from: oldPayload)
    try check(decoded.guiInstallationState == nil && decoded.gui == nil,
              "Legacy controller status without GUI installation metadata remains decodable")
    try check(model(nil, gui: nil).guiInstallationState == .notConfigured
              && model(nil, gui: service()).guiInstallationState == .configured,
              "Legacy GUI availability distinguishes missing configuration from a configured stopped service")
    for installation in [GUIInstallationState.notConfigured, .uninstalled, .notFound] {
        let unavailable = model(installation, gui: service(.failed, policy: .manualOn))
        try check(unavailable.guiStatusText == "GUI " + installation.unavailableLabel!
                  && unavailable.guiStatusEmphasis == .neutral && unavailable.guiError == nil
                  && !unavailable.guiConfirmedOff && !unavailable.guiControls.enabled
                  && !unavailable.openWeb.enabled && !unavailable.retryGUI.enabled,
                  "Missing GUI state is neutral and blocks GUI actions without treating absence as a runtime failure")
        try check(unavailable.panelStatus().text == "Ready" && unavailable.guiPolicy == .manualOn,
                  "Optional GUI absence preserves DSP readiness and retained GUI policy")
        var recoveringService = service(.starting)
        recoveringService.recovering = true
        try check(model(installation, gui: recoveringService).panelStatus().text == "Ready",
                  "Installation availability outranks stale GUI recovery and startup observations")
        let payload = try JSONEncoder().encode(unavailable.selectedProfile!)
        let restored = try JSONDecoder().decode(ControllerProfile.self, from: payload)
        try check(restored.guiInstallationState == installation,
                  "GUI installation availability round-trips in controller status")
    }
    let configuredOff = model(.configured, gui: service())
    try check(configuredOff.guiControls.enabled && configuredOff.guiConfirmedOff
              && configuredOff.guiStatusText == "GUI Off" && configuredOff.guiStatusEmphasis == .off,
              "An installed configured stopped GUI keeps its ordinary Off state and controls")
    let configuredFailure = model(.configured, gui: service(.failed))
    try check(configuredFailure.guiStatusText == "GUI Failed" && configuredFailure.guiStatusEmphasis == .error
              && configuredFailure.retryGUI.enabled && configuredFailure.panelStatus().text == "GUI failed",
              "A configured GUI runtime failure retains its bounded retry behavior")
    try check(model(.configured, gui: service(.running)).openWeb.enabled,
              "A configured ready GUI enables its browser action")
    for (scenario, passed) in GUIInstallationVerification.verifyAvailabilityTransitions() {
        try check(passed, "Native GUI installation availability: " + scenario)
    }
}
