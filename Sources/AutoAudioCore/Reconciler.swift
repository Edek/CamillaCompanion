import Foundation

/// Event-driven in stable operation; transient failures have one bounded recovery window.
@MainActor public final class Reconciler {
    public private(set) var state: RuntimeState = .idle {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    public var onFeedback: ((FeedbackEvent) -> Void)?
    public var onSnapshot: ((AudioSnapshot) -> Void)?
    /// A normal output selected outside this controller while hardware is stable.
    /// The application decides whether to persist it as a fallback target.
    public var onExternalOutputSelection: ((String, AudioDevice) -> Void)?
    public var onStateChange: ((RuntimeState) -> Void)?
    private let profiles: [Profile]
    private let routingPolicy: OutputRoutingPolicy
    private let workAuthority = ReconcilerWorkAuthority()
    private let audio: AudioManaging
    private let dsp: DSPManaging
    private let store: RouteStoring
    private let sleeper: TransitionSleeping
    private let now: () -> TimeInterval
    private let log: (String) -> Void
    public private(set) var mode: AutomationMode = .automatic
    public private(set) var selectedID: String?
    private var record: RouteRecord?
    private var managed: Profile?
    private var initialRecovery = true
    private var lastDevices: [AudioDevice] = []
    private var lastOutputUID: String?
    private var lastPhysicalOutputUID: String?
    public private(set) var fallbackPreferences: FallbackOutputPreferences
    private var handlingDisconnectFallback = false
    private var assigningOutput = false
    /// CoreAudio may deliver device and default-output notifications in either
    /// order. Keep their availability edge grouped until reconciliation settles.
    private var outputSelectionHardwareTransition = false
    /// Explicit policy actions retain restoration even when hardware is absent.
    /// Passive loss teardown can instead relinquish routes for Fallback Off.
    private typealias TeardownReason = OutputRoutingPolicy.TeardownReason
    /// Manual On ends on hardware loss. Repeated notifications must not retry
    /// its teardown or reinterpret the loss as an explicit user-Off action.
    private var manualDeviceLossProfileID: String?
    /// One passive loss consumes its cleanup attempt until hardware returns or
    /// an explicit command retries. Preserve the original availability predicate
    /// when manual On becomes Off after loss.
    private var consumedDeviceLoss: (profileID: String, requireTrigger: Bool)?
    private var bypassedActivationProfile: Profile?
    private var requestedOutputProfileID: String?
    private var preserveManualVirtualStartup = false
    private var startingOutputUID: String?
    public private(set) var suspended = false { didSet { if oldValue != suspended { onControlChange?() } } }
    public private(set) var released = false { didSet { if oldValue != released { onControlChange?() } } }
    public private(set) var routingRestoring = false { didSet { if oldValue != routingRestoring { onControlChange?() } } }
    public private(set) var routingError: String? { didSet { if oldValue != routingError { onControlChange?() } } }
    public private(set) var automaticSwitching: Bool
    private var routingSession: (mode: AutomationMode, selectedID: String?)?
    private var pendingRouteRelinquishment = false
    private var companionCleanupConsumed = false
    private var switchingTransitionPending = false
    private var reconnectPending = false
    public var onControlChange: (() -> Void)?
    private var fault: String?
    private var exhaustedProfile: Profile?
    public private(set) var dspControlBusy = false {
        didSet { if oldValue != dspControlBusy { onControlChange?() } }
    }
    public var processingReconfiguration: Bool { dspControlBusy && workAuthority.dspControlAllowsRestart }
    private enum RecoveryKind { case starting, unavailable }
    private struct Recovery {
        let profile: Profile
        let deadline: TimeInterval
        var kind: RecoveryKind
        var unavailableAttempt = 0
        var expectedOutputUID: String?
    }
    public var recovering: Bool { recovery != nil }
    /// Interactive DSP controls share the lifecycle authority, without a second watcher.
    public func permitsDSPControls(profileID: String) -> Bool {
        !dspControlBusy && hasDSPAuthority(profileID: profileID)
    }
    private func hasDSPAuthority(profileID: String) -> Bool {
        guard !workAuthority.isShuttingDown, !switchingTransitionPending, !suspended, !reconnectPending,
              !recovering, mode != .forceOff,
              selectedID == nil || selectedID == profileID,
              case .active(let activeID) = state else { return false }
        return activeID == profileID
    }
    /// An unverified configuration restoration follows the same route safety and
    /// bounded service recovery path as a passive DSP transport failure.
    public func reportDSPFailure(profileID: String, reason: String) {
        guard !workAuthority.isShuttingDown, managed?.id == profileID else { return }
        dsp.onFailure?(reason)
    }
    /// One finite mutation owns DSP authority. Lifecycle changes cancel its work
    /// and await completion before starting/stopping or handing off a service.
    public func performDSPControl<T: Sendable>(profileID: String,
        allowsProcessingRestart: Bool = false,
        operation: @escaping @MainActor () async throws -> T) async throws -> T {
        guard permitsDSPControls(profileID: profileID) else {
            throw SwitcherError.message("DSP is unavailable or another DSP command is active.")
        }
        let reservation = workAuthority.reserveDSPControl(allowsProcessingRestart: allowsProcessingRestart)
        let token = reservation.token
        let id = reservation.id
        let priorTransition = reservation.priorTransition
        let priorRecovery = reservation.priorRecovery
        dspControlBusy = true
        let work = Task { @MainActor in
            await priorTransition?.value
            await priorRecovery?.value
            try Task.checkCancellation()
            guard self.current(token), self.hasDSPAuthority(profileID: profileID) else { throw CancellationError() }
            let result: T
            do { result = try await operation() }
            catch {
                // A verified rollback is still ready and needs the passive socket
                // rearmed if the expected processing transition interrupted it.
                if !(error is DSPFailure), !(error is CancellationError), !Task.isCancelled {
                    try await self.rearmDSPObservation(profileID: profileID, token: token)
                }
                throw error
            }
            try Task.checkCancellation()
            guard self.current(token), self.hasDSPAuthority(profileID: profileID) else { throw CancellationError() }
            try await self.rearmDSPObservation(profileID: profileID, token: token)
            return result
        }
        var timedOut = false
        // Includes Aux drain, transport validation/recovery, and at most five
        // seconds to rearm passive observation. Preset IPC allows 60s including
        // catalog preflight and the final control readback outside this lease.
        let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 28_000_000_000) } catch { return }
            timedOut = true; work.cancel()
        }
        workAuthority.installDSPControl(cancel: { work.cancel() }, drain: { Task { _ = await work.result } })
        defer {
            deadline.cancel()
            if workAuthority.finishDSPControl(id: id) {
                dspControlBusy = false
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard current(token), hasDSPAuthority(profileID: profileID) else { throw CancellationError() }
            // A delegate may run after the worker's rearm finishes but before
            // this awaiting task resumes. No actor yield follows this check.
            try validateHeldDSPFailure(token: token)
            return result
        } catch {
            if timedOut, current(token) {
                throw DSPFailure.unavailable("DSP reconfiguration reached its time limit; readiness was not verified.")
            }
            if !(error is CancellationError), !Task.isCancelled { try validateHeldDSPFailure(token: token) }
            throw error
        }
    }
    private func rearmDSPObservation(profileID: String, token: Int) async throws {
        try Task.checkCancellation()
        guard current(token), hasDSPAuthority(profileID: profileID) else { throw CancellationError() }
        guard workAuthority.dspControlAllowsRestart, let profile = managed, profile.id == profileID else { return }
        // Every expected restart replaces the old passive socket, even when its
        // delayed failure callback has not arrived. New callbacks are retained.
        workAuthority.clearHeldDSPFailure()
        do { try await dsp.verifyReadiness(profile) }
        catch {
            if Task.isCancelled || !current(token) { throw CancellationError() }
            throw DSPFailure.unavailable("DSP readiness after audio reconfiguration could not be verified: " + error.localizedDescription)
        }
        try Task.checkCancellation()
        guard current(token), hasDSPAuthority(profileID: profileID) else { throw CancellationError() }
        try validateHeldDSPFailure(token: token)
    }
    private func validateHeldDSPFailure(token: Int) throws {
        guard current(token), workAuthority.dspControlAllowsRestart, let failure = workAuthority.deferredDSPFailure else { return }
        throw DSPFailure.unavailable("DSP observation failed after audio reconfiguration: " + failure)
    }
    private var recovery: Recovery? { didSet { onControlChange?() } }

    public init(profiles: [Profile], audio: AudioManaging, dsp: DSPManaging,
                store: RouteStoring, sleeper: TransitionSleeping? = nil,
                fallbackPreferences: FallbackOutputPreferences = .init(),
                automaticSwitching: Bool = true, companionMode: AutomationMode = .automatic,
                companionProfileID: String? = nil,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                log: @escaping (String) -> Void = { _ in }) {
        self.profiles = profiles; self.audio = audio; self.dsp = dsp
        self.routingPolicy = OutputRoutingPolicy(managedFeedUIDs: Set(profiles.compactMap(\.managedFeedUID)))
        self.store = store; self.sleeper = sleeper ?? TaskSleeper(); self.now = now; self.log = log
        self.fallbackPreferences = fallbackPreferences
        self.automaticSwitching = automaticSwitching
        if !automaticSwitching {
            mode = companionMode
            selectedID = CompanionSessionPolicy.selectedProfileID(companionProfileID, profiles: profiles)
            pendingRouteRelinquishment = true
            switchingTransitionPending = true
        }
    }

    /// Routing and companion sessions share serialized work, never output authority.
    /// Entry relinquishes owned routes without changing the selected outputs.
    /// Persistence failure is surfaced once and never retried by companion events.
    public func setAutomaticSwitching(_ enabled: Bool, companionMode: AutomationMode = .automatic,
                                     profileID: String? = nil) throws {
        guard !workAuthority.isShuttingDown, enabled != automaticSwitching else { return }
        if !enabled, let profileID, !profiles.contains(where: { $0.id == profileID }) {
            throw SwitcherError.message("Unknown companion profile: \(profileID)")
        }
        cancelRecovery()
        if enabled {
            automaticSwitching = true
            if let routingSession { mode = routingSession.mode; selectedID = routingSession.selectedID }
            routingSession = nil
            pendingRouteRelinquishment = false
        } else {
            routingSession = (mode, selectedID)
            automaticSwitching = false
            selectedID = CompanionSessionPolicy.selectedProfileID(profileID ?? managed?.id ?? selectedID, profiles: profiles)
            mode = companionMode
            pendingRouteRelinquishment = true
        }
        switchingTransitionPending = true
        companionCleanupConsumed = false
        consumedDeviceLoss = nil; manualDeviceLossProfileID = nil
        released = false; suspended = false; routingRestoring = false; routingError = nil
        reconnectPending = false; exhaustedProfile = nil; fault = nil
        bypassedActivationProfile = nil; requestedOutputProfileID = nil
        onControlChange?()
        enqueue(debounce: false, reason: .policyAction)
    }

    public func fallbackPreference(profileID: String) -> FallbackOutputPreference {
        fallbackPreferences.preference(profileID: profileID)
    }
    public func validateFallbackPreference(_ preference: FallbackOutputPreference, profileID: String,
                                           requireManualSelection: Bool = true) throws {
        _ = try preference.validated()
        guard profiles.contains(where: { $0.id == profileID }) else {
            throw SwitcherError.message("Fallback settings require a configured profile.")
        }
        if let uid = preference.outputUID, routingPolicy.managedFeedUIDs.contains(uid) {
            throw SwitcherError.message("A managed system-feed device cannot be a fallback output.")
        }
        if requireManualSelection, preference.mode == .manual,
           preference.outputSelection != .device || preference.outputUID == nil {
            throw SwitcherError.message("Choose an output for Force fallback.")
        }
    }
    /// Saving preferences does not change the current output. Missing saved devices
    /// are retained and normal restoration alternatives remain available.
    public func setFallbackPreference(_ preference: FallbackOutputPreference, profileID: String) throws {
        try validateFallbackPreference(preference, profileID: profileID)
        fallbackPreferences.profiles[profileID] = preference
        onControlChange?()
    }
    public func eligibleFallbackOutputs() throws -> [AudioDevice] {
        routingPolicy.eligibleOutputs(in: try audio.snapshot())
    }
    /// A presentation hint derived only from an existing event snapshot and
    /// owned return route. It never probes or changes CoreAudio output.
    public func suggestedAutomaticFallbackOutput(profileID: String, snapshot: AudioSnapshot) -> AudioDevice? {
        guard profiles.contains(where: { $0.id == profileID }) else { return nil }
        let outputs = routingPolicy.eligibleOutputs(in: snapshot)
        let previousUID: String?
        if let saved = record, saved.profileID == profileID, saved.ownsOutput,
           snapshot.outputUID == saved.captureUID { previousUID = saved.previousOutputUID }
        else {
            previousUID = outputs.first(where: { $0.uid == snapshot.outputUID })?.uid
                ?? outputs.first(where: { $0.uid == lastPhysicalOutputUID })?.uid
        }
        return routingPolicy.restorationOutputs(previousUID: previousUID, snapshot: snapshot).first
    }

    public func start() throws {
        _ = try fallbackPreferences.validated()
        for (id, preference) in fallbackPreferences.profiles where profiles.contains(where: { $0.id == id }) {
            // Legacy Manual-without-output stays readable. Edges report Choose
            // Output rather than inventing a selected device or blocking startup.
            try validateFallbackPreference(preference, profileID: id, requireManualSelection: false)
        }
        record = try store.load()
        let initial = try audio.snapshot()
        onSnapshot?(initial)
        lastDevices = initial.devices
        rememberObservedOutput(initial)
        if automaticSwitching, record == nil, let orphan = profiles.first(where: {
            guard let feedUID = $0.managedFeedUID else { return false }
            return initial.outputUID == feedUID || ($0.routeAlerts && initial.alertUID == feedUID)
        }), let feedUID = orphan.managedFeedUID {
            record = RouteRecord(profileID: orphan.id, captureUID: feedUID,
                                 previousOutputUID: nil, previousAlertUID: nil,
                                 ownsOutput: initial.outputUID == feedUID,
                                 ownsAlerts: orphan.routeAlerts && initial.alertUID == feedUID)
            try store.save(record)
        }
        if let record { managed = profiles.first { $0.id == record.profileID } }
        dsp.onFailure = { [weak self] message in
            guard let self, !self.workAuthority.isShuttingDown else { return }
            if self.dspControlBusy, self.workAuthority.dspControlAllowsRestart {
                self.workAuthority.holdDSPFailure(message)
                self.log("DSP observation interrupted during the owned audio reconfiguration; readiness remains under its finite lease")
                return
            }
            // A requested policy teardown already owns the serialized work.
            // A late socket failure must not reinterpret that action as loss.
            if self.mode == .forceOff || self.workAuthority.hasPendingPolicyAction || (self.released && self.routingRestoring) { return }
            if !self.automaticSwitching {
                self.fault = message
                self.enqueue(debounce: false)
                return
            }
            switch self.state {
            case .starting, .active:
                guard self.recovery == nil, let profile = self.managed else { return }
                if let snapshot = try? self.audio.snapshot(),
                   !self.available(profile, in: snapshot, requireTrigger: self.mode != .forceOn) {
                    self.prepareDeviceLoss(snapshot)
                    return
                }
                self.fault = message
                self.workAuthority.interruptForRecovery()
                do {
                    try self.restoreRoutes()
                    let output = try self.audio.snapshot().outputUID
                    self.beginRecovery(profile, kind: .unavailable, expectedOutputUID: output)
                } catch {
                    self.fault = error.localizedDescription
                    self.state = .failed(error.localizedDescription)
                }
            default: break
            }
        }
        try audio.startMonitoring { [weak self] event in self?.handle(event) }
        enqueue(debounce: false)
    }

    public func handle(_ event: AudioEvent) {
        guard !workAuthority.isShuttingDown, !handlingDisconnectFallback else { return }
        log("Audio event: \(event)")
        if !automaticSwitching { handleCompanionEvent(event); return }
        do {
            var snapshot = try audio.snapshot()
            observeOutputSelectionHardwareEdge(snapshot)
            if let loss = consumedDeviceLoss,
               let profile = profiles.first(where: { $0.id == loss.profileID }) {
                let before = AudioSnapshot(devices: lastDevices, outputUID: nil, alertUID: nil)
                let anotherProfileArrived = mode == .automatic && profiles.contains { candidate in
                    candidate.id != loss.profileID && automaticSelectionAllows(candidate, in: snapshot)
                        && (candidate.autoActivate || selectedID == candidate.id)
                        && !available(candidate, in: before, requireTrigger: true)
                        && available(candidate, in: snapshot, requireTrigger: true)
                }
                if !available(profile, in: snapshot, requireTrigger: loss.requireTrigger),
                   managed == nil || managed?.id == loss.profileID, !anotherProfileArrived {
                    lastDevices = snapshot.devices
                    onSnapshot?(snapshot)
                    rememberObservedOutput(snapshot)
                    return
                }
                consumedDeviceLoss = nil
            }
            if mode == .forceOff, let id = manualDeviceLossProfileID,
               let profile = profiles.first(where: { $0.id == id }),
               !available(profile, in: snapshot, requireTrigger: false) {
                lastDevices = snapshot.devices
                onSnapshot?(snapshot)
                rememberObservedOutput(snapshot)
                return
            }
            if let profile = manualFallbackEdgeProfile(snapshot) {
                if !workAuthority.hasPendingPolicyAction {
                    if available(profile, in: snapshot,
                                 requireTrigger: mode != .forceOn && manualDeviceLossProfileID != profile.id) {
                        prepareManualReconnect(profile, snapshot: snapshot)
                    } else { prepareDeviceLoss(snapshot, profile: profile) }
                    return
                }
                // An explicit Off/Bypassed action already owns this transition.
                // Consume the edge without changing that action's route policy.
                lastDevices = snapshot.devices
            }
            onSnapshot?(snapshot)
            let outputChanged = snapshot.outputUID != lastOutputUID
            if outputChanged, let outputUID = snapshot.outputUID,
               !profiles.contains(where: { $0.managedFeedUID == outputUID }) {
                reportOutput(snapshot, restored: false)
            }
            defer { rememberObservedOutput(snapshot) }
            let hardwareLost = managed.map { !available($0, in: snapshot, requireTrigger: mode != .forceOn) } ?? false
            // Required device loss always schedules lifecycle teardown, even if
            // synchronous fallback just consumed the route ownership record.
            if hardwareLost {
                if mode == .forceOff || (released && routingRestoring) {
                    cancelRecovery()
                    lastDevices = snapshot.devices
                    enqueue(debounce: false, reason: .policyAction)
                } else {
                    prepareDeviceLoss(snapshot, publishSnapshot: false)
                    // Restoration may have changed Auto/Manual output; the
                    // outer observed-output defer must retain that final route.
                    snapshot = try audio.snapshot()
                }
                return
            }
            if case .outputChanged = event, outputChanged {
                reportExternalOutputSelection(snapshot)
            }
            if let recovery {
                switch event {
                case .devicesChanged:
                    lastDevices = snapshot.devices
                    if hardwareLost {
                        cancelRecovery()
                        fault = nil
                        enqueue(debounce: false)
                    }
                    return
                case .outputChanged:
                    if released {
                        self.recovery?.expectedOutputUID = snapshot.outputUID
                        return
                    }
                    if snapshot.outputUID != recovery.expectedOutputUID {
                        cancelRecovery()
                        suspended = true
                        fault = nil
                        enqueue(debounce: false)
                    }
                    return
                case .woke:
                    return
                }
            }
            if case .woke = event, exhaustedProfile == nil { fault = nil }
            if case .devicesChanged = event, snapshot.devices != lastDevices {
                let before = AudioSnapshot(devices: lastDevices, outputUID: nil, alertUID: nil)
                let reconnected = profiles.contains { profile in
                    automaticSelectionAllows(profile, in: snapshot) && profile.autoActivate
                    && !available(profile, in: before, requireTrigger: true)
                    && available(profile, in: snapshot, requireTrigger: true)
                }
                if mode == .automatic && reconnected {
                    suspended = false
                    released = false
                    requestedOutputProfileID = nil
                    log("Configured interface reconnected; resuming automatic routing")
                }
                if let blocked = exhaustedProfile {
                    let before = AudioSnapshot(devices: lastDevices, outputUID: nil, alertUID: nil)
                    if !available(blocked, in: before, requireTrigger: mode != .forceOn),
                       available(blocked, in: snapshot, requireTrigger: mode != .forceOn) {
                        exhaustedProfile = nil
                        fault = nil
                    }
                } else { fault = nil }
                lastDevices = snapshot.devices
            }
            if case .outputChanged = event {
                if outputChanged, !released, mode != .forceOff, record?.ownsOutput != true {
                    let matches = profiles.filter { profile in
                        guard let feedUID = profile.managedFeedUID else { return false }
                        return feedUID == snapshot.outputUID
                            && (mode == .automatic ? automaticSelectionAllows(profile, in: snapshot)
                                : selectedID == nil || selectedID == profile.id)
                            && available(profile, in: snapshot, requireTrigger: mode != .forceOn)
                    }
                    if matches.count == 1, let target = matches.first, let feedUID = target.managedFeedUID {
                        // Preserve a safe return route before handling a manually selected virtual output.
                        let saved = RouteRecord(profileID: target.id, captureUID: feedUID,
                            previousOutputUID: lastPhysicalOutputUID, previousAlertUID: nil,
                            ownsOutput: true, ownsAlerts: target.routeAlerts && snapshot.alertUID == feedUID)
                        try store.save(saved)
                        record = saved
                        requestedOutputProfileID = target.id
                        preserveManualVirtualStartup = true
                        suspended = false; fault = nil; exhaustedProfile = nil
                        log("Virtual output selected manually; activating \(target.name)")
                        enqueue(debounce: false)
                        return
                    }
                }
                guard var saved = record else {
                    if case .starting = state, snapshot.outputUID != startingOutputUID {
                        suspended = true
                        enqueue(debounce: false)
                    }
                    return
                }
                var changed = false
                if saved.ownsOutput && snapshot.outputUID != saved.captureUID {
                    saved.ownsOutput = false
                    suspended = !hardwareLost
                    changed = true
                }
                if saved.ownsAlerts && snapshot.alertUID != saved.captureUID {
                    saved.ownsAlerts = false
                    changed = true
                }
                guard changed else { return } // Our own property notifications.
                record = saved
                try store.save(saved)
                if suspended || hardwareLost { enqueue(debounce: false) }
                return
            }
            // Device removal must not wait behind the arrival debounce.
            let lostManagedDevice = managed.map { !available($0, in: snapshot, requireTrigger: mode != .forceOn) } ?? false
            enqueue(debounce: !lostManagedDevice)
        } catch {
            cancelRecovery()
            fault = error.localizedDescription
            enqueue(debounce: false)
        }
    }

    public func setMode(_ mode: AutomationMode, profileID: String? = nil) {
        guard !workAuthority.isShuttingDown else { return }
        if !automaticSwitching {
            self.mode = mode
            selectedID = CompanionSessionPolicy.selectedProfileID(profileID ?? selectedID, profiles: profiles)
            companionCleanupConsumed = false; fault = nil; reconnectPending = false
            onControlChange?()
            enqueue(debounce: false, reason: .policyAction)
            return
        }
        consumedDeviceLoss = nil
        cancelRecovery()
        released = false
        routingRestoring = false; routingError = nil
        reconnectPending = false
        bypassedActivationProfile = nil
        exhaustedProfile = nil
        self.mode = mode
        manualDeviceLossProfileID = nil
        requestedOutputProfileID = nil
        if mode == .automatic { selectedID = profileID }
        else if let profileID { selectedID = profileID }
        suspended = false; fault = nil
        onControlChange?()
        enqueue(debounce: false, reason: .policyAction)
    }

    /// Restore owned routes while retaining a verified DSP session. Retry alone does not resume a release.
    public func release() {
        guard automaticSwitching, !workAuthority.isShuttingDown, !released || routingError != nil else { return }
        consumedDeviceLoss = nil
        cancelRecovery()
        reconnectPending = false
        bypassedActivationProfile = nil
        requestedOutputProfileID = nil
        released = true; suspended = false; fault = nil; routingError = nil
        routingRestoring = true
        enqueue(debounce: false, reason: .policyAction)
    }

    /// Resume retained policy after explicit release or manual output suspension.
    public func resume() throws {
        guard automaticSwitching, !workAuthority.isShuttingDown, (suspended || released), mode != .forceOff else {
            throw SwitcherError.message("DSP is not suspended with an enabled policy.")
        }
        consumedDeviceLoss = nil
        cancelRecovery()
        bypassedActivationProfile = nil
        released = false; suspended = false; fault = nil; exhaustedProfile = nil; routingError = nil
        routingRestoring = true
        enqueue(debounce: false, reason: .policyAction)
    }

    /// Intentional DSP restart, without USB reset or any GUI operation.
    public func reconnect(profileID: String) throws {
        guard !workAuthority.isShuttingDown, !released, recovery == nil, mode != .forceOff else {
            throw SwitcherError.message("Select DSP Auto or Enabled before reconnecting.")
        }
        guard let profile = profiles.first(where: { $0.id == profileID }),
              selectedID == nil || selectedID == profileID,
              managed == nil || managed?.id == profileID else {
            throw SwitcherError.message("Reconnect must use the selected or active profile.")
        }
        let snapshot = try audio.snapshot()
        guard automaticSwitching ? available(profile, in: snapshot, requireTrigger: mode != .forceOn)
            : CompanionSessionPolicy.available(profile, in: snapshot, requireTrigger: mode != .forceOn) else {
            throw SwitcherError.message("Required audio devices are unavailable for reconnect.")
        }
        try validateSelectors(profile, in: snapshot)
        consumedDeviceLoss = nil
        cancelRecovery()
        companionCleanupConsumed = false
        bypassedActivationProfile = nil
        selectedID = profileID
        reconnectPending = true
        exhaustedProfile = nil; suspended = false; fault = nil
        onControlChange?()
        enqueue(debounce: false, reason: .policyAction)
    }

    public func retry() {
        guard !workAuthority.isShuttingDown else { return }
        if !automaticSwitching {
            guard mode != .forceOff else { return }
            companionCleanupConsumed = false; fault = nil
            enqueue(debounce: false, reason: .policyAction)
            return
        }
        if released {
            guard mode != .forceOff, exhaustedProfile != nil || isFailed(state),
                  let profile = exhaustedProfile ?? managed,
                  let snapshot = try? audio.snapshot(),
                  available(profile, in: snapshot, requireTrigger: mode != .forceOn) else { return }
            cancelRecovery()
            consumedDeviceLoss = nil
            fault = nil
            managed = profile
            beginRecovery(profile, kind: .unavailable, expectedOutputUID: snapshot.outputUID)
            return
        }
        consumedDeviceLoss = nil
        cancelRecovery()
        exhaustedProfile = nil
        suspended = false; fault = nil
        enqueue(debounce: false)
    }

    private func isFailed(_ state: RuntimeState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    public func shutdown() async {
        workAuthority.closeAdmission()
        bypassedActivationProfile = nil
        audio.stopMonitoring()
        dsp.onFailure = nil
        workAuthority.invalidateForShutdown()
        let recoveryToDrain = workAuthority.recoveryTask
        cancelRecovery()
        workAuthority.cancelDelay()
        routingRestoring = false
        await workAuthority.dspControlTask?.value
        await workAuthority.transitionTask?.value
        await recoveryToDrain?.value
        var entryRelinquishmentFailure: String?
        if !automaticSwitching {
            do { try relinquishRoutingOnce() }
            catch { entryRelinquishmentFailure = error.localizedDescription }
        }
        companionCleanupConsumed = false
        do {
            try await deactivate()
            state = entryRelinquishmentFailure.map(RuntimeState.failed) ?? .idle
        } catch { state = .failed(error.localizedDescription) }
    }

    private func enqueue(debounce: Bool, reason: TeardownReason = .automatic) {
        let ticket = workAuthority.prepareTransition(reason: reason)
        let token = ticket.token
        workAuthority.installTransition(Task { [weak self] in
            await ticket.priorTransition?.value
            await ticket.priorRecovery?.value
            await ticket.priorDSPControl?.value
            guard let self, self.current(token) else { return }
            if debounce {
                let timer = Task { try await self.sleeper.sleep(milliseconds: 800) }
                self.workAuthority.installDelay(timer)
                do { try await timer.value } catch { return }
                guard self.current(token) else { return }
                self.workAuthority.clearDelay()
            }
            await self.reconcile(token, reason: ticket.reason)
        })
    }

    private func current(_ token: Int) -> Bool { workAuthority.current(token) }
    private func rememberObservedOutput(_ snapshot: AudioSnapshot) {
        lastOutputUID = snapshot.outputUID
        if let uid = snapshot.outputUID, !profiles.contains(where: { $0.managedFeedUID == uid }),
           snapshot.devices.contains(where: { $0.uid == uid && $0.hasOutput }) {
            lastPhysicalOutputUID = uid
        }
    }
    private func setNormalOutput(uid: String) throws {
        guard automaticSwitching else {
            throw SwitcherError.message("Automatic Switching is disabled.")
        }
        assigningOutput = true
        defer { assigningOutput = false }
        try audio.setOutput(uid: uid)
    }
    private func reportExternalOutputSelection(_ snapshot: AudioSnapshot) {
        guard !assigningOutput, !handlingDisconnectFallback, !routingRestoring,
              !outputSelectionHardwareTransition,
              !workAuthority.hasPendingPolicyAction, !recovering, !dspControlBusy,
              fault == nil, routingError == nil, snapshot.devices == lastDevices else { return }
        switch state { case .starting, .stopping: return; default: break }
        let profile = managed ?? selectedID.flatMap { id in profiles.first { $0.id == id } }
            ?? (profiles.count == 1 ? profiles.first : nil)
        guard let profile, let uid = snapshot.outputUID,
              !profiles.contains(where: { $0.managedFeedUID == uid }),
              let device = snapshot.devices.first(where: { $0.uid == uid && $0.hasOutput }),
              available(profile, in: snapshot, requireTrigger: false),
              available(profile, in: AudioSnapshot(devices: lastDevices, outputUID: nil, alertUID: nil),
                        requireTrigger: false) else { return }
        onExternalOutputSelection?(profile.id, device)
    }
    private func observeOutputSelectionHardwareEdge(_ snapshot: AudioSnapshot) {
        guard snapshot.devices != lastDevices else { return }
        // The system can reroute after any output is removed or admitted, not
        // only after this profile loses its own capture/playback interface.
        let previousOutputs = Set(lastDevices.filter(\.hasOutput).map(\.uid))
        let currentOutputs = Set(snapshot.devices.filter(\.hasOutput).map(\.uid))
        if previousOutputs != currentOutputs {
            outputSelectionHardwareTransition = true
            return
        }
        let before = AudioSnapshot(devices: lastDevices, outputUID: nil, alertUID: nil)
        if profiles.contains(where: { profile in
            guard mode == .automatic ? automaticSelectionAllows(profile, in: snapshot)
                : selectedID == nil || selectedID == profile.id else { return false }
            let requireTrigger = mode == .automatic
            return available(profile, in: before, requireTrigger: requireTrigger)
                != available(profile, in: snapshot, requireTrigger: requireTrigger)
        }) { outputSelectionHardwareTransition = true }
    }
    private func available(_ profile: Profile, in snapshot: AudioSnapshot, requireTrigger: Bool) -> Bool {
        profile.deviceRolesAvailable(in: snapshot, automaticSwitching: true, requireTrigger: requireTrigger)
    }
    private func managedFeedUID(for profile: Profile) throws -> String {
        guard let uid = profile.managedFeedUID else {
            throw SwitcherError.message("\(profile.name) is a Companion Mode profile and has no managed system-output feed. Choose a profile with a managed feed or switch to Companion Mode.")
        }
        return uid
    }

    /// Auto selection is a preference while its hardware is available, not a
    /// permanent lock that prevents an eligible interface from taking over on loss.
    private func automaticSelectionAllows(_ candidate: Profile, in snapshot: AudioSnapshot) -> Bool {
        guard let selectedID, selectedID != candidate.id,
              let selected = profiles.first(where: { $0.id == selectedID }) else { return true }
        return !available(selected, in: snapshot, requireTrigger: true)
    }
    private func recordAutomaticHandoff(to profile: Profile) {
        guard mode == .automatic, let selectedID, selectedID != profile.id else { return }
        self.selectedID = profile.id
        onControlChange?()
    }
    private func choose(_ snapshot: AudioSnapshot) throws -> Profile? {
        if state == .needsSelection { state = .idle }
        if mode == .forceOff || suspended || released || fault != nil { return nil }
        if let id = requestedOutputProfileID {
            requestedOutputProfileID = nil
            if let target = profiles.first(where: { $0.id == id }),
               available(target, in: snapshot, requireTrigger: mode != .forceOn) {
                recordAutomaticHandoff(to: target)
                return target
            }
        }
        if let selectedID {
            guard let chosen = profiles.first(where: { $0.id == selectedID }) else {
                throw SwitcherError.message("Unknown profile: \(selectedID)")
            }
            _ = try managedFeedUID(for: chosen)
            if available(chosen, in: snapshot, requireTrigger: mode != .forceOn) { return chosen }
            if mode == .forceOn { throw SwitcherError.message("Required audio devices are unavailable for \(chosen.name).") }
            // In Auto, unavailable selected hardware can hand off to one
            // auto-activated alternative. Off, On and Companion do not use this path.
        }
        let candidates = profiles.filter {
            (mode == .forceOn || $0.autoActivate) && available($0, in: snapshot, requireTrigger: mode != .forceOn)
        }
        if let managed, candidates.contains(managed) {
            recordAutomaticHandoff(to: managed)
            return managed
        }
        if candidates.count == 1 {
            recordAutomaticHandoff(to: candidates[0])
            return candidates[0]
        }
        if candidates.count > 1 { state = .needsSelection }
        else if mode == .forceOn { throw SwitcherError.message("Select a profile with available capture and playback devices.") }
        return nil
    }

    private func validateSelectors(_ profile: Profile, in snapshot: AudioSnapshot) throws {
        for (uid, selector) in [(profile.captureUID, profile.expectedCaptureDevice),
                                (profile.playbackUID, profile.expectedPlaybackDevice)] {
            guard let device = snapshot.devices.first(where: { $0.uid == uid }) else {
                throw SwitcherError.message("Configured device is unavailable: \(uid)")
            }
            if selector == uid { continue }
            guard selector == device.name,
                  snapshot.devices.filter({ $0.name == selector }).count == 1 else {
                throw SwitcherError.message("DSP selector does not uniquely identify configured device: \(selector)")
            }
        }
    }

    private func reconcile(_ token: Int, reason: TeardownReason) async {
        defer {
            workAuthority.finishTransition(token: token)
            if current(token) { outputSelectionHardwareTransition = false }
        }
        if !automaticSwitching {
            await reconcileCompanion(token)
            return
        }
        let completesSwitchingTransition = switchingTransitionPending
        defer {
            if completesSwitchingTransition, current(token) {
                switchingTransitionPending = false
                onControlChange?()
            }
        }
        var routeOnlyTransition = false
        var routeAcquisitionStarted = false
        let teardownReason = reason
        do {
            let firstSnapshot = try audio.snapshot()
            if mode != .forceOff, let id = selectedID,
               let selected = profiles.first(where: { $0.id == id }) {
                // Missing routing support is a configuration choice, not hardware loss.
                _ = try managedFeedUID(for: selected)
            }
            if mode == .forceOn, !(released && routingRestoring),
               let id = selectedID, let selected = profiles.first(where: { $0.id == id }),
               !available(selected, in: firstSnapshot, requireTrigger: false) {
                // Loss can precede assignment of managed during a queued On
                // startup. End that request without inventing a DSP failure.
                prepareDeviceLoss(firstSnapshot, profile: selected)
                return
            }
            if reason == .automatic, let managed,
               !available(managed, in: firstSnapshot, requireTrigger: mode != .forceOn) {
                prepareDeviceLoss(firstSnapshot)
                return
            }
            if released && mode != .forceOff {
                if let target = bypassedActivationProfile {
                    bypassedActivationProfile = nil
                    guard available(target, in: firstSnapshot, requireTrigger: mode != .forceOn) else {
                        prepareDeviceLoss(firstSnapshot, profile: target)
                        return
                    }
                    if managed != target || state != .active(target.id) {
                        try await deactivate()
                        guard current(token) else { return }
                        try validateSelectors(target, in: firstSnapshot)
                        managed = target; state = .starting(target.id)
                        try await dsp.start(target)
                        guard current(token) else { return }
                        try await sleeper.sleep(milliseconds: target.startupDelayMilliseconds)
                        guard current(token) else { return }
                        try await dsp.verifyReadiness(target)
                        guard current(token) else { return }
                        let confirmed = try audio.snapshot()
                        guard available(target, in: confirmed, requireTrigger: mode != .forceOn) else {
                            prepareDeviceLoss(confirmed, profile: target)
                            return
                        }
                    }
                    state = .active(target.id)
                    routingRestoring = false
                    return
                }
                if let managed {
                    guard available(managed, in: firstSnapshot, requireTrigger: mode != .forceOn) else {
                        routingRestoring = false
                        try await deactivate(reason: teardownReason, preferManualFallback: true)
                        guard current(token) else { return }
                        state = .suspended
                        return
                    }
                    if case .active(let activeID) = state, activeID == managed.id {
                        do { try restoreRoutes(preferManualFallback: true) }
                        catch {
                            routingError = error.localizedDescription
                            routingRestoring = false
                            state = .active(managed.id)
                            return
                        }
                        guard current(token) else { return }
                        routingError = nil
                        routingRestoring = false
                        // The DSP remains verified and interactive while only its route is bypassed.
                        state = .active(managed.id)
                        return
                    }
                    // A session that was never verified is not retained by routing-only release.
                    try await deactivate(reason: teardownReason, preferManualFallback: true)
                    guard current(token) else { return }
                }
                routingError = nil
                routingRestoring = false
                state = .suspended
                return
            }
            let manualRequest = requestedOutputProfileID
            let target: Profile?
            do { target = try choose(firstSnapshot) }
            catch { try await deactivate(reason: teardownReason); throw error }
            let needsSelection = state == .needsSelection
            guard current(token) else { return }
            let restarting = reconnectPending
            reconnectPending = false
            let wasActive = target.map { managed == $0 && state == .active($0.id) } ?? false
            let routeAlreadyOwned = target.map {
                $0.managedFeedUID != nil && record?.profileID == $0.id && record?.ownsOutput == true
                    && firstSnapshot.outputUID == $0.managedFeedUID
            } ?? false
            if !restarting, wasActive, routeAlreadyOwned {
                routingRestoring = false; routingError = nil
                return
            }
            let adoptionSnapshot = firstSnapshot
            let adopt = target != nil && record?.profileID == target?.id
                && record?.ownsOutput == true && adoptionSnapshot.outputUID == record?.captureUID
                && ((initialRecovery && managed == target)
                    || (manualRequest == target?.id && (managed == nil || managed == target)))
            initialRecovery = false
            let routeOnlyResume = !restarting && wasActive && !routeAlreadyOwned
            routeOnlyTransition = routeOnlyResume
            if restarting || (!adopt && !routeOnlyResume) { try await deactivate(reason: teardownReason) }
            guard current(token) else { return }
            guard let target else {
                routingRestoring = false
                if let fault { state = .failed(fault) }
                else if suspended { state = .suspended }
                else { state = needsSelection ? .needsSelection : .idle }
                return
            }
            let startupSnapshot = try audio.snapshot()
            if released { routingRestoring = false; return }
            var routeOnlyReturnOutputUID: String?
            if routeOnlyResume {
                let virtualUIDs = Set(profiles.compactMap(\.managedFeedUID))
                if let feedUID = target.managedFeedUID, startupSnapshot.outputUID == feedUID {
                    let observedOutput = routingPolicy.eligibleOutputs(in: startupSnapshot)
                        .first(where: { $0.uid == lastPhysicalOutputUID })
                    // Enabling switching explicitly acquires a companion's routes.
                    // A fresh companion may never have observed a physical default,
                    // so use the normal restoration choice for its durable return
                    // route. Ordinary Resume still requires an observed output.
                    let returnOutput = observedOutput ?? (completesSwitchingTransition
                        ? routingPolicy.restorationOutputs(previousUID: nil, snapshot: startupSnapshot).first : nil)
                    guard let returnOutput else {
                        throw SwitcherError.message("Choose an available physical output before resuming routing.")
                    }
                    routeOnlyReturnOutputUID = returnOutput.uid
                } else if let currentUID = startupSnapshot.outputUID {
                    guard !virtualUIDs.contains(currentUID),
                          startupSnapshot.devices.contains(where: { $0.uid == currentUID && $0.hasOutput }) else {
                        throw SwitcherError.message("Choose an available physical output before resuming routing.")
                    }
                } else {
                    throw SwitcherError.message("Choose an available physical output before resuming routing.")
                }
            }
            try validateSelectors(target, in: startupSnapshot)
            startingOutputUID = startupSnapshot.outputUID
            if routeOnlyResume {
                // The retained active session is already verified. This transition
                // changes only CoreAudio routing and never touches the DSP service.
                state = .active(target.id)
            } else {
                state = .starting(target.id)
                // Record an attempted start so partial starts are stopped on failure or supersession.
                managed = target
                try await dsp.start(target)
                guard current(token) else { return }
                let timer = Task { try await self.sleeper.sleep(milliseconds: target.startupDelayMilliseconds) }
                workAuthority.installDelay(timer)
                try await timer.value
                guard current(token) else { return }
                workAuthority.clearDelay()
                try await dsp.verifyReadiness(target)
            }
            guard current(token) else { return }
            let snapshot = try audio.snapshot()
            guard available(target, in: snapshot, requireTrigger: mode != .forceOn) else {
                throw SwitcherError.message("Audio devices changed during startup.")
            }
            guard snapshot.outputUID == startingOutputUID else {
                suspended = true
                try await deactivate()
                if current(token) { state = .suspended }
                return
            }
            try validateSelectors(target, in: snapshot)
            let feedUID = try managedFeedUID(for: target)
            var saved = (adopt ? record : nil) ?? RouteRecord(profileID: target.id, captureUID: feedUID,
                                    previousOutputUID: snapshot.outputUID == feedUID
                                        ? routeOnlyReturnOutputUID : snapshot.outputUID,
                                    previousAlertUID: snapshot.alertUID == feedUID ? nil : snapshot.alertUID,
                                    ownsOutput: true, ownsAlerts: target.routeAlerts)
            if target.routeAlerts && !saved.ownsAlerts {
                saved.previousAlertUID = snapshot.alertUID == feedUID ? nil : snapshot.alertUID
                saved.ownsAlerts = true
            }
            routeAcquisitionStarted = true
            try store.save(saved) // Durable recovery information precedes every route acquisition.
            record = saved
            if snapshot.outputUID != feedUID { try setNormalOutput(uid: feedUID) }
            if target.routeAlerts && snapshot.alertUID != feedUID {
                try audio.setAlertOutput(uid: feedUID)
            }
            let confirmed = try audio.snapshot()
            guard confirmed.outputUID == feedUID,
                  !target.routeAlerts || confirmed.alertUID == feedUID else {
                throw SwitcherError.message("Audio route change was not confirmed.")
            }
            rememberObservedOutput(confirmed)
            state = .active(target.id)
            routingRestoring = false; routingError = nil
            reportOutput(confirmed, restored: false)
            preserveManualVirtualStartup = false
        } catch {
            guard current(token) else { return }
            if teardownReason != .deviceLoss, mode != .forceOff,
               !(released && routingRestoring), let managed, let snapshot = try? audio.snapshot(),
               !available(managed, in: snapshot, requireTrigger: mode != .forceOn) {
                prepareDeviceLoss(snapshot)
                return
            }
            if teardownReason == .deviceLoss {
                // A failed stop or ownership save is terminal for this event.
                // Never turn missing hardware into recurring teardown attempts.
                fault = error.localizedDescription
                routingRestoring = false
                state = .failed(error.localizedDescription)
                log(error.localizedDescription)
                return
            }
            if let failure = error as? DSPFailure {
                guard let profile = managed else { return }
                switch failure {
                case .starting:
                    beginRecovery(profile, kind: .starting, expectedOutputUID: startingOutputUID)
                    return
                case .unavailable:
                    beginRecovery(profile, kind: .unavailable, expectedOutputUID: startingOutputUID)
                    return
                }
            }
            let message = error.localizedDescription
            if routeOnlyTransition, let managed {
                do { try restoreRoutes() }
                catch { log("Could not restore the output after resume failed: \(error.localizedDescription)") }
                released = true
                routingError = message
                routingRestoring = false
                state = .active(managed.id)
                return
            }
            fault = message
            routingRestoring = false
            routingError = routeAcquisitionStarted ? message : nil
            do { try await deactivate(reason: teardownReason) }
            catch { log("Recovery failed: \(error.localizedDescription)") }
            guard current(token) else { return }
            state = .failed(message)
            log(message)
        }
    }

    private func deactivate(reason: TeardownReason = .policyAction, preferManualFallback: Bool = false) async throws {
        if !automaticSwitching {
            try await stopCompanionSession()
            return
        }
        preserveManualVirtualStartup = false
        if let managed { state = .stopping(managed.id) }
        do { try restoreRoutes(preferManualFallback: preferManualFallback, reason: reason) }
        catch {
            if let managed, let snapshot = try? audio.snapshot(),
               !available(managed, in: snapshot, requireTrigger: false) {
                try await dsp.stop(managed)
                self.managed = nil
            }
            throw error
        }
        if let managed {
            try await dsp.stop(managed)
            self.managed = nil
        }
    }

    private func handleCompanionEvent(_ event: AudioEvent) {
        do {
            let snapshot = try audio.snapshot()
            let previous = AudioSnapshot(devices: lastDevices, outputUID: nil, alertUID: nil)
            let profile = profiles.first { $0.id == selectedID }
            let before = profile.map { CompanionSessionPolicy.available($0, in: previous, requireTrigger: mode != .forceOn) } ?? false
            let after = profile.map { CompanionSessionPolicy.available($0, in: snapshot, requireTrigger: mode != .forceOn) } ?? false
            lastDevices = snapshot.devices
            rememberObservedOutput(snapshot)
            onSnapshot?(snapshot)
            // Default-output changes are observations only. No fallback, profile
            // adoption, suspension, recovery loop or system output assignment.
            guard before != after else { return }
            if after { fault = nil; companionCleanupConsumed = false }
            else { cancelRecovery(); fault = nil }
            enqueue(debounce: after, reason: .automatic)
        } catch {
            fault = error.localizedDescription
            enqueue(debounce: false)
        }
    }

    private func relinquishRoutingOnce() throws {
        guard pendingRouteRelinquishment else { return }
        pendingRouteRelinquishment = false
        guard record != nil else { return }
        // Companion mode preserves the selected normal and alert outputs. Drop
        // ownership before persistence so even a failed save cannot authorize a
        // later companion command, notification or Quit to restore those routes.
        record = nil
        do { try store.save(nil) }
        catch { routingError = error.localizedDescription; throw error }
    }

    private func stopCompanionSession() async throws {
        guard let managed, !companionCleanupConsumed else { return }
        companionCleanupConsumed = true
        state = .stopping(managed.id)
        try await dsp.stop(managed)
        self.managed = nil
    }

    private func reconcileCompanion(_ token: Int) async {
        defer {
            if current(token) { switchingTransitionPending = false; onControlChange?() }
        }
        do {
            try relinquishRoutingOnce()
            guard current(token), !automaticSwitching else { return }
            let snapshot = try audio.snapshot()
            guard let id = selectedID, let profile = profiles.first(where: { $0.id == id }) else {
                try await stopCompanionSession()
                guard current(token) else { return }
                state = .needsSelection
                return
            }
            let available = CompanionSessionPolicy.available(profile, in: snapshot, requireTrigger: mode != .forceOn)
            if mode == .forceOff || !available || fault != nil {
                try await stopCompanionSession()
                guard current(token) else { return }
                state = fault.map(RuntimeState.failed) ?? .idle
                return
            }
            if managed?.id == profile.id, state == .active(profile.id), !reconnectPending { return }
            if managed != nil {
                companionCleanupConsumed = false
                try await stopCompanionSession()
                guard current(token) else { return }
            }
            reconnectPending = false
            try validateSelectors(profile, in: snapshot)
            companionCleanupConsumed = false
            managed = profile
            state = .starting(profile.id)
            let deadline = now() + 30
            try await withRecoveryDeadline(until: deadline) { try await self.dsp.start(profile) }
            guard current(token) else { return }
            try await withRecoveryDeadline(until: deadline) {
                try await self.sleeper.sleep(milliseconds: profile.startupDelayMilliseconds)
            }
            guard current(token) else { return }
            // Only an in-flight Starting response can receive finite readiness
            // retries. Offline/unavailable ends this attempt, never restarts it.
            while current(token) {
                do {
                    try await withRecoveryDeadline(until: deadline) { try await self.dsp.verifyReadiness(profile) }
                    break
                } catch DSPFailure.starting {
                    guard now() < deadline else { throw RecoveryWindowExpired() }
                    try await sleeper.sleep(milliseconds: 500)
                }
            }
            guard current(token), !automaticSwitching else { return }
            guard CompanionSessionPolicy.available(profile, in: try audio.snapshot(), requireTrigger: mode != .forceOn) else {
                try await stopCompanionSession()
                guard current(token) else { return }
                state = .idle
                return
            }
            state = .active(profile.id)
            fault = nil
        } catch is CancellationError { }
        catch {
            guard current(token) else { return }
            fault = error is RecoveryWindowExpired ? "CamillaDSP startup did not succeed within 30 seconds." : error.localizedDescription
            do { try await stopCompanionSession() }
            catch { fault = (fault ?? "") + " Cleanup: " + error.localizedDescription }
            guard current(token) else { return }
            state = .failed(fault ?? "DSP unavailable")
        }
    }

    private func cancelRecovery() {
        workAuthority.cancelRecovery()
        recovery = nil
    }

    /// Consume loss ownership before any actor yield or later failure callback.
    /// The serialized transition then stops the service without a retry window.
    private func manualFallbackEdgeProfile(_ snapshot: AudioSnapshot) -> Profile? {
        let profile = managed ?? selectedID.flatMap { id in profiles.first { $0.id == id } }
            ?? (profiles.count == 1 ? profiles.first : nil)
        guard let profile, fallbackPreference(profileID: profile.id).mode == .manual else { return nil }
        let before = AudioSnapshot(devices: lastDevices, outputUID: nil, alertUID: nil)
        // A former On session keeps its capture/playback edge definition after
        // loss turns it Off. An optional Auto trigger must not hide its reconnect.
        let requireTrigger = mode != .forceOn && manualDeviceLossProfileID != profile.id
        return available(profile, in: before, requireTrigger: requireTrigger)
            != available(profile, in: snapshot, requireTrigger: requireTrigger) ? profile : nil
    }

    /// Manual owns an availability edge, not every output property notification.
    /// It never selects an arbitrary alternative for a missing chosen device.
    private func enforceManualFallback(_ profile: Profile, snapshot: AudioSnapshot) throws {
        let uid = try routingPolicy.manualFallbackUID(preference: fallbackPreference(profileID: profile.id),
                                                    snapshot: snapshot)
        if snapshot.outputUID != uid { try setNormalOutput(uid: uid) }
        let confirmed = try audio.snapshot()
        guard confirmed.outputUID == uid else { throw SwitcherError.message("Fallback output change was not confirmed.") }
        rememberObservedOutput(confirmed)
        reportOutput(confirmed, restored: true)
    }

    private func prepareManualReconnect(_ profile: Profile, snapshot: AudioSnapshot) {
        cancelRecovery()
        lastDevices = snapshot.devices
        onSnapshot?(snapshot)
        rememberObservedOutput(snapshot)
        fault = nil; suspended = false; exhaustedProfile = nil
        handlingDisconnectFallback = true
        do { try enforceManualFallback(profile, snapshot: snapshot); routingError = nil }
        catch { routingError = error.localizedDescription; log(error.localizedDescription) }
        handlingDisconnectFallback = false
        let canActivate = mode != .forceOff && (selectedID == nil || selectedID == profile.id)
            && (mode == .forceOn || selectedID == profile.id || profile.autoActivate)
        released = canActivate
        requestedOutputProfileID = nil
        bypassedActivationProfile = canActivate ? profile : nil
        enqueue(debounce: false)
    }

    private func prepareDeviceLoss(_ snapshot: AudioSnapshot, profile: Profile? = nil, publishSnapshot: Bool = true) {
        let lossProfile = profile ?? managed
        if let lossProfile {
            if let loss = consumedDeviceLoss, loss.profileID == lossProfile.id,
               !available(lossProfile, in: snapshot, requireTrigger: loss.requireTrigger) { return }
            consumedDeviceLoss = (lossProfile.id, mode != .forceOn)
        }
        cancelRecovery()
        observeOutputSelectionHardwareEdge(snapshot)
        let manualEdge = manualFallbackEdgeProfile(snapshot)
        lastDevices = snapshot.devices
        if publishSnapshot {
            // A DSP transport callback can discover removal before CoreAudio
            // emits its event. Publish availability and output for UI/GUI state.
            onSnapshot?(snapshot)
            rememberObservedOutput(snapshot)
        }
        fault = nil
        handlingDisconnectFallback = true
        if let manualEdge, manualEdge == lossProfile {
            do { try enforceManualFallback(manualEdge, snapshot: snapshot); routingError = nil }
            catch { fault = error.localizedDescription; routingError = error.localizedDescription; log(error.localizedDescription) }
        }
        do {
            // Auto restores owned routes conservatively; Manual already forced
            // only normal output. Alert ownership remains independent.
            try restoreRoutes(reason: .deviceLoss)
        }
        catch { fault = error.localizedDescription; log("Disconnect cleanup failed: \(error.localizedDescription)") }
        handlingDisconnectFallback = false
        if mode == .forceOn, let lossProfile,
           !available(lossProfile, in: snapshot, requireTrigger: false) {
            // Classify and consume disconnect fallback using the original
            // policy first. Do not use setMode: that is an explicit user action
            // with different route-restoration rules.
            mode = .forceOff
            manualDeviceLossProfileID = lossProfile.id
            if selectedID == nil { selectedID = lossProfile.id }
            reconnectPending = false
            bypassedActivationProfile = nil
            requestedOutputProfileID = nil
            exhaustedProfile = nil
            suspended = false
            released = false
            routingRestoring = false
            onControlChange?()
        }
        enqueue(debounce: false, reason: .deviceLoss)
    }

    private func beginRecovery(_ profile: Profile, kind: RecoveryKind, expectedOutputUID: String?) {
        guard !workAuthority.isShuttingDown, recovery == nil else { return }
        if let snapshot = try? audio.snapshot(),
           !available(profile, in: snapshot, requireTrigger: mode != .forceOn) {
            prepareDeviceLoss(snapshot)
            return
        }
        var context = Recovery(profile: profile, deadline: now() + 30, kind: kind,
                               expectedOutputUID: expectedOutputUID)
        do {
            if kind != .starting || !preserveManualVirtualStartup {
                try restoreRoutes()
                preserveManualVirtualStartup = false
            }
            context.expectedOutputUID = try audio.snapshot().outputUID
        } catch {
            fault = error.localizedDescription
            routingError = error.localizedDescription
            routingRestoring = false
            state = .failed(error.localizedDescription)
            return
        }
        recovery = context
        log("Recovery started for \(profile.name); deadline in 30 seconds")
        state = .starting(profile.id)
        let handoff = workAuthority.recoveryHandoff()
        let token = handoff.token
        workAuthority.installRecovery(Task { [weak self] in
            guard let self else { return }
            await handoff.priorTransition?.value
            await handoff.priorDSPControl?.value
            await self.runRecovery(token: token)
        })
    }

    private func runRecovery(token: Int) async {
        while current(token), var context = recovery {
            let remaining = context.deadline - now()
            guard remaining > 0 else { break }
            let waitMilliseconds: Int
            switch context.kind {
            case .starting:
                waitMilliseconds = 500
            case .unavailable:
                let delays = [1000, 2000, 4000]
                waitMilliseconds = context.unavailableAttempt < delays.count
                    ? delays[context.unavailableAttempt] : 4000
            }
            do {
                try await sleeper.sleep(milliseconds: min(waitMilliseconds,
                    max(1, Int((remaining * 1000).rounded(.down)))))
            } catch { return }
            guard current(token), recovery != nil, now() < context.deadline else { break }

            do {
                let snapshot = try audio.snapshot()
                guard available(context.profile, in: snapshot, requireTrigger: mode != .forceOn) else {
                    prepareDeviceLoss(snapshot)
                    return
                }
                try validateSelectors(context.profile, in: snapshot)
                log("Recovery attempt; \(String(format: "%.1f", context.deadline - now())) seconds remaining")
                switch context.kind {
                case .starting:
                    try await withRecoveryDeadline(until: context.deadline) {
                        try await self.dsp.verifyReadiness(context.profile)
                    }
                case .unavailable:
                    context.unavailableAttempt += 1
                    recovery = context
                    try await withRecoveryDeadline(until: context.deadline) {
                        try await self.dsp.start(context.profile)
                        try await self.dsp.verifyReadiness(context.profile)
                    }
                }
                guard current(token), now() < context.deadline else { break }
                try activateRecovered(context.profile, expectedOutputUID: context.expectedOutputUID)
                recovery = nil
                workAuthority.clearRecovery()
                fault = nil
                return
            } catch is RecoveryWindowExpired {
                guard current(token) else { return }
                break
            } catch let failure as DSPFailure {
                guard current(token) else { return }
                if let snapshot = try? audio.snapshot(),
                   !available(context.profile, in: snapshot, requireTrigger: mode != .forceOn) {
                    prepareDeviceLoss(snapshot)
                    return
                }
                switch failure {
                case .starting:
                    context.kind = .starting
                    recovery = context
                case .unavailable:
                    do {
                        try restoreRoutes()
                        preserveManualVirtualStartup = false
                        context.expectedOutputUID = try audio.snapshot().outputUID
                    } catch {
                        recovery = nil; workAuthority.clearRecovery()
                        fault = error.localizedDescription
                        routingError = error.localizedDescription
                        routingRestoring = false
                        state = .failed(error.localizedDescription)
                        return
                    }
                    context.kind = .unavailable
                    recovery = context
                }
            } catch {
                guard current(token) else { return }
                if let snapshot = try? audio.snapshot(),
                   !available(context.profile, in: snapshot, requireTrigger: mode != .forceOn) {
                    prepareDeviceLoss(snapshot)
                    return
                }
                // Only typed DSP failures are recoverable. Configuration, routing, and
                // protocol errors terminate the window immediately.
                recovery = nil
                fault = error.localizedDescription
                do { try restoreRoutes() } catch { fault = error.localizedDescription }
                do { try await deactivate() }
                catch { log("DSP cleanup after recovery failure failed: \(error.localizedDescription)") }
                guard current(token) else { return }
                routingRestoring = false
                state = .failed(fault ?? error.localizedDescription)
                workAuthority.clearRecovery()
                return
            }
        }
        guard current(token), let expired = recovery else { return }
        if let snapshot = try? audio.snapshot(),
           !available(expired.profile, in: snapshot, requireTrigger: mode != .forceOn) {
            prepareDeviceLoss(snapshot)
            return
        }
        exhaustedProfile = expired.profile
        do { try restoreRoutes() }
        catch { fault = error.localizedDescription }
        let expiredMessage = "CamillaDSP recovery did not succeed within 30 seconds."
        let previousFault = fault
        do { try await deactivate() }
        catch { log("DSP cleanup after recovery failure failed: \(error.localizedDescription)") }
        guard current(token) else { return }
        fault = previousFault.map { "\($0) Recovery did not succeed within 30 seconds." } ?? expiredMessage
        routingRestoring = false
        state = .failed(fault ?? expiredMessage)
        recovery = nil
        workAuthority.clearRecovery()
        log(fault!)
    }

    private func activateRecovered(_ profile: Profile, expectedOutputUID: String?) throws {
        let snapshot = try audio.snapshot()
        guard available(profile, in: snapshot, requireTrigger: mode != .forceOn) else {
            throw SwitcherError.message("Audio devices changed during recovery.")
        }
        try validateSelectors(profile, in: snapshot)
        if released {
            // Recovery may restore DSP service availability, but a released route
            // remains on the physical output until the user explicitly resumes it.
            state = .active(profile.id)
            routingRestoring = false
            routingError = nil
            return
        }
        guard snapshot.outputUID == expectedOutputUID else {
            suspended = true
            throw SwitcherError.message("The audio output changed during recovery.")
        }
        let feedUID = try managedFeedUID(for: profile)
        var saved = record ?? RouteRecord(profileID: profile.id, captureUID: feedUID,
                                previousOutputUID: snapshot.outputUID == feedUID ? nil : snapshot.outputUID,
                                previousAlertUID: snapshot.alertUID == feedUID ? nil : snapshot.alertUID,
                                ownsOutput: true, ownsAlerts: profile.routeAlerts)
        if profile.routeAlerts && !saved.ownsAlerts {
            saved.previousAlertUID = snapshot.alertUID == feedUID ? nil : snapshot.alertUID
            saved.ownsAlerts = true
        }
        try store.save(saved)
        record = saved
        if snapshot.outputUID != feedUID { try setNormalOutput(uid: feedUID) }
        if profile.routeAlerts && snapshot.alertUID != feedUID {
            try audio.setAlertOutput(uid: feedUID)
        }
        let confirmed = try audio.snapshot()
        guard confirmed.outputUID == feedUID,
              !profile.routeAlerts || confirmed.alertUID == feedUID else {
            throw SwitcherError.message("Audio route change was not confirmed.")
        }
        rememberObservedOutput(confirmed)
        state = .active(profile.id)
        routingRestoring = false
        routingError = nil
        reportOutput(confirmed, restored: false)
        preserveManualVirtualStartup = false
    }

    private func withRecoveryDeadline<T>(until deadline: TimeInterval,
                                          operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let remaining = deadline - now()
        guard remaining > 0 else { throw RecoveryWindowExpired() }
        let completion = RecoveryCompletion<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.setContinuation(continuation)
                let work = Task { @MainActor in
                    do { completion.resolve(.success(try await operation())) }
                    catch { completion.resolve(.failure(error)) }
                }
                let watchdog = Task { @MainActor in
                    do {
                        try await sleeper.sleep(milliseconds: max(1, Int((remaining * 1000).rounded(.up))))
                        await completion.cancelWorkAndWait(RecoveryWindowExpired())
                    } catch { }
                }
                completion.install(work: work, watchdog: watchdog)
            }
        } onCancel: {
            Task { @MainActor in await completion.cancelWorkAndWait(CancellationError()) }
        }
    }

    private func reportOutput(_ snapshot: AudioSnapshot, restored: Bool) {
        onSnapshot?(snapshot)
        guard let uid = snapshot.outputUID, let device = snapshot.devices.first(where: { $0.uid == uid }) else { return }
        onFeedback?(.output(uid: uid, name: device.name, restored: restored))
    }

    private func restoreRoutes(preferManualFallback: Bool = false,
                               reason: TeardownReason = .policyAction) throws {
        guard automaticSwitching else { return }
        guard var saved = record else { return }
        if routingPolicy.relinquishesRoutes(preference: fallbackPreference(profileID: saved.profileID), reason: reason) {
            // Never leave a pending in-memory restoration for a later callback
            // or quit. Save failure is surfaced rather than changing output.
            record = nil
            try store.save(nil)
            return
        }
        var failures: [String] = []
        for alerts in [false, true] {
            guard alerts ? saved.ownsAlerts : saved.ownsOutput else { continue }
            do {
                let snapshot = try audio.snapshot()
                let actual = alerts ? snapshot.alertUID : snapshot.outputUID
                if actual == saved.captureUID {
                    let previous = alerts ? saved.previousAlertUID : saved.previousOutputUID
                    let candidates = routingPolicy.restorationCandidates(previousUID: previous,
                        captureUID: saved.captureUID, snapshot: snapshot,
                        preference: fallbackPreference(profileID: saved.profileID), alerts: alerts,
                        preferManualFallback: preferManualFallback, reason: reason)
                    var restored = false
                    for uid in candidates {
                        do {
                            if alerts { try audio.setAlertOutput(uid: uid) } else { try setNormalOutput(uid: uid) }
                            let check = try audio.snapshot()
                            if (alerts ? check.alertUID : check.outputUID) == uid {
                                if !alerts {
                                    rememberObservedOutput(check)
                                    reportOutput(check, restored: true)
                                }
                                restored = true; break
                            }
                        } catch { log("Could not restore \(uid): \(error.localizedDescription)") }
                    }
                    if !restored { throw SwitcherError.message("No usable \(alerts ? "alert" : "normal") output could be restored.") }
                }
                if alerts { saved.ownsAlerts = false } else { saved.ownsOutput = false }
            } catch { failures.append(error.localizedDescription) }
        }
        record = saved.ownsOutput || saved.ownsAlerts ? saved : nil
        try store.save(record)
        if !failures.isEmpty { throw SwitcherError.message(failures.joined(separator: " ")) }
    }
}

private struct RecoveryWindowExpired: Error {}

@MainActor private final class RecoveryCompletion<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var work: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var completed = false
    private var cancelling = false

    func setContinuation(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func install(work: Task<Void, Never>, watchdog: Task<Void, Never>) {
        self.work = work
        self.watchdog = watchdog
        if completed {
            work.cancel()
            watchdog.cancel()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        guard !completed, !cancelling else { return }
        completed = true
        continuation?.resume(with: result)
        continuation = nil
        watchdog?.cancel()
    }

    func cancelWorkAndWait(_ error: Error) async {
        guard !completed else { return }
        cancelling = true
        work?.cancel()
        await work?.value
        completed = true
        continuation?.resume(throwing: error)
        continuation = nil
        watchdog?.cancel()
    }
}
