import Foundation

/// Independent per-profile workers. Commands acknowledge desired state immediately.
@MainActor public final class GUIController {
    public var onFeedback: ((FeedbackEvent) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onStatusChange: ((GUIStatus) -> Void)?
    private let profiles: [Profile]
    private let service: GUIManaging
    private let sleeper: TransitionSleeping
    private let now: () -> TimeInterval
    private let recoverySeconds: TimeInterval
    private var policies: [String: GUIPolicy] = [:]
    private var observed: [String: GUIServiceState] = [:]
    private var errors: [String: String] = [:]
    private var present = Set<String>()
    private var workers: [String: Task<Void, Never>] = [:]
    private var generations: [String: Int] = [:]
    private var closing = false
    private var initialized = false
    private var announcedRunning = Set<String>()
    private var exited = Set<String>()
    private var recoveringProfiles = Set<String>()
    public init(profiles: [Profile], service: GUIManaging, sleeper: TransitionSleeping? = nil,
                recoverySeconds: TimeInterval = 30, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.profiles = profiles.filter { $0.gui != nil }; self.service = service
        self.sleeper = sleeper ?? TaskSleeper(); self.recoverySeconds = recoverySeconds; self.now = now
        service.onExit = { [weak self] id, reason in
            guard let self, !self.closing, let profile = self.profiles.first(where: { $0.id == id }),
                  self.observed[id] == .starting || self.observed[id] == .running else { return }
            self.exited.insert(id); self.errors[id] = reason
            self.log(profile, "unexpected exit: " + reason)
            if self.workers[id] == nil { self.launch(profile) }
        }
    }
    public func receive(_ snapshot: AudioSnapshot) {
        guard !closing else { return }
        let next = Set(snapshot.devices.map(\.uid)); let previous = present
        present = next
        for profile in profiles where !initialized || previous.contains(profile.triggerUID) != next.contains(profile.triggerUID) {
            // First device snapshot cannot renew an already-established manual recovery.
            let needsInitialObservation = !initialized && observed[profile.id] == nil && workers[profile.id] == nil
            let automaticEdge = (policies[profile.id] ?? .automatic) == .automatic && profile.gui!.autoStart &&
                previous.contains(profile.triggerUID) != next.contains(profile.triggerUID)
            if needsInitialObservation || automaticEdge { launch(profile) }
        }
        initialized = true
    }
    private func desired(_ profile: Profile) -> Bool {
        guard !closing else { return false }
        switch policies[profile.id] ?? .automatic {
        case .manualOn: return true
        case .manualOff: return false
        case .automatic: return profile.gui!.autoStart && present.contains(profile.triggerUID)
        }
    }
    public func status(profileID: String) throws -> GUIStatus {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            throw SwitcherError.message("Profile has no GUI configuration: " + profileID)
        }
        return GUIStatus(profileID: profileID, policy: policies[profileID] ?? .automatic,
                         autoStart: profile.gui!.autoStart, desiredRunning: desired(profile),
                         observed: observed[profileID] ?? .stopped, url: profile.gui!.url, lastError: errors[profileID], recovering: recoveringProfiles.contains(profileID))
    }
    public func command(_ command: GUICommand, profileID: String) async throws -> GUIStatus {
        guard !closing, let profile = profiles.first(where: { $0.id == profileID }) else {
            throw SwitcherError.message("Profile has no GUI configuration, is unknown, or controller is shutting down: " + profileID)
        }
        if command == .retry {
            guard observed[profileID] == .failed, workers[profileID] == nil else {
                throw SwitcherError.message("GUI retry requires a completed failure.")
            }
            launch(profile); publish(profile)
        } else if command != .status {
            let oldTarget = desired(profile)
            policies[profileID] = command == .start ? .manualOn : command == .stop ? .manualOff : .automatic
            log(profile, "desired policy updated")
            if oldTarget != desired(profile) || workers[profileID] == nil && observed[profileID] != (desired(profile) ? .running : .stopped) {
                launch(profile)
            }
            publish(profile)
        }
        return try status(profileID: profileID)
    }
    private func log(_ profile: Profile, _ message: String) {
        onLog?("GUI profile=\(profile.id) policy=\((policies[profile.id] ?? .automatic).rawValue) desired=\(desired(profile)) \(message)")
    }
    private func publish(_ profile: Profile) { if let value = try? status(profileID: profile.id) { onStatusChange?(value) } }
    private func set(_ profile: Profile, _ state: GUIServiceState, error: String? = nil) {
        if state != .starting && state != .stopping { recoveringProfiles.remove(profile.id) }
        observed[profile.id] = state; errors[profile.id] = error; publish(profile)
    }
    private func launch(_ profile: Profile) {
        recoveringProfiles.remove(profile.id)
        let id = profile.id; let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        let previous = workers[id]; previous?.cancel()
        workers[id] = Task { [weak self] in
            // A cancelled mutation may still finish. Serialize replacement behind it.
            await previous?.value
            guard let self, self.generations[id] == generation else { return }
            await self.reconcile(profile, generation: generation)
            if self.generations[id] == generation { self.workers[id] = nil }
        }
    }
    private func reconcile(_ profile: Profile, generation: Int) async {
        let id = profile.id; let target = desired(profile)
        let began = now(); let deadline = began + recoverySeconds
        service.beginRecovery(profile, deadline: deadline)
        var attempt = 0; var started = false
        func current() -> Bool { generations[id] == generation && desired(profile) == target && !Task.isCancelled }
        while current() {
            if now() >= deadline {
                let reason = "GUI recovery deadline expired after \(Int(recoverySeconds)) seconds: \(errors[id] ?? "service unavailable")"
                set(profile, .failed, error: reason); log(profile, reason)
                if !closing { onFeedback?(.failure(source: "gui:" + id, message: reason)) }; return
            }
            do {
                if target {
                    if !started {
                        set(profile, .starting); log(profile, "starting attempt=\(attempt + 1)")
                        exited.remove(id)
                        try await service.start(profile)
                        guard current() else { return }
                        if now() >= deadline { continue }
                        started = true
                    }
                    if exited.remove(id) != nil { throw GUIFailure.transient(errors[id] ?? "Backend exited during startup") }
                    try await service.verifyReadiness(profile)
                    guard current() else { return }
                    if now() >= deadline { continue }
                    if exited.remove(id) != nil { throw GUIFailure.transient("Backend exited during readiness verification") }
                    set(profile, .running); log(profile, "ready elapsed=\(String(format: "%.3f", now() - began))s\(attempt > 0 ? " recovered" : "")")
                    announcedRunning.insert(id)
                    if !closing { onFeedback?(.gui(profile: id, running: true)) }; return
                } else {
                    set(profile, .stopping); log(profile, "stopping attempt=\(attempt + 1)")
                    try await service.stop(profile)
                    guard current() else { return }
                    if now() >= deadline { continue }
                    set(profile, .stopped); log(profile, "stopped elapsed=\(String(format: "%.3f", now() - began))s")
                    if !closing, announcedRunning.remove(id) != nil { onFeedback?(.gui(profile: id, running: false)) }; return
                }
            } catch {
                guard current() else { return }
                errors[id] = error.localizedDescription
                guard let failure = error as? GUIFailure, failure.recoverable else {
                    set(profile, .failed, error: error.localizedDescription); log(profile, "failed: " + error.localizedDescription)
                    if !closing { onFeedback?(.failure(source: "gui:" + id, message: error.localizedDescription)) }; return
                }
                let delay: Int
                if case .starting = failure { delay = 500 }
                else { started = false; delay = min(4_000, 1_000 * (1 << min(attempt, 2))); attempt += 1 }
                log(profile, "recovery attempt=\(attempt) elapsed=\(String(format: "%.3f", now() - began))s reason=\(error.localizedDescription)")
                recoveringProfiles.insert(id)
                publish(profile)
                let remaining = max(0, Int((deadline - now()) * 1_000))
                do { try await sleeper.sleep(milliseconds: min(delay, remaining)) } catch { return }
            }
        }
    }
    public func shutdown() async {
        closing = true
        for profile in profiles { launch(profile) }
        let pending = Array(workers.values)
        for worker in pending { await worker.value }
    }
}
