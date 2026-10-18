import Foundation

public struct ActionAvailability: Sendable {
    public let enabled: Bool
    public let reason: String?
    public init(_ enabled: Bool, reason: String? = nil) { self.enabled = enabled; self.reason = reason }
}

public enum MenuStatusEmphasis: String, Sendable { case neutral, active, off, waiting, direct, bypassed, transition, error }
public enum ObservedRouting: String, Sendable { case processed, direct, pending, unknown }

public enum MenuPanelStatusAction: String, Sendable {
    case resumeDSP, retryDSP, retryGUI, dismiss
    public var title: String {
        switch self {
        case .resumeDSP: return "Resume Routing"
        case .retryDSP: return "Retry DSP"
        case .retryGUI: return "Retry GUI"
        case .dismiss: return "Dismiss"
        }
    }
}

/// One compact status for the permanent panel row. Details remain available without
/// inserting additional rows, and actions retain the controller's existing authority.
public struct MenuPanelStatus: Sendable {
    public let text: String
    public let emphasis: MenuStatusEmphasis
    public let detail: String
    public let actions: [MenuPanelStatusAction]
}

/// A pushed, typed view of accepted policy and observed state. No display-string parsing.
public struct MenuBarPresentation: Sendable {
    public let mode: AutomationMode
    public let state: RuntimeState
    public let preferredProfileID: String?
    public let activeProfileID: String?
    public let profiles: [ControllerProfile]
    public let suspended: Bool
    public let released: Bool
    public let recovering: Bool
    public let reconfiguringAudio: Bool
    public let automaticSwitching: Bool
    public var companionMode: Bool { !automaticSwitching }
    public let routingRestoring: Bool
    public let routingError: String?
    public let observedOutputUID: String?
    public let outputName: String?
    /// Playback identity supplied only by the verified active DSP session.
    public let dspPlaybackUID: String?
    public let dspPlaybackName: String?
    public var selectedProfileID: String? { preferredProfileID ?? activeProfileID ?? (profiles.count == 1 ? profiles.first?.id : nil) }
    public var selectedProfile: ControllerProfile? { profiles.first { $0.id == selectedProfileID } }
    public var observedProfile: ControllerProfile? { profiles.first { $0.id == activeProfileID } ?? selectedProfile }
    public var title: String { profiles.first { $0.id == activeProfileID }?.name ?? selectedProfile?.name ?? "Select a profile" }
    public var guiPolicy: GUIPolicy { selectedProfile?.gui?.policy ?? .automatic }
    public var guiInstallationState: GUIInstallationState {
        selectedProfile?.guiInstallationState ?? (selectedProfile?.gui == nil ? .notConfigured : .configured)
    }
    public var systemOutputLine: String { "System Output: " + (outputName ?? "Unavailable") }
    public var outputLine: String { systemOutputLine }
    public var dspOutputLine: String {
        let value: String
        if recovering { value = "Unavailable (recovering)" }
        else {
            switch state {
            case .active:
                value = dspPlaybackUID != nil ? (dspPlaybackName ?? "Unavailable") : "Unavailable"
            case .starting: value = "Unavailable (starting)"
            case .stopping: value = "Unavailable (stopping)"
            case .failed: value = "Unavailable"
            case .idle, .suspended, .needsSelection: value = "Not running"
            }
        }
        return "DSP Output: " + value
    }
    public var dspError: String? { if case .failed(let reason) = state { return reason }; return nil }
    public var guiError: String? { guiInstallationState == .configured ? selectedProfile?.gui?.lastError : nil }
    public var dspStatusText: String {
        if case .failed = state { return "DSP Failed" }
        if recovering { return "DSP Recovering" }
        if reconfiguringAudio { return "DSP Reconfiguring" }
        switch state {
        case .active: return "DSP Active"
        case .starting: return "DSP Starting"
        case .stopping: return "DSP Stopping"
        case .failed: return "DSP Failed"
        case .suspended: return mode == .forceOff ? "DSP Off" : "DSP Waiting"
        case .needsSelection: return "DSP Needs Selection"
        case .idle: return mode == .forceOff ? "DSP Off" : "DSP Waiting"
        }
    }
    public var dspStatusEmphasis: MenuStatusEmphasis {
        if case .failed = state { return .error }
        if recovering { return .transition }
        if reconfiguringAudio { return .transition }
        switch state {
        case .active: return .active
        case .starting, .stopping: return .transition
        case .failed: return .error
        case .idle, .suspended: return mode == .forceOff ? .off : .waiting
        case .needsSelection: return .neutral
        }
    }
    public var observedRouting: ObservedRouting {
        if routingRestoring { return .pending }
        guard let output = observedOutputUID, let capture = observedProfile?.captureUID else {
            return routingError == nil ? (released ? .direct : .unknown) : .unknown
        }
        return output == capture ? .processed : .direct
    }
    /// The capture destination alone does not establish active processing.
    /// Observed Active remains authoritative while an Off request is settling.
    public var processedRoutingConfirmed: Bool {
        guard case .active = state, !recovering, !reconfiguringAudio,
              !routingRestoring, routingError == nil else { return false }
        return observedRouting == .processed
    }
    /// Control selection distinguishes an output destination from verified audio.
    /// Routing actions retain the separate observed destination and authority.
    public var routingControlSelection: ObservedRouting {
        observedRouting == .processed && !processedRoutingConfirmed ? .unknown : observedRouting
    }
    public var routingProcessedHelp: String {
        if processedRoutingConfirmed { return "Output is currently processed by DSP." }
        guard observedRouting == .processed else {
            return routingProcessed.reason ?? "Route output through DSP without restarting a healthy service."
        }
        let detail: String
        if recovering { detail = "Wait for DSP recovery to finish." }
        else if reconfiguringAudio { detail = "Wait for audio reconfiguration to finish." }
        else {
            switch state {
            case .active: detail = "Processing has not been confirmed."
            case .starting: detail = "Wait for DSP startup to finish."
            case .stopping: detail = "DSP is stopping."
            case .failed: detail = "DSP failed and is not processing audio."
            case .idle, .suspended:
                detail = mode == .forceOff ? "DSP is off." : "DSP is waiting and is not processing audio."
            case .needsSelection: detail = "Select a profile before starting DSP."
            }
        }
        return "Output is set to DSP. " + detail
    }
    /// Only confirmed DSP audio through the capture device receives full opacity.
    public var statusIconDimmed: Bool {
        if companionMode {
            guard case .active = state else { return true }
            return recovering || reconfiguringAudio
        }
        return !processedRoutingConfirmed
    }
    public var routingStatusText: String {
        if companionMode { return "Companion Mode" }
        if routingRestoring { return released ? "Restoring Output" : "Resuming Routing" }
        if let routingError { return "Routing Failed: \(routingError)" }
        switch observedRouting {
        case .processed:
            return processedRoutingConfirmed ? "Routing Processed" : "Output Set to DSP"
        case .direct:
            return released ? "Routing Bypassed" : "Direct Output"
        case .pending: return "Routing Pending"
        case .unknown: return "Routing Unknown"
        }
    }
    public var routingStatusEmphasis: MenuStatusEmphasis {
        if companionMode { return .active }
        if routingRestoring { return .transition }
        if routingError != nil { return .error }
        switch observedRouting {
        case .processed: return processedRoutingConfirmed ? .active : dspStatusEmphasis
        case .direct: return released ? .bypassed : .direct
        case .pending: return .transition
        case .unknown: return .neutral
        }
    }
    public var guiStatusText: String {
        if let label = guiInstallationState.unavailableLabel { return "GUI " + label }
        guard let service = selectedProfile?.gui else { return "GUI Unavailable" }
        if service.recovering == true { return "GUI Recovering" }
        switch service.observed {
        case .running: return "GUI Ready"
        case .starting: return "GUI Starting"
        case .stopping: return "GUI Stopping"
        case .stopped: return "GUI Off"
        case .failed: return "GUI Failed"
        }
    }
    public var guiStatusEmphasis: MenuStatusEmphasis {
        guard guiInstallationState == .configured else { return .neutral }
        guard let service = selectedProfile?.gui, service.recovering != true else { return .neutral }
        switch service.observed {
        case .running: return .active
        case .stopped: return .off
        case .failed: return .error
        case .starting, .stopping: return .neutral
        }
    }
    public var statusLine: String { dspStatusText + " · " + guiStatusText }
    public var context: String? {
        if let routingError { return "Output routing failed: \(routingError)" }
        if let dspError { return "DSP failed: \(dspError)" }
        if reconfiguringAudio { return "Audio reconfiguration is in progress." }
        if released {
            if routingRestoring { return "Restoring the previous output." }
            if case .active = state { return "DSP remains running while routing is bypassed." }
            if case .suspended = state { return "Output is restored temporarily. Resume routing when the required devices are available." }
            return "Routing is bypassed."
        }
        if suspended { return "Routing paused after an output change. Resume restores the retained DSP policy." }
        if recovering { return "Recovery is in progress." }
        if selectedProfile?.available == false { return "Waiting for the required audio devices." }
        if selectedProfileID == nil { return "Choose a profile to enable DSP or GUI controls." }
        return selectedProfile?.guiUnavailableReason
    }
    /// Compact panel feedback omits routine policy and availability explanations.
    /// The full context remains available to diagnostics and command help.
    public var panelContext: String? {
        if let routingError { return "Output routing failed: \(routingError)" }
        if let dspError { return "DSP failed: \(dspError)" }
        if reconfiguringAudio { return "Audio reconfiguration is in progress." }
        if recovering { return "Recovery is in progress." }
        if routingRestoring { return "Output routing is in progress." }
        return nil
    }
    public var panelRoutingReason: String? {
        guard recovering || routingRestoring || routingError != nil || dspError != nil else { return nil }
        switch observedRouting {
        case .processed: return routingDirect.enabled ? nil : routingDirect.reason
        case .direct: return routingProcessed.enabled ? nil : routingProcessed.reason
        case .pending, .unknown: return routingProcessed.reason ?? routingDirect.reason
        }
    }
    public func panelStatus(surfacedError: String? = nil) -> MenuPanelStatus {
        let localError = surfacedError.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        var actions: [MenuPanelStatusAction] = []
        if contextualDSPAction == .resume && resumeDSP.enabled { actions.append(.resumeDSP) }
        if contextualDSPAction == .retry && retryDSP.enabled { actions.append(.retryDSP) }
        if contextualGUIAction == .retry && retryGUI.enabled { actions.append(.retryGUI) }
        if localError != nil { actions.append(.dismiss) }
        func status(_ text: String, _ emphasis: MenuStatusEmphasis, _ detail: String? = nil) -> MenuPanelStatus {
            MenuPanelStatus(text: text, emphasis: emphasis, detail: detail ?? text, actions: actions)
        }
        // A surfaced failure must not be replaced by a routine pushed update.
        // Match exact model detail so passive service failures keep their domain;
        // unrelated command and Aux failures remain action failures.
        if let localError {
            let text: String
            if localError == routingError { text = "Output routing failed" }
            else if localError == dspError { text = "DSP failed" }
            else if localError == guiError { text = "GUI failed" }
            else { text = "Action failed" }
            return status(text, .error, localError)
        }
        // Only the caller's surfaced error carries full failure detail. Dismissing
        // it may retain an honest failed state, but must not resurrect the detail.
        if routingError != nil { return status("Output routing failed", .error) }
        if dspError != nil { return status("DSP failed", .error) }
        if guiInstallationState == .configured && selectedProfile?.gui?.observed == .failed && selectedProfile?.gui?.recovering != true {
            return status("GUI failed", .error)
        }
        if reconfiguringAudio { return status("Audio reconfiguration in progress", .transition) }
        if recovering { return status("DSP recovery in progress", .transition) }
        if routingRestoring { return status("Output routing in progress", .transition) }
        switch state {
        case .starting: return status("DSP starting", .transition)
        case .stopping: return status("DSP stopping", .transition)
        default: break
        }
        if selectedProfile == nil || state == .needsSelection {
            return status("Select a profile", .neutral, "Choose a profile to enable DSP or GUI controls.")
        }
        if mode == .forceOff {
            if selectedProfile?.available == false {
                return status("Interface disconnected", .neutral, companionMode
                    ? "DSP is off. Reconnect the interface, then select On to start."
                    : "DSP is off. Reconnect the interface, then select On or Auto to start.")
            }
            return status("DSP off", .neutral, "DSP is disabled by the selected policy.")
        }
        if selectedProfile?.available == false {
            return status("Waiting for interface", .neutral, "Waiting for the required audio devices.")
        }
        if suspended && !released {
            return status("Routing paused", .neutral, "Routing paused after an output change. Resume restores the retained DSP policy.")
        }
        if released {
            return status("Bypassed routing", .neutral, context ?? "Routing is intentionally bypassed.")
        }
        guard case .active(let id) = state else { return status("Waiting for DSP", .neutral) }
        guard id == selectedProfileID else { return status("Waiting for selected profile", .transition) }
        if guiInstallationState == .configured && selectedProfile?.gui?.recovering == true { return status("GUI recovery in progress", .transition) }
        switch guiInstallationState == .configured ? selectedProfile?.gui?.observed : nil {
        case .starting: return status("GUI starting", .transition)
        case .stopping: return status("GUI stopping", .transition)
        default: break
        }
        if companionMode { return status("DSP ready", .active) }
        switch observedRouting {
        case .processed: return status("Ready", .active)
        case .direct: return status("Bypassed routing", .neutral)
        case .pending: return status("Output routing in progress", .transition)
        case .unknown: return status("Routing unavailable", .neutral, "The system output routing has not been verified.")
        }
    }
    public var guiConfirmedOff: Bool {
        guiInstallationState == .configured && selectedProfile?.gui?.observed == .stopped && selectedProfile?.gui?.recovering != true
    }
    public var dspOn: ActionAvailability { ActionAvailability(selectedProfile != nil && (companionMode || selectedProfile?.available == true), reason: selectedProfile == nil ? "Select a profile" : selectedProfile?.available == false && !companionMode ? "Required audio devices unavailable" : nil) }
    public var guiControls: ActionAvailability {
        let reason = guiInstallationState.unavailableLabel.map { "CamillaGUI: " + $0 }
            ?? selectedProfile?.guiUnavailableReason ?? (selectedProfile?.gui == nil ? "GUI not configured for this profile" : nil)
        return ActionAvailability(reason == nil, reason: reason)
    }
    public var openWeb: ActionAvailability { ActionAvailability(guiControls.enabled && selectedProfile?.gui?.observed == .running, reason: guiControls.reason ?? (selectedProfile?.gui?.observed != .running ? "Web interface is not ready" : nil)) }
    public var restartDSP: ActionAvailability {
        let reason: String?
        if reconfiguringAudio { reason = "Wait for audio reconfiguration to finish" }
        else if recovering { reason = "Wait for recovery to finish" }
        else if mode == .forceOff { reason = companionMode ? "Select DSP On" : "Select DSP Auto or On" }
        else if suspended || released { reason = "Resume routing first" }
        else if case .active(let id) = state { reason = id != selectedProfileID ? "Wait for the selected profile to become active" : (companionMode && selectedProfile?.available != true ? "Required audio devices unavailable" : dspOn.reason) }
        else { reason = "Wait for DSP to become active" }
        return ActionAvailability(reason == nil, reason: reason)
    }
    /// Aux reads remain available while a healthy service is bypassed.
    public var refreshAux: ActionAvailability {
        let reason: String?
        if reconfiguringAudio { reason = "Wait for audio reconfiguration to finish" }
        else if recovering { reason = "Wait for recovery to finish" }
        else if mode == .forceOff { reason = companionMode ? "Select DSP On" : "Select DSP Auto or On" }
        else if suspended { reason = "Resume routing first" }
        else if routingRestoring { reason = "Wait for output routing to finish" }
        else if case .active(let id) = state {
            reason = id != selectedProfileID ? "Wait for the selected profile to become active" : (companionMode && selectedProfile?.available != true ? "Required audio devices unavailable" : dspOn.reason)
        } else { reason = "Wait for DSP to become active" }
        return ActionAvailability(reason == nil, reason: reason)
    }
    public var contextualDSPAction: ControllerCommand? {
        if companionMode { return nil }
        if released {
            if dspError != nil && !recovering && mode != .forceOff && selectedProfile?.available == true { return .retry }
            return nil
        }
        if suspended { return mode == .forceOff ? nil : .resume }
        if dspError != nil && !recovering && mode != .forceOff && selectedProfile?.available == true { return .retry }
        return nil
    }
    public var retryDSP: ActionAvailability { ActionAvailability(contextualDSPAction == .retry) }
    public var releaseDSP: ActionAvailability {
        if companionMode { return ActionAvailability(false, reason: "Output routing is unavailable in Companion Mode") }
        if routingRestoring { return ActionAvailability(false, reason: "Wait for output routing to finish") }
        if released, routingError != nil, !suspended, mode != .forceOff {
            if case .active = state { return ActionAvailability(true) }
        }
        guard !released, !suspended, mode != .forceOff else {
            return ActionAvailability(false, reason: "Routing is already stopped or paused")
        }
        switch state {
        case .active: return ActionAvailability(true)
        default: return ActionAvailability(false, reason: "No active routing to release")
        }
    }
    /// The first More entry keeps its position throughout temporary output release.
    public var outputRoutingAction: ControllerCommand { released ? .resume : .release }
    public var outputRoutingTitle: String {
        if routingRestoring { return released ? "Releasing Output" : "Resuming Routing…" }
        return released ? "Resume Routing" : "Release Output Temporarily"
    }
    public var outputRoutingAvailability: ActionAvailability { released ? resumeDSP : releaseDSP }
    public var resumeDSP: ActionAvailability {
        if companionMode { return ActionAvailability(false, reason: "Output routing is unavailable in Companion Mode") }
        if routingRestoring { return ActionAvailability(false, reason: "Wait for output routing to finish") }
        let canResume = (suspended || released) && mode != .forceOff
        return ActionAvailability(canResume && dspOn.enabled, reason: canResume ? dspOn.reason : "Routing is not paused")
    }
    public var contextualGUIAction: GUICommand? { selectedProfile?.gui?.observed == .failed && selectedProfile?.gui?.recovering != true && guiControls.enabled ? .retry : nil }
    public var retryGUI: ActionAvailability { ActionAvailability(contextualGUIAction == .retry) }
    public var routingProcessed: ActionAvailability { resumeDSP }
    public var routingDirect: ActionAvailability { releaseDSP }

    public init(mode: AutomationMode, state: RuntimeState, preferredProfileID: String?, outputName: String?, suspended: Bool, released: Bool, recovering: Bool, profiles: [ControllerProfile], outputUID: String? = nil, routingRestoring: Bool = false, routingError: String? = nil, dspPlaybackUID: String? = nil, dspPlaybackName: String? = nil, reconfiguringAudio: Bool = false, automaticSwitching: Bool = true) {
        self.mode = mode; self.state = state; self.preferredProfileID = preferredProfileID
        self.reconfiguringAudio = reconfiguringAudio
        self.automaticSwitching = automaticSwitching
        switch state { case .active(let id), .starting(let id), .stopping(let id): activeProfileID = id; default: activeProfileID = nil }
        self.dspPlaybackUID = dspPlaybackUID; self.dspPlaybackName = dspPlaybackName
        self.outputName = outputName; self.suspended = suspended; self.released = released; self.recovering = recovering; self.profiles = profiles
        self.observedOutputUID = outputUID; self.routingRestoring = routingRestoring; self.routingError = routingError
    }
}
