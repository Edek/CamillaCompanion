import Foundation

/// Serializes lifecycle and command ownership without publishing runtime state.
/// Cancelled task slots remain available until their existing owners drain them.
@MainActor final class ReconcilerWorkAuthority {
    typealias TeardownReason = OutputRoutingPolicy.TeardownReason

    struct TransitionTicket {
        let token: Int
        let reason: TeardownReason
        let priorTransition: Task<Void, Never>?
        let priorRecovery: Task<Void, Never>?
        let priorDSPControl: Task<Void, Never>?
    }

    struct DSPControlReservation {
        let token: Int
        let id: UUID
        let priorTransition: Task<Void, Never>?
        let priorRecovery: Task<Void, Never>?
    }

    struct RecoveryHandoff {
        let token: Int
        let priorTransition: Task<Void, Never>?
        let priorDSPControl: Task<Void, Never>?
    }

    private var generation = 0
    private var pendingPolicyActionGeneration: Int?
    private(set) var isShuttingDown = false
    private(set) var transitionTask: Task<Void, Never>?
    private var delayTask: Task<Void, Error>?
    private(set) var recoveryTask: Task<Void, Never>?
    private(set) var dspControlTask: Task<Void, Never>?
    private var dspControlID: UUID?
    private var cancelDSPControl: (() -> Void)?
    private(set) var dspControlAllowsRestart = false
    private(set) var deferredDSPFailure: String?

    var hasPendingPolicyAction: Bool { pendingPolicyActionGeneration != nil }

    func current(_ token: Int) -> Bool { !isShuttingDown && generation == token }

    func prepareTransition(reason: TeardownReason) -> TransitionTicket {
        let effectiveReason: TeardownReason = reason == .automatic && hasPendingPolicyAction
            ? .policyAction : reason
        generation += 1
        pendingPolicyActionGeneration = effectiveReason == .policyAction ? generation : nil
        cancelDSPControl?()
        let token = generation
        delayTask?.cancel()
        return TransitionTicket(token: token, reason: effectiveReason,
                                priorTransition: transitionTask, priorRecovery: recoveryTask,
                                priorDSPControl: dspControlTask)
    }

    func installTransition(_ task: Task<Void, Never>) { transitionTask = task }

    func finishTransition(token: Int) {
        if pendingPolicyActionGeneration == token { pendingPolicyActionGeneration = nil }
    }

    func interruptForRecovery() {
        generation += 1
        cancelDSPControl?()
        delayTask?.cancel(); delayTask = nil
        transitionTask?.cancel()
    }

    func reserveDSPControl(allowsProcessingRestart: Bool) -> DSPControlReservation {
        let reservation = DSPControlReservation(token: generation, id: UUID(),
            priorTransition: transitionTask, priorRecovery: recoveryTask)
        dspControlID = reservation.id
        dspControlAllowsRestart = allowsProcessingRestart
        deferredDSPFailure = nil
        return reservation
    }

    func installDSPControl(cancel: @escaping () -> Void, drain: @MainActor () -> Task<Void, Never>) {
        // Reservation precedes Reconciler's Busy callback; installation follows it.
        // A callback may invalidate the generation while installation is pending.
        cancelDSPControl = cancel
        dspControlTask = drain()
    }

    func finishDSPControl(id: UUID) -> Bool {
        guard dspControlID == id else { return false }
        dspControlID = nil; cancelDSPControl = nil; dspControlTask = nil
        dspControlAllowsRestart = false; deferredDSPFailure = nil
        return true
    }

    func holdDSPFailure(_ message: String) { deferredDSPFailure = message }
    func clearHeldDSPFailure() { deferredDSPFailure = nil }

    func recoveryHandoff() -> RecoveryHandoff {
        RecoveryHandoff(token: generation, priorTransition: transitionTask,
                        priorDSPControl: dspControlTask)
    }

    func installRecovery(_ task: Task<Void, Never>) { recoveryTask = task }
    func cancelRecovery() { recoveryTask?.cancel() }
    func clearRecovery() { recoveryTask = nil }

    func installDelay(_ task: Task<Void, Error>) { delayTask = task }
    func cancelDelay() { delayTask?.cancel() }
    func clearDelay() { delayTask = nil }

    // Shutdown admission closes before monitoring teardown. Invalidation occurs
    // afterwards, preserving the controller's existing observable callback order.
    func closeAdmission() { isShuttingDown = true }
    func invalidateForShutdown() {
        generation += 1
        cancelDSPControl?()
    }
}
