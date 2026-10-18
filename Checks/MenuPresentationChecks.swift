import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runMenuPresentationChecks() throws {
    func profile(_ id: String = "studio", available: Bool = true, gui: GUIStatus? = nil, reason: String? = nil) -> ControllerProfile {
        ControllerProfile(id: id, name: id, available: available, guiUnavailableReason: reason, gui: gui, captureUID: "blackhole")
    }
    func model(_ state: RuntimeState, mode: AutomationMode = .automatic, available: Bool = true, suspended: Bool = false, released: Bool = false, recovering: Bool = false, outputUID: String? = nil, routingRestoring: Bool = false, routingError: String? = nil) -> MenuBarPresentation {
        MenuBarPresentation(mode: mode, state: state, preferredProfileID: "studio", outputName: "Speakers", suspended: suspended, released: released, recovering: recovering, profiles: [profile(available: available)], outputUID: outputUID, routingRestoring: routingRestoring, routingError: routingError)
    }
    let readyStatus = model(.active("studio"), outputUID: "blackhole").panelStatus()
    try check(readyStatus.text == "Ready" && readyStatus.emphasis == .active && readyStatus.actions.isEmpty,
              "Permanent status reports confirmed healthy processing without recovery actions")
    let directStatus = model(.active("studio"), released: true, outputUID: "phones").panelStatus()
    try check(directStatus.text == "Bypassed routing" && directStatus.emphasis == .neutral && directStatus.actions.isEmpty,
              "Settled intentional bypass has neutral Status text without recovery actions")
    let observedDirect = model(.active("studio"), outputUID: "phones")
    try check(observedDirect.panelStatus().emphasis == .neutral
              && observedDirect.routingStatusEmphasis == .direct
              && model(.active("studio"), released: true, outputUID: "phones").routingStatusEmphasis == .bypassed,
              "Neutral settled Status retains separate Direct and Bypassed routing header emphasis")
    try check(model(.active("studio"), outputUID: "blackhole").panelStatus(surfacedError: " \n ").text == "Ready"
              && model(.active("studio")).panelStatus().text == "Routing unavailable",
              "Whitespace is not a surfaced failure and an unverified output never claims Ready")
    let errorDetail = "Could not update the fader.\nDetailed diagnostic information."
    let surfacedStatus = model(.failed("deadline"), routingRestoring: true, routingError: "restore failed").panelStatus(surfacedError: errorDetail)
    try check(surfacedStatus.text == "Action failed" && surfacedStatus.detail == errorDetail
              && surfacedStatus.emphasis == .error && surfacedStatus.actions == [.retryDSP, .dismiss],
              "Surfaced action errors outrank service and transition messages, retain full detail and ordered available actions")
    let simultaneousFailures = model(.failed("DSP deadline"), routingRestoring: true, routingError: "Routing deadline")
    try check(simultaneousFailures.panelStatus(surfacedError: "DSP deadline").text == "DSP failed"
              && simultaneousFailures.panelStatus(surfacedError: "DSP deadline").detail == "DSP deadline"
              && simultaneousFailures.panelStatus(surfacedError: "Routing deadline").text == "Output routing failed"
              && simultaneousFailures.panelStatus(surfacedError: "Routing deadline").detail == "Routing deadline"
              && simultaneousFailures.panelStatus(surfacedError: errorDetail).text == "Action failed",
              "Surfaced service errors preserve their matching domain and detail, even alongside a different model failure")
    try check(model(.failed("shared failure"), routingError: "shared failure").panelStatus(surfacedError: "shared failure").text == "Output routing failed",
              "Identical service error details use the shared status's routing-before-DSP precedence")
    let routingFailureStatus = model(.failed("deadline"), recovering: true, routingError: "restore failed").panelStatus()
    try check(routingFailureStatus.text == "Output routing failed" && !routingFailureStatus.detail.contains("restore failed")
              && routingFailureStatus.actions.isEmpty,
              "Routing failure remains truthful without resurrecting dismissed detail; bounded DSP recovery suppresses Retry")
    let offlineRetryStatus = model(.failed("deadline"), available: false).panelStatus()
    try check(offlineRetryStatus.text == "DSP failed" && offlineRetryStatus.actions.isEmpty,
              "An unavailable interface never exposes an unavailable Retry action in the shared status")
    try check(model(.starting("studio")).panelStatus().text == "DSP starting"
              && model(.stopping("studio")).panelStatus().text == "DSP stopping"
              && model(.active("studio"), recovering: true).panelStatus().text == "DSP recovery in progress"
              && model(.active("studio"), routingRestoring: true).panelStatus().text == "Output routing in progress",
              "Status distinguishes startup, shutdown, recovery and routing transitions")
    try check(model(.idle, mode: .forceOff, available: false).panelStatus().text == "Interface disconnected"
              && model(.idle, available: false).panelStatus().text == "Waiting for interface"
              && model(.suspended, suspended: true).panelStatus().actions == [.resumeDSP]
              && model(.suspended, available: false, suspended: true).panelStatus().actions.isEmpty
              && model(.needsSelection).panelStatus().text == "Select a profile",
              "Off, missing hardware, selection and paused routing have honest status and only available actions")
    for state in [RuntimeState.idle, .suspended] {
        for mode in [AutomationMode.automatic, .forceOn, .forceOff] {
            let presentation = model(state, mode: mode, available: false, outputUID: "phones")
            try check(presentation.dspStatusText == (mode == .forceOff ? "DSP Off" : "DSP Waiting")
                      && presentation.dspStatusEmphasis == (mode == .forceOff ? .off : .waiting)
                      && presentation.dspError == nil,
                      "Settled DSP Off has distinct red emphasis; actual idle and suspended Waiting use yellow emphasis without inventing failure")
            try check(presentation.routingStatusText == "Direct Output" && presentation.routingStatusEmphasis == .direct,
                      "Observed direct output has yellow emphasis independently of DSP availability or policy")
            try check(NativePanelLayoutVerification.headerMatchesPresentation(presentation),
                      "Native header preserves DSP Off and direct-output emphasis with accessible state labels")
        }
    }
    try check(model(.active("studio"), mode: .forceOff).dspStatusEmphasis == .active
              && model(.stopping("studio"), mode: .forceOff).dspStatusEmphasis == .transition
              && model(.failed("deadline"), mode: .forceOff).dspStatusEmphasis == .error
              && model(.idle, mode: .forceOff, recovering: true).dspStatusEmphasis == .transition,
              "Observed activity, stop, failure and recovery outrank settled Off styling during policy transitions")
    let verifiedOutput = MenuBarPresentation(mode: .automatic, state: .active("studio"), preferredProfileID: "other",
        outputName: "BlackHole 2ch", suspended: false, released: false, recovering: false,
        profiles: [profile(), profile("other")], outputUID: "blackhole", dspPlaybackUID: "clarett", dspPlaybackName: "Clarett+ 8Pre")
    try check(verifiedOutput.systemOutputLine == "System Output: BlackHole 2ch"
              && verifiedOutput.dspOutputLine == "DSP Output: Clarett+ 8Pre",
              "Header distinguishes observed system output from verified DSP playback during profile handoff")
    try check(NativePanelLayoutVerification.headerMatchesPresentation(verifiedOutput),
              "Both native output rows retain full accessible names and help")
    let directOutput = MenuBarPresentation(mode: .forceOn, state: .active("studio"), preferredProfileID: "studio",
        outputName: "Headphones", suspended: false, released: true, recovering: false,
        profiles: [profile()], outputUID: "phones", dspPlaybackUID: "clarett", dspPlaybackName: "Clarett+ 8Pre")
    try check(directOutput.systemOutputLine == "System Output: Headphones" && directOutput.dspOutputLine == verifiedOutput.dspOutputLine,
              "Healthy Direct preserves verified DSP playback while system routing changes")
    try check(NativePanelLayoutVerification.routingSelectedStyleMatchesNative(directOutput),
              "Selected Direct uses orange fill with accessible native segment semantics")
    for state in [RuntimeState.idle, .suspended, .needsSelection, .starting("studio"), .stopping("studio"), .failed("error")] {
        let unverified = MenuBarPresentation(mode: .automatic, state: state, preferredProfileID: "studio", outputName: nil,
            suspended: false, released: false, recovering: false, profiles: [profile()], dspPlaybackUID: "stale", dspPlaybackName: "Stale playback")
        try check(!unverified.dspOutputLine.contains("Stale") && unverified.systemOutputLine == "System Output: Unavailable",
                  "Inactive and transition states never display stale playback as active")
    }
    try check(model(.active("studio")).dspOutputLine == "DSP Output: Unavailable",
              "Older clients without verified playback data do not infer configured output")
    try check(model(.active("studio")).restartDSP.enabled, "Active DSP allows intentional restart")
    let companionOffline = MenuBarPresentation(mode: .forceOn, state: .active("studio"), preferredProfileID: "studio",
        outputName: "Speakers", suspended: false, released: false, recovering: false,
        profiles: [profile(available: false)], automaticSwitching: false)
    try check(companionOffline.dspOn.enabled && !companionOffline.restartDSP.enabled && !companionOffline.refreshAux.enabled &&
              !companionOffline.releaseDSP.enabled && !companionOffline.resumeDSP.enabled &&
              companionOffline.routingStatusText == "Companion Mode" && companionOffline.routingStatusEmphasis == .active &&
              !companionOffline.statusIconDimmed,
              "Companion mode retains DSP On intent offline while blocking device actions and reflecting active DSP status")
    let companionWaiting = MenuBarPresentation(mode: .automatic, state: .idle, preferredProfileID: "studio",
        outputName: "Speakers", suspended: false, released: false, recovering: false,
        profiles: [profile(available: false)], automaticSwitching: false)
    try check(companionWaiting.statusIconDimmed && companionWaiting.panelStatus().text == "Waiting for interface",
              "Companion status icon follows DSP activity while interface availability remains visible")
    try check(NativePanelLayoutVerification.companionControlsAreHidden(companionOffline),
              "Companion panel removes fallback and output routing rows from the control layout")
    try check(model(.active("studio")).releaseDSP.enabled, "Active routing can be released")
    try check(!model(.idle, mode: .forceOff).releaseDSP.enabled, "Off has no routing to release")
    let failedRelease = model(.active("studio"), released: true, outputUID: "blackhole", routingError: "Restore failed")
    try check(failedRelease.statusLine.contains("DSP Active") && failedRelease.context?.contains("failed") == true,
              "Failed restoration must not claim output was restored")
    for state in [RuntimeState.idle, .starting("studio"), .stopping("studio"), .failed("deadline")] {
        try check(!model(state).restartDSP.enabled, "Non-active DSP cannot be restarted from popover")
    }
    try check(model(.failed("deadline")).contextualDSPAction == .retry, "Terminal failure offers Retry")
    try check(model(.starting("studio"), recovering: true).contextualDSPAction == nil, "Bounded recovery hides Retry")
    try check(!model(.active("studio"), recovering: true).restartDSP.enabled, "Recovery cannot have deadline renewed by Restart")
    try check(model(.active("studio")).statusIconDimmed, "Unverified output dims the icon")
    for state in [RuntimeState.idle, .starting("studio"), .stopping("studio"), .failed("deadline"), .suspended] {
        try check(model(state, outputUID: "blackhole").statusIconDimmed, "Unavailable or unverified DSP dims a processed route")
        try check(!model(state).refreshAux.enabled, "Inactive DSP denies Aux refresh with its own availability")
    }
    let processed = model(.active("studio"), outputUID: "blackhole")
    let reconfiguring = MenuBarPresentation(mode: .automatic, state: .active("studio"), preferredProfileID: "studio",
        outputName: "BlackHole", suspended: false, released: false, recovering: false, profiles: [profile()],
        outputUID: "blackhole", reconfiguringAudio: true)
    try check(reconfiguring.dspStatusText == "DSP Reconfiguring" && reconfiguring.dspStatusEmphasis == .transition
              && reconfiguring.statusIconDimmed && !reconfiguring.restartDSP.enabled && !reconfiguring.refreshAux.enabled
              && reconfiguring.panelContext?.contains("reconfiguration") == true,
              "Expected processing restart has truthful transient feedback and disables stale controls")
    let unconfirmedCaptureModels = [
        model(.idle, mode: .forceOff, outputUID: "blackhole"),
        model(.idle, outputUID: "blackhole"),
        model(.needsSelection, outputUID: "blackhole"),
        model(.suspended, mode: .forceOn, suspended: true, outputUID: "blackhole"),
        model(.starting("studio"), outputUID: "blackhole"),
        model(.stopping("studio"), outputUID: "blackhole"),
        model(.failed("deadline"), outputUID: "blackhole"),
        model(.active("studio"), recovering: true, outputUID: "blackhole"),
        model(.active("studio"), outputUID: "blackhole", routingError: "Unconfirmed route"),
        reconfiguring
    ]
    try check(unconfirmedCaptureModels.allSatisfy {
        $0.observedRouting == .processed && !$0.processedRoutingConfirmed
            && $0.routingControlSelection == .unknown && $0.statusIconDimmed
            && $0.routingStatusEmphasis != .active && !$0.routingProcessedHelp.isEmpty
    }, "Capture output remains an observed destination while Off, Waiting, transitions and failures cannot select active Processed routing")
    try check(unconfirmedCaptureModels.filter { $0.routingError == nil }.allSatisfy { $0.routingStatusText == "Output Set to DSP" },
              "Unconfirmed capture destination reports Output Set to DSP rather than active processing")
    try check(model(.idle, mode: .forceOff, outputUID: "blackhole").routingProcessedHelp.contains("DSP is off")
              && model(.idle, outputUID: "blackhole").routingProcessedHelp.contains("DSP is waiting"),
              "Capture-destination help explains Off and Waiting without claiming that audio is processed")
    try check(processed.processedRoutingConfirmed && processed.routingControlSelection == .processed
              && processed.routingProcessedHelp == "Output is currently processed by DSP."
              && !processed.statusIconDimmed,
              "Only verified active processing selects Processed and receives its confirmed help")
    let activePendingOff = model(.active("studio"), mode: .forceOff, outputUID: "blackhole")
    try check(activePendingOff.processedRoutingConfirmed && activePendingOff.routingControlSelection == .processed,
              "Observed active processing remains authoritative while an Off request has not yet stopped the service")
    let directWithoutDSP = model(.idle, mode: .forceOff, outputUID: "phones")
    let pendingDestination = model(.active("studio"), outputUID: "blackhole", routingRestoring: true)
    try check(directWithoutDSP.routingControlSelection == .direct && !directWithoutDSP.processedRoutingConfirmed
              && pendingDestination.routingControlSelection == .pending && !pendingDestination.processedRoutingConfirmed,
              "Direct and pending destinations retain their own control observation independently of DSP state")
    try check(model(.idle).dspStatusEmphasis == .waiting
              && model(.suspended, mode: .forceOn).dspStatusEmphasis == .waiting
              && model(.needsSelection).dspStatusEmphasis == .neutral
              && model(.starting("studio")).dspStatusEmphasis == .transition
              && model(.idle, recovering: true).dspStatusEmphasis == .transition
              && reconfiguring.dspStatusEmphasis == .transition
              && model(.failed("deadline")).dspStatusEmphasis == .error,
              "Waiting emphasis belongs only to actual idle or suspended DSP Waiting, with transitions and errors retaining precedence")
    try check(reconfiguring.panelStatus().text == "Audio reconfiguration in progress"
              && reconfiguring.panelStatus().emphasis == .transition,
              "Permanent status reflects audio reconfiguration without inserting an extra feedback row")
    try check(processed.dspStatusText == "DSP Active" && processed.routingStatusText == "Routing Processed" && processed.routingStatusEmphasis == .active,
              "Verified DSP and processed routing receive separate active status")
    try check(!processed.statusIconDimmed && processed.refreshAux.enabled, "Confirmed active processed DSP has full icon opacity and Aux refresh")
    try check(model(.active("studio"), recovering: true, outputUID: "blackhole").statusIconDimmed,
              "Recovering DSP dims even a capture output")
    try check(!model(.active("studio"), recovering: true).refreshAux.enabled,
              "Recovery disables Aux refresh independently of restart")
    let activeOff = model(.active("studio"), mode: .forceOff)
    try check(!activeOff.refreshAux.enabled && activeOff.refreshAux.reason != nil,
              "Off policy denies Aux refresh even before the observed active state settles")
    let activeSuspended = model(.active("studio"), mode: .forceOn, suspended: true)
    try check(!activeSuspended.refreshAux.enabled && activeSuspended.refreshAux.reason != nil,
              "Suspended authority denies Aux refresh even with a retained active state")
    let bypassedActive = model(.active("studio"), mode: .forceOn, released: true, outputUID: "phones")
    try check(bypassedActive.dspStatusText == "DSP Active" && bypassedActive.routingStatusText == "Routing Bypassed" && bypassedActive.routingStatusEmphasis == .bypassed,
              "Bypass reports DSP running and routing bypassed independently")
    try check(bypassedActive.routingProcessed.enabled && !bypassedActive.routingDirect.enabled,
              "Bypass enables Processed and disables the selected Direct choice")
    try check(NativePanelLayoutVerification.routingSelectionMatchesObservation(bypassedActive),
              "Native Direct selection matches the observed bypass route")
    try check(bypassedActive.statusIconDimmed && bypassedActive.refreshAux.enabled && !bypassedActive.restartDSP.enabled,
              "Bypass dims the icon while healthy Aux refresh remains available")
    try check(NativePanelLayoutVerification.routingReselectionIsInert(processed)
              && NativePanelLayoutVerification.routingReselectionIsInert(bypassedActive),
              "Current routing segments remain enabled and reselecting is inert; alternatives dispatch once without fabricating observation")
    let idleDirect = model(.idle, outputUID: "phones")
    try check(idleDirect.routingStatusText == "Direct Output" && idleDirect.routingStatusEmphasis == .direct,
              "Physical output while DSP is idle is yellow")
    try check(NativePanelLayoutVerification.routingSelectionMatchesObservation(idleDirect),
              "Native Direct selection matches idle physical output")
    let startingRoute = model(.starting("studio"), outputUID: "blackhole")
    try check(startingRoute.routingStatusEmphasis == .transition && startingRoute.routingStatusText == "Output Set to DSP",
              "Unverified DSP route never appears green")
    try check(NativePanelLayoutVerification.routingSelectionMatchesObservation(startingRoute),
              "Native pending selection matches startup routing")
    let restoring = model(.active("studio"), released: true, outputUID: "blackhole", routingRestoring: true)
    try check(restoring.routingStatusText == "Restoring Output" && restoring.routingStatusEmphasis == .transition,
              "Release has a truthful in-progress route label")
    try check(!restoring.routingProcessed.enabled && !restoring.routingDirect.enabled && NativePanelLayoutVerification.routingSelectionMatchesObservation(restoring),
              "Native routing choices disable while release is settling")
    let resuming = model(.active("studio"), outputUID: "phones", routingRestoring: true)
    try check(resuming.routingStatusText == "Resuming Routing" && resuming.routingStatusEmphasis == .transition,
              "Resume has a truthful in-progress route label")
    try check(!resuming.routingProcessed.enabled && !resuming.routingDirect.enabled && NativePanelLayoutVerification.routingSelectionMatchesObservation(resuming),
              "Native routing choices disable while resume is settling")
    let routeFailure = model(.active("studio"), released: true, outputUID: "phones", routingError: "no usable output")
    try check(routeFailure.routingStatusText.contains("Routing Failed") && routeFailure.routingStatusEmphasis == .error,
              "Route restoration errors are distinct from DSP status")
    try check(routeFailure.routingDirect.enabled && routeFailure.routingProcessed.enabled,
              "A failed route restore can be retried or explicitly resumed")
    let released = model(.suspended, mode: .forceOn, suspended: true, released: true)
    try check(released.mode == .forceOn && released.contextualDSPAction == nil && released.resumeDSP.enabled && released.outputRoutingAction == .resume && released.outputRoutingTitle == "Resume Routing", "Release retains On and moves Resume into the existing More entry")
    try check(model(.suspended, available: false, suspended: true, released: true).resumeDSP.enabled == false, "Missing hardware disables Resume")
    try check(model(.suspended, suspended: true).contextualDSPAction == .resume, "Manual suspension offers Resume")
    try check(model(.idle, mode: .forceOff).contextualDSPAction == nil, "Off has no recovery action")
    for mode in [AutomationMode.automatic, .forceOn] {
        let active = model(.active("studio"), mode: mode)
        try check(active.outputRoutingTitle == "Release Output Temporarily" && active.outputRoutingAction == .release && active.outputRoutingAvailability.enabled,
                  "Active routing offers temporary restore in More")
        let stopping = model(.active("studio"), mode: mode, suspended: true, released: true, routingRestoring: true)
        try check(stopping.mode == mode && stopping.outputRoutingTitle == "Releasing Output" && !stopping.outputRoutingAvailability.enabled && stopping.contextualDSPAction == nil,
                  "Restoration retains policy with one disabled pending More entry")
        let restored = model(.suspended, mode: mode, suspended: true, released: true)
        try check(restored.mode == mode && restored.outputRoutingTitle == "Resume Routing" && restored.outputRoutingAvailability.enabled && restored.contextualDSPAction == nil,
                  "Restored output exposes only the existing More Resume entry")
    }
    try check(failedRelease.outputRoutingTitle == "Resume Routing" && failedRelease.outputRoutingAvailability.enabled && failedRelease.contextualDSPAction == nil,
              "Failed restore retains error and the same More Resume entry")
    let missingReleased = model(.suspended, available: false, suspended: true, released: true)
    try check(missingReleased.outputRoutingTitle == "Resume Routing" && !missingReleased.outputRoutingAvailability.enabled && missingReleased.outputRoutingAvailability.reason != nil,
              "Missing hardware disables the same More Resume entry with a reason")
    try check(NativePanelLayoutVerification.compactButtonsKeepSharedGeometry(), "Pin, More, Retry and Dismiss share fixed padded dimensions across titles and states; primary actions retain their wider native layout")
    try check(NativePanelLayoutVerification.controlStyleIsConsistent(), "Selected Off uses a red fill and preserves native accessible labels")
    let renderDirectory = ProcessInfo.processInfo.environment["AUTOSWITCH_PANEL_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    let layoutSamples = try NativePanelLayoutVerification.samples(renderDirectory: renderDirectory)
    try check(layoutSamples.allSatisfy(\.contentFits), "Native panel content fits its measured document after every update")
    let expandedHeight = layoutSamples.first { $0.name == "expanded" }!.documentHeight
    let collapsedHeight = layoutSamples.first { $0.name == "collapsed" }!.documentHeight
    try check(expandedHeight > collapsedHeight, "Expanding Levels measures new native content immediately")
    try check(layoutSamples.filter { $0.name.hasPrefix("busy-") || $0.name.hasPrefix("muted-") }.allSatisfy { $0.documentHeight == expandedHeight && !$0.hasScroller },
              "Repeated busy and mute snapshots retain a stable fitting panel without a scroller")
    try check(layoutSamples.filter { $0.name != "small-screen" }.allSatisfy { !$0.hasScroller },
              "A fitting native panel never enables an overlay scroller")
    try check(layoutSamples.last?.hasScroller == true && layoutSamples.last!.documentHeight > layoutSamples.last!.viewportHeight,
              "Short screens enable scrolling only for actual document overflow")
    let missing = model(.active("studio"))
    try check(!missing.guiControls.enabled && !missing.openWeb.enabled, "Unconfigured GUI disables controls and browser")
    let gui = GUIStatus(profileID: "studio", policy: .automatic, autoStart: true, desiredRunning: true, observed: .failed, url: "http://localhost:5005", lastError: "deadline")
    let failedGUI = MenuBarPresentation(mode: .automatic, state: .active("studio"), preferredProfileID: nil, outputName: nil, suspended: false, released: false, recovering: false, profiles: [profile(gui: gui)])
    try check(failedGUI.contextualGUIAction == .retry && failedGUI.guiPolicy == .automatic, "Failed GUI offers Retry while retaining Auto")
    try check(failedGUI.panelStatus().text == "GUI failed" && !failedGUI.panelStatus().detail.contains("deadline")
              && failedGUI.panelStatus().actions == [.retryGUI]
              && failedGUI.panelStatus(surfacedError: "Fader write failed").actions == [.retryGUI, .dismiss],
              "GUI failure supplies its existing Retry alongside surfaced-error Dismiss in stable order")
    try check(failedGUI.panelStatus(surfacedError: "deadline").text == "GUI failed"
              && failedGUI.panelStatus(surfacedError: "deadline").detail == "deadline"
              && failedGUI.panelStatus(surfacedError: "deadline").actions == [.retryGUI, .dismiss],
              "Surfaced GUI failure retains its domain, full detail and contextual actions")
    try check(model(.idle, released: true, outputUID: "phones").panelStatus().text == "Bypassed routing"
              && model(.suspended, suspended: true, released: true, outputUID: "phones").panelStatus().text == "Bypassed routing",
              "Released idle and suspended sessions report Direct routing without claiming a healthy active DSP")
    let guiRunning = GUIStatus(profileID: "studio", policy: .manualOn, autoStart: true, desiredRunning: true, observed: .running, url: "http://localhost:5005", lastError: nil)
    let guiOnly = MenuBarPresentation(mode: .forceOff, state: .idle, preferredProfileID: "studio", outputName: nil, suspended: false, released: false, recovering: false, profiles: [profile(gui: guiRunning)], outputUID: "blackhole")
    try check(guiOnly.statusIconDimmed, "A running GUI cannot brighten an unavailable DSP icon")
    try check(guiOnly.guiStatusEmphasis == .active && NativePanelLayoutVerification.headerMatchesPresentation(guiOnly),
              "Observed GUI Ready uses the shared green checkmark and bold text even while DSP is off")
    try check(failedGUI.guiStatusEmphasis == .error && NativePanelLayoutVerification.headerMatchesPresentation(failedGUI),
              "Observed GUI Failed header is red with explicit words")
    for observed in [GUIServiceState.stopped, .starting, .stopping] {
        let status = GUIStatus(profileID: "studio", policy: .automatic, autoStart: true, desiredRunning: true, observed: observed,
                               url: "http://localhost:5005", lastError: nil)
        let presentation = MenuBarPresentation(mode: .automatic, state: .idle, preferredProfileID: "studio", outputName: nil,
            suspended: false, released: false, recovering: false, profiles: [profile(gui: status)])
        try check(presentation.guiStatusEmphasis == (observed == .stopped ? .off : .neutral)
                  && NativePanelLayoutVerification.headerMatchesPresentation(presentation),
                  "GUI Off uses Off emphasis, failures retain Error, and transitions remain neutral without relying on color alone")
    }
    func guiModel(_ observed: GUIServiceState) -> MenuBarPresentation {
        let service = GUIStatus(profileID: "studio", policy: .manualOff, autoStart: false,
            desiredRunning: false, observed: observed, url: "http://localhost:5005", lastError: observed == .failed ? "failure" : nil)
        return MenuBarPresentation(mode: .forceOn, state: .active("studio"), preferredProfileID: "studio",
            outputName: "Speakers", suspended: false, released: false, recovering: false,
            profiles: [profile(gui: service)], outputUID: "blackhole")
    }
    try check(guiModel(.stopped).guiStatusEmphasis == .off && guiModel(.failed).guiStatusEmphasis == .error,
              "Intentional GUI Off has its own Off emphasis while an actual GUI failure retains Error")
    try check(guiModel(.stopped).panelStatus().text == "Ready"
              && guiModel(.stopped).panelStatus().emphasis == .active
              && guiModel(.starting).panelStatus().text == "GUI starting"
              && guiModel(.stopping).panelStatus().text == "GUI stopping",
              "Intentional GUI Off permits Ready; observed GUI transitions remain explicit")
    try check(NativePanelLayoutVerification.focusStatusIsConsistent(guiModel(.stopped), failed: guiModel(.failed), stopping: guiModel(.stopping)),
              "Confirmed GUI Off retains its Off symbol, bold words and geometry across focus and appearances; Restart changes only text color")
    let routineModels = [processed, bypassedActive, missingReleased, model(.idle, mode: .forceOff, available: false, outputUID: "phones")]
    try check(routineModels.allSatisfy { $0.panelContext == nil && $0.panelRoutingReason == nil },
              "Routine routing policy and device availability stay out of panel notes")
    try check(missingReleased.context != nil && missingReleased.resumeDSP.reason != nil,
              "Routine explanations remain available in diagnostics and action help")
    try check(NativePanelLayoutVerification.routineFeedbackKeepsLayout(routineModels),
              "Routine processed, released, disconnected and Off snapshots retain native panel height and typed statuses")
    try check(routeFailure.panelContext?.contains("no usable output") == true
              && model(.failed("deadline")).panelContext?.contains("deadline") == true
              && model(.starting("studio"), recovering: true).panelContext != nil
              && restoring.panelContext != nil,
              "Actual routing errors, DSP errors and ongoing recovery or routing transitions retain feedback")
    let multiple = MenuBarPresentation(mode: .automatic, state: .active("studio"), preferredProfileID: "other", outputName: nil, suspended: false, released: false, recovering: false, profiles: [profile(), profile("other")])
    try check(multiple.activeProfileID == "studio" && multiple.preferredProfileID == "other", "Active and preferred profile identities remain distinct")
    try check(!multiple.refreshAux.enabled, "Profile handoff cannot refresh the wrong active profile")
    try check(!multiple.restartDSP.enabled, "Profile handoff cannot restart wrong active profile")
    try check(multiple.panelStatus().text == "Waiting for selected profile"
              && multiple.panelStatus().emphasis == .transition,
              "A profile handoff cannot claim Ready based on the previous active session")
    for command in [ControllerCommand.retry, .release, .resume, .status, .profiles] {
        try check(MenuBarCommandRequest.make(command: command, profileID: "studio").profileID == nil,
                  "Global menu command must omit profile: " + command.rawValue)
    }
    for command in [ControllerCommand.auto, .on, .off, .reconnect] {
        try check(MenuBarCommandRequest.make(command: command, profileID: "studio").profileID == "studio",
                  "Profile menu command must preserve selection: " + command.rawValue)
    }
    let oldStatus = Data(#"{"mode":"automatic","dspState":"idle","suspended":false,"profiles":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(ControllerStatus.self, from: oldStatus)
    try check(decoded.released == nil && decoded.recovering == nil && decoded.routingRestoring == nil && decoded.routingError == nil,
              "Old CLI JSON decodes without new optional fields")
    print("Menu presentation checks: typed policy, observed state, actions and legacy JSON passed")
}
