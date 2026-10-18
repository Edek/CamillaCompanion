import Foundation

/// Chooses safe output destinations without acquiring route ownership or touching
/// hardware. Reconciler retains event ordering, persistence and confirmed writes.
struct OutputRoutingPolicy {
    enum TeardownReason { case automatic, policyAction, deviceLoss }

    let managedCaptureUIDs: Set<String>

    func eligibleOutputs(in snapshot: AudioSnapshot, excluding captureUID: String? = nil) -> [AudioDevice] {
        var excluded = managedCaptureUIDs
        if let captureUID { excluded.insert(captureUID) }
        return snapshot.devices.filter { $0.hasOutput && !excluded.contains($0.uid) }
    }

    func restorationOutputs(previousUID: String?, excluding captureUID: String? = nil,
                            snapshot: AudioSnapshot) -> [AudioDevice] {
        let physical = eligibleOutputs(in: snapshot, excluding: captureUID)
        var candidates: [AudioDevice] = []
        if let previous = physical.first(where: { $0.uid == previousUID }) { candidates.append(previous) }
        candidates += physical.filter(\.isBuiltIn)
        candidates += physical
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.uid).inserted }
    }

    func relinquishesRoutes(preference: FallbackOutputPreference, reason: TeardownReason) -> Bool {
        reason == .deviceLoss && preference.mode == .off
    }

    func restorationCandidates(previousUID: String?, captureUID: String, snapshot: AudioSnapshot,
                               preference: FallbackOutputPreference, alerts: Bool,
                               preferManualFallback: Bool, reason: TeardownReason) -> [String] {
        let physical = restorationOutputs(previousUID: previousUID, excluding: captureUID, snapshot: snapshot)
        var candidates: [String] = []
        if !alerts, preferManualFallback, reason != .deviceLoss,
           preference.mode != .automatic, preference.outputSelection == .device, let uid = preference.outputUID,
           physical.contains(where: { $0.uid == uid }) { candidates.append(uid) }
        candidates += physical.map(\.uid)
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// Force fallback owns a hardware edge and requires its exact saved target.
    /// Ordinary restoration can instead try the ordered alternatives above.
    func manualFallbackUID(preference: FallbackOutputPreference, snapshot: AudioSnapshot) throws -> String {
        guard preference.outputSelection == .device, let uid = preference.outputUID else {
            throw SwitcherError.message("Choose an output for Force fallback.")
        }
        guard eligibleOutputs(in: snapshot).contains(where: { $0.uid == uid }) else {
            throw SwitcherError.message("Selected fallback output is unavailable.")
        }
        return uid
    }
}
