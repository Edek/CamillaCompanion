import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runNativeInterfaceChecks() throws {
    for (scenario, passed) in MenuBarVerification.verifyPanelLifecycle() {
        try check(passed, "Panel lifecycle: \(scenario)")
    }
    let directory = ProcessInfo.processInfo.environment["AUTOSWITCH_PANEL_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    let continuousGlass = try NativePanelLayoutVerification.continuousGlassCoversPanel(renderDirectory: directory)
    try check(continuousGlass,
              "A neutral translucent wash darkens the continuous panel glass uniformly, including outer padding, with an opaque Reduce Transparency fallback")
    try check(AudioDisclosureStyleVerification.headingsMatch(),
              "Live Metering and Aux Levels share font, tint, chevrons and full-width 28-point disclosure sizing across focus and appearance states")
    try check(SignalLevelsPanelVerification.disclosureControlsReadingPreference(),
              "Live Metering disclosure collapses/expands its reading preference, retains inactive appearance policy and exposes its expanded state")
    try check(SignalLevelsPanelVerification.emptyOfflineSectionsStayCompact(),
              "Empty offline meter/Aux disclosures fit compactly through Retry and independent expansion, while disconnected known rows retain geometry and dim safely")
    try check(NativePanelLayoutVerification.offlineRoutingAndStatusAreTruthful(),
              "Offline DSP status keeps its warning glyph and tint, while inactive capture routing is unselected and dispatches no routing action")
    try check(SignalLevelsPanelVerification.numericTrailingEdgesAlign(),
              "Meter labels, numbers and dBFS share the panel content edges across widths")
    try check(SignalLevelsPanelVerification.rememberedTopologyStaysStable(),
              "Meter reopening reserves per-profile channel rows with dim unavailable values while local mode controls remain usable")
    try check(NativePanelLayoutVerification.footerControlsAreConsistent(),
              "Footer aligns preset height with More's bezel, preserves widths and fonts, truncates long names and keeps native preset actions and warning metadata")
    try check(NativePanelLayoutVerification.fallbackControlsKeepLayout(),
              "Fallback Auto/Force/Off keeps Auto read-only, preserves selected devices for Force/Off, stable geometry and menu tracking; reordered Audio Controls collapse preserves policy and focus")
    try check(NativePanelLayoutVerification.statusFeedbackKeepsLayout(),
              "Permanent header Status keeps panel height and control positions through transitions, long errors and recovery actions, preserving details, dismissal and tracked menu authority")
    try check(NativePanelLayoutVerification.primaryActionsMatchSharedHeight(),
              "Open Web Interface and Restart DSP match other action bezel heights across appearances, focus and enabled states, preserving widths and fonts")
    try check(NativePanelLayoutVerification.activeColorsPreserveFocusAndPolicy(),
              "Keep Active Colors preserves selection, enabled policy and actual focus while restoring inactive control colors")
    let normalSelectionsFit = try NativePanelLayoutVerification.verifyNormalSelectionActiveColors(renderDirectory: directory)
    try check(normalSelectionsFit,
              "Inactive Auto, On and Processed restore accent fill and white text with Keep Active Colors, then return to native appearance when disabled")
    let segmentsFit = try NativePanelLayoutVerification.verifySegmentRasterization(renderDirectory: directory)
    try check(segmentsFit, "DSP/GUI Off keep policy coloring, Fallback Off stays red, and Bypassed stays orange with readable text across appearances and focus states")
    let muteFits = try NativePanelLayoutVerification.verifyMuteRasterization(renderDirectory: directory)
    try check(muteFits, "Mute matches the shared 0 dB bezel dimensions and corners, with red filled white active text and a distinct mixed state")
    let aboutFits = try NativePanelLayoutVerification.verifyAboutWindow(renderDirectory: directory)
    try check(aboutFits, "About centers waveform and metadata, and diagnostics fit and refresh on demand")
    let profile = ControllerProfile(id: "fixture", name: "Fixture", available: true, guiUnavailableReason: "GUI not configured", gui: nil, captureUID: "virtual")
    for (output, released, pending) in [("virtual", false, false), ("physical", true, false), ("physical", false, true)] {
        let model = MenuBarPresentation(mode: .forceOn, state: .active("fixture"), preferredProfileID: "fixture", outputName: "Fixture output", suspended: false, released: released, recovering: false, profiles: [profile], outputUID: output, routingRestoring: pending)
        if !pending {
            try check(NativePanelLayoutVerification.routingReselectionIsInert(model), "Reselecting current routing dispatches no action and preserves observed selection")
            try check(NativePanelLayoutVerification.routingSelectedStyleMatchesNative(model), "Current routing keeps enabled native selection styling while alternatives retain guards")
        }
        try check(NativePanelLayoutVerification.routingSelectionMatchesObservation(model), "Native routing selection follows observed output and transition availability")
    }
    print("Native interface checks: filled mute, About diagnostics and observed routing controls passed")
}
