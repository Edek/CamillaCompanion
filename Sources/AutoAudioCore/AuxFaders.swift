import Foundation

public struct AuxPreferences: Codable, Equatable, Sendable {
    public var visibleIDs: [Int]
    public var labels: [String: String]
    public var linkGroups: [[Int]]
    public var linkMutes: Bool
    public var lastVisibleIDs: [Int]
    public var sliderMinimumDB: Double
    public init(visibleIDs: [Int] = [], labels: [String: String] = [:], linkGroups: [[Int]] = [], linkMutes: Bool = true, lastVisibleIDs: [Int] = [], sliderMinimumDB: Double = -150) {
        self.visibleIDs = visibleIDs; self.labels = labels; self.linkGroups = linkGroups; self.linkMutes = linkMutes; self.lastVisibleIDs = lastVisibleIDs; self.sliderMinimumDB = sliderMinimumDB
    }
    private enum CodingKeys: String, CodingKey { case visibleIDs, labels, linkGroups, linkMutes, lastVisibleIDs, sliderMinimumDB }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        visibleIDs = try values.decode([Int].self, forKey: .visibleIDs)
        labels = try values.decode([String: String].self, forKey: .labels)
        linkGroups = try values.decode([[Int]].self, forKey: .linkGroups)
        linkMutes = try values.decodeIfPresent(Bool.self, forKey: .linkMutes) ?? true
        lastVisibleIDs = try values.decodeIfPresent([Int].self, forKey: .lastVisibleIDs) ?? visibleIDs
        sliderMinimumDB = try values.decodeIfPresent(Double.self, forKey: .sliderMinimumDB) ?? -150
    }
    /// Visibility edits preserve labels and link policies and never imply a DSP command.
    public func hidingVisibility() -> AuxPreferences {
        var hidden = self
        if !visibleIDs.isEmpty { hidden.lastVisibleIDs = visibleIDs }
        hidden.visibleIDs = []
        return hidden
    }
    public func restoringVisibility(availableIDs: [Int]? = nil) -> AuxPreferences {
        var restored = self
        let available = availableIDs.map { Set($0.filter { (1...4).contains($0) }) }
        let remembered = Set(lastVisibleIDs.filter { (1...4).contains($0) })
        let target = remembered.isEmpty ? available ?? [] : remembered
        restored.visibleIDs = (available.map { target.intersection($0) } ?? target).sorted()
        return restored
    }
    public func validated() throws -> AuxPreferences {
        func valid(_ ids: [Int]) -> Bool { ids.allSatisfy { (1...4).contains($0) } && Set(ids).count == ids.count }
        guard valid(lastVisibleIDs) else { throw SwitcherError.message("Remembered Aux visibility must contain unique IDs from 1 through 4") }
        guard valid(visibleIDs) else { throw SwitcherError.message("Aux visibility must contain unique IDs from 1 through 4") }
        guard sliderMinimumDB.isFinite, (-150...50).contains(sliderMinimumDB) else {
            throw SwitcherError.message("Slider minimum must be finite and between -150 and 50 dB")
        }
        var used = Set<Int>()
        for group in linkGroups {
            guard group.count >= 2, valid(group), used.isDisjoint(with: group) else {
                throw SwitcherError.message("Aux links require disjoint groups of two or more IDs from 1 through 4")
            }
            used.formUnion(group)
        }
        var cleanLabels: [String: String] = [:]
        for (key, label) in labels {
            let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = Int(key), (1...4).contains(id), key == String(id), !clean.isEmpty, clean.count <= 80 else {
                throw SwitcherError.message("Aux labels require IDs from 1 through 4 and 1 through 80 characters")
            }
            cleanLabels[key] = clean
        }
        return AuxPreferences(visibleIDs: visibleIDs.sorted(), labels: cleanLabels,
                              linkGroups: linkGroups.map { $0.sorted() }.sorted { $0[0] < $1[0] }, linkMutes: linkMutes, lastVisibleIDs: lastVisibleIDs.sorted(), sliderMinimumDB: sliderMinimumDB)
    }
}
@MainActor public protocol AuxPreferencesStoring: AnyObject {
    func load(profileID: String) throws -> AuxPreferences?
    func save(_ preferences: AuxPreferences, profileID: String) throws
}
public struct AuxFader: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var volumeDB: Double
    public var muted: Bool
    public var maximumDB: Double
    public init(id: Int, name: String, volumeDB: Double, muted: Bool, maximumDB: Double) {
        self.id = id; self.name = name; self.volumeDB = volumeDB; self.muted = muted; self.maximumDB = maximumDB
    }
}
public struct AuxDSPState: Codable, Equatable, Sendable {
    public var faders: [AuxFader]
    public var main: AuxFader?
    public init(faders: [AuxFader], main: AuxFader? = nil) { self.faders = faders; self.main = main }
}
public struct AuxFaderSnapshot: Codable, Equatable, Sendable {
    public var main: AuxFader?
    public var profileID: String?
    public var faders: [AuxFader]
    public var preferences: AuxPreferences
    public var ready: Bool
    public var preferencesEditable: Bool
    public var busy: Bool
    public var error: String?
    public init(profileID: String? = nil, faders: [AuxFader] = [], preferences: AuxPreferences = AuxPreferences(),
                ready: Bool = false, busy: Bool = false, error: String? = nil, preferencesEditable: Bool = true, main: AuxFader? = nil) {
        self.main = main
        self.profileID = profileID; self.faders = faders; self.preferences = preferences
        self.ready = ready; self.busy = busy; self.error = error; self.preferencesEditable = preferencesEditable
    }
}
@MainActor public protocol AuxDSPTransport: AnyObject {
    func read(profile: Profile) async throws -> AuxDSPState
    func setVolume(id: Int, db: Double) async throws
    func setMute(id: Int, muted: Bool) async throws
    func cancel()
}

public enum AuxVolumeIntent: Equatable, Sendable { case group, individual }
public struct AuxVolumeCandidate: Equatable, Sendable {
    public var faders: [AuxFader]
    public var available: Bool
    public var reason: String?
}
public struct AuxVolumeProposal: Equatable, Sendable {
    public var profileID: String
    public var id: Int
    public var requestedDB: Double
    public var effectiveDB: Double
    public var members: [AuxFader]
    public var group: AuxVolumeCandidate
    public var individual: AuxVolumeCandidate
    public var preferences: AuxPreferences
    fileprivate var authorityGeneration: Int
    public var linked: Bool { (preferences.linkGroups.first { $0.contains(id) }?.count ?? 1) > 1 }
    public var changed: Bool { members.first { $0.id == id }.map { abs($0.volumeDB - effectiveDB) > 0.000001 } ?? true }
}

/// Finite reads and serialized commands. No timer or background polling is installed.
@MainActor public final class AuxController {
    public private(set) var snapshot = AuxFaderSnapshot(preferencesEditable: false)
    public var onChange: ((AuxFaderSnapshot) -> Void)?
    /// Observed read/write/read cost, excluding coalescing spacing.
    public private(set) var lastDragTransactionDuration: TimeInterval?
    private let transport: AuxDSPTransport
    private let loadPreferences: (String) throws -> AuxPreferences?
    private let savePreferences: (String, AuxPreferences) throws -> Void
    private var profile: Profile?
    private var eligible = false
    private var generation = 0
    private var tail: Task<Void, Never>?
    private var queued = 0
    private var needsDefaults = false
    private var preferencesReadable = true
    private var rawFaders: [AuxFader] = []
    private var mainFader: AuxFader?
    private var controlFaders: [AuxFader] { (mainFader.map { [$0] } ?? []) + rawFaders }
    private final class VolumeDrag {
        let id: Int
        let baseline: [AuxFader]
        let preferences: AuxPreferences
        let intent: AuxVolumeIntent
        var latestDB: Double?
        var ended = false
        var waiting: CheckedContinuation<Void, Never>?
        var lastUpdateTime = 0.0
        init(id: Int, baseline: [AuxFader], preferences: AuxPreferences, intent: AuxVolumeIntent) {
            self.id = id; self.baseline = baseline; self.preferences = preferences; self.intent = intent
        }
        func wake() { let continuation = waiting; waiting = nil; continuation?.resume() }
    }
    private var volumeDrag: VolumeDrag?
    public init(transport: AuxDSPTransport, loadPreferences: @escaping (String) throws -> AuxPreferences?,
                savePreferences: @escaping (String, AuxPreferences) throws -> Void) {
        self.transport = transport; self.loadPreferences = loadPreferences; self.savePreferences = savePreferences
    }
    public func activate(profile next: Profile?, ready: Bool = true) {
        guard profile != next || eligible != (ready && next != nil) else { return }
        let changed = profile != next
        volumeDrag?.wake(); volumeDrag = nil
        generation += 1; tail?.cancel(); transport.cancel(); queued = 0
        profile = next; eligible = ready && next != nil
        snapshot.ready = false; snapshot.busy = false
        if changed {
            mainFader = nil
            rawFaders = []; snapshot = AuxFaderSnapshot(profileID: next?.id)
            needsDefaults = false; preferencesReadable = true
            if let next {
                do {
                    if let preferences = try loadPreferences(next.id) { snapshot.preferences = try preferences.validated() }
                    else { needsDefaults = true }
                } catch { preferencesReadable = false; snapshot.error = "Cannot load Aux preferences: " + error.localizedDescription }
            }
        }
        publish()
    }
    /// Revoke accepted fader work and wait for its finite transport to finish.
    /// The caller must reactivate and read fresh values after changing a pipeline.
    public func drainForDSPChange() async {
        let previous = tail
        activate(profile: profile, ready: false)
        await previous?.value
    }
    public func setPreferences(_ preferences: AuxPreferences) throws {
        guard let profile, preferencesReadable else { throw SwitcherError.message("Aux preferences are unavailable for this profile") }
        let canceledDrag = volumeDrag != nil
        if canceledDrag { cancelVolumeDrag(verifyCurrentValues: false) }
        defer { if canceledDrag { verifyCanceledDragValues() } }
        guard !snapshot.busy else { throw SwitcherError.message("Wait for the current Aux command before editing preferences") }
        var updated = try preferences.validated()
        if !updated.visibleIDs.isEmpty { updated.lastVisibleIDs = updated.visibleIDs }
        else if !snapshot.preferences.visibleIDs.isEmpty { updated.lastVisibleIDs = snapshot.preferences.visibleIDs }
        else if updated.lastVisibleIDs.isEmpty { updated.lastVisibleIDs = snapshot.preferences.lastVisibleIDs }
        let validated = try updated.validated()
        do { try savePreferences(profile.id, validated) }
        catch { snapshot.error = "Cannot save Aux preferences: " + error.localizedDescription; publish(); throw error }
        snapshot.preferences = validated; needsDefaults = false; snapshot.error = nil; publish()
    }
    /// Preparation and confirmation share the same serialization as slider and mute commands.
    /// A stale confirmation returns fresh consequences, without writing anything.
    public func prepareVolumeChange(id: Int, db: Double) async throws -> AuxVolumeProposal {
        guard db.isFinite else { throw SwitcherError.message("Aux volume must be a finite number") }
        return try await serializedProposal { profile, token in
            let fresh = try await self.read(profile, token: token)
            return try self.volumeProposal(id: id, db: db, faders: fresh, profile: profile, token: token)
        }
    }
    public func applyVolumeChange(proposal: AuxVolumeProposal, intent: AuxVolumeIntent) async throws -> AuxVolumeProposal? {
        try await serializedProposal { profile, token in
            guard profile.id == proposal.profileID, token == proposal.authorityGeneration else {
                throw SwitcherError.message("Aux profile or DSP authority changed. Enter the value again for the active profile.")
            }
            let fresh = try await self.read(profile, token: token)
            let renewed = try self.volumeProposal(id: proposal.id, db: proposal.requestedDB, faders: fresh, profile: profile, token: token)
            guard renewed == proposal else { return renewed }
            let candidate = intent == .group ? renewed.group : renewed.individual
            guard candidate.available else { throw SwitcherError.message(candidate.reason ?? "This Aux change is unavailable") }
            var wrote = false
            do {
                for target in candidate.faders {
                    guard self.current(token) else { throw CancellationError() }
                    if fresh.first(where: { $0.id == target.id }).map({ abs($0.volumeDB - target.volumeDB) > 0.000001 }) == true {
                        wrote = true
                        try await self.transport.setVolume(id: target.id, db: target.volumeDB)
                    }
                }
                if wrote {
                    let confirmed = try await self.read(profile, token: token)
                    guard candidate.faders.allSatisfy({ target in confirmed.contains { $0.id == target.id && abs($0.volumeDB - target.volumeDB) < 0.001 } }) else {
                        throw SwitcherError.message("CamillaDSP did not confirm the requested Aux values")
                    }
                }
                if self.preferencesReadable { self.snapshot.error = nil }
                return nil
            } catch {
                guard self.current(token) else { throw CancellationError() }
                if wrote {
                    do { _ = try await self.read(profile, token: token) }
                    catch { self.snapshot.ready = false }
                    throw SwitcherError.message("Aux command may have partially applied; current values were re-read where available: " + error.localizedDescription)
                }
                throw error
            }
        }
    }
    private func volumeProposal(id: Int, db: Double, faders: [AuxFader], profile: Profile, token: Int) throws -> AuxVolumeProposal {
        guard db.isFinite else { throw SwitcherError.message("Aux volume must be a finite number") }
        guard let origin = faders.first(where: { $0.id == id }) else { throw SwitcherError.message("Aux \(id) is unavailable in the active DSP pipeline") }
        let effective = max(-150, db)
        let ids = snapshot.preferences.linkGroups.first { $0.contains(id) } ?? [id]
        let group = faders.filter { ids.contains($0.id) }
        let complete = Set(ids).isSubset(of: Set(group.map(\.id)))
        let lower = group.map { -150 - $0.volumeDB }.max()!
        let upper = group.map { $0.maximumDB - $0.volumeDB }.min()!
        let offset = max(lower, effective - origin.volumeDB)
        let groupAvailable = complete && lower <= upper && offset <= upper
        let groupReason: String? = !complete ? "A linked Aux member is unavailable; update the link group." : (lower > upper ? "Linked members have no valid shared range." : (offset > upper ? "Group target exceeds its maximum of \(origin.volumeDB + upper) dB." : (offset > effective - origin.volumeDB ? "Group target is limited to \(origin.volumeDB + lower) dB to preserve existing offsets." : nil)))
        let groupTargets = group.map { fader -> AuxFader in var target = fader; target.volumeDB += offset; return target }
        var individual = origin; individual.volumeDB = effective
        return AuxVolumeProposal(profileID: profile.id, id: id, requestedDB: db, effectiveDB: effective, members: group,
            group: AuxVolumeCandidate(faders: groupTargets, available: groupAvailable, reason: groupReason),
            individual: AuxVolumeCandidate(faders: [individual], available: effective <= origin.maximumDB,
                reason: effective > origin.maximumDB ? "This fader's maximum is \(origin.maximumDB) dB." : nil),
            preferences: snapshot.preferences, authorityGeneration: token)
    }
    private func serializedProposal<T: Sendable>(_ operation: @escaping @MainActor (Profile, Int) async throws -> T) async throws -> T {
        guard let profile, eligible, volumeDrag == nil else {
            throw SwitcherError.message(volumeDrag != nil ? "Finish the Aux drag before requesting another command." : "Aux DSP is unavailable. Refresh when DSP is ready.")
        }
        let token = generation; let previous = tail
        queued += 1; snapshot.busy = true; publish()
        var outcome: Result<T, Error>?
        let work = Task { [weak self] in
            await previous?.value
            guard let self else { outcome = .failure(CancellationError()); return }
            do {
                guard self.current(token) else { throw CancellationError() }
                outcome = .success(try await operation(profile, token))
            } catch {
                outcome = .failure(error)
                if self.current(token) { self.snapshot.error = error.localizedDescription }
            }
            if self.current(token) { self.queued -= 1; self.snapshot.busy = self.queued > 0; self.publish() }
        }
        tail = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.generation += 1
                self.tail?.cancel(); self.transport.cancel(); self.queued = 0
                self.snapshot.ready = false; self.snapshot.busy = false
                self.publish()
            }
        }
        try Task.checkCancellation()
        guard current(token) else { throw CancellationError() }
        return try (outcome ?? .failure(CancellationError())).get()
    }
    public func refreshForUser() async throws {
        guard volumeDrag == nil else { throw SwitcherError.message("Finish the Aux drag before refreshing fader values.") }
        try await serializedProposal { profile, token in
            do {
                _ = try await self.read(profile, token: token)
                if self.preferencesReadable { self.snapshot.error = nil }
            } catch {
                if self.current(token) { self.snapshot.ready = false }
                throw error
            }
        }
    }
    public func refresh() async { await enqueue(.refresh) }
    public func changeVolumeForUser(id: Int, db: Double, intent: AuxVolumeIntent = .group) async throws {
        try await performForUser(.volume(id, db, intent))
    }
    public func setMuteForUser(id: Int, muted: Bool, intent: AuxVolumeIntent = .group) async throws {
        try await performForUser(.mute(id, muted, intent))
    }
    private func performForUser(_ command: Command) async throws {
        try await serializedProposal { profile, token in
            let applied = await self.perform(command, profile: profile, token: token)
            guard self.current(token) else { throw CancellationError() }
            guard applied else { throw SwitcherError.message(self.snapshot.error ?? "Aux command was rejected. Refresh current values before retrying.") }
        }
    }
    public func changeVolume(id: Int, db: Double, intent: AuxVolumeIntent = .group) async { await enqueue(.volume(id, db, intent)) }
    public func setMute(id: Int, muted: Bool, intent: AuxVolumeIntent = .group) async { await enqueue(.mute(id, muted, intent)) }
    /// Captures the gesture's selected members and bounds. One worker waits for event-driven
    /// targets, so a held or idle drag does not poll DSP or create timer work.
    @discardableResult public func beginVolumeDrag(id: Int, intent: AuxVolumeIntent = .group) -> Bool {
        guard let profile, eligible, snapshot.ready, !snapshot.busy, volumeDrag == nil,
              let group = try? members(id, faders: controlFaders, linked: intent == .group),
              group.map({ -150 - $0.volumeDB }).max()! <= group.map({ $0.maximumDB - $0.volumeDB }).min()! else { return false }
        let drag = VolumeDrag(id: id, baseline: group, preferences: snapshot.preferences, intent: intent)
        volumeDrag = drag
        let token = generation
        queued += 1; snapshot.busy = true; publish()
        let previous = tail
        let worker = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.runVolumeDrag(drag, profile: profile, token: token)
        }
        tail = worker
        return true
    }
    public func updateVolumeDrag(id: Int, db: Double) {
        guard let drag = volumeDrag, drag.id == id, !drag.ended, db.isFinite else { return }
        drag.latestDB = clampedDragTarget(db, drag: drag)
        drag.wake()
    }
    public func endVolumeDrag(id: Int, db: Double) {
        guard let drag = volumeDrag, drag.id == id, db.isFinite else { return }
        drag.latestDB = clampedDragTarget(db, drag: drag)
        drag.ended = true
        drag.wake()
    }
    /// Invalidates pending and in-flight work. No failed target is replayed.
    public func cancelVolumeDrag(verifyCurrentValues: Bool = true) {
        guard let drag = volumeDrag else { return }
        volumeDrag = nil; drag.wake()
        generation += 1; tail?.cancel(); transport.cancel(); queued = 0
        snapshot.busy = false
        if verifyCurrentValues { verifyCanceledDragValues() }
        else { publish() }
    }
    private func verifyCanceledDragValues() {
        guard let profile, eligible else { publish(); return }
        let token = generation
        let previous = tail
        queued += 1; snapshot.busy = true; publish()
        let verification = Task { [weak self] in
            await previous?.value
            guard let self, self.current(token) else { return }
            _ = await self.perform(.refresh, profile: profile, token: token)
            guard self.current(token) else { return }
            self.queued -= 1; self.snapshot.busy = self.queued > 0; self.publish()
        }
        tail = verification
    }
    private func clampedDragTarget(_ db: Double, drag: VolumeDrag) -> Double {
        let origin = drag.baseline.first { $0.id == drag.id }!
        let lower = drag.baseline.map { -150 - $0.volumeDB }.max()!
        let upper = drag.baseline.map { $0.maximumDB - $0.volumeDB }.min()!
        return origin.volumeDB + min(upper, max(lower, db - origin.volumeDB))
    }
    private func runVolumeDrag(_ drag: VolumeDrag, profile: Profile, token: Int) async {
        while current(token), volumeDrag === drag {
            if drag.latestDB == nil {
                if drag.ended { break }
                await withCheckedContinuation { drag.waiting = $0 }
                continue
            }
            // This finite spacing exists only when a newer target is waiting.
            // Continuation suspension above has no timer and no idle DSP reads.
            let spacing = 0.05 - (ProcessInfo.processInfo.systemUptime - drag.lastUpdateTime)
            if spacing > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
                catch { return }
            }
            guard current(token), volumeDrag === drag, let target = drag.latestDB else { return }
            drag.latestDB = nil
            let startedAt = ProcessInfo.processInfo.systemUptime
            let success = await perform(.dragVolume(drag.id, target, drag.baseline, drag.preferences, drag.intent), profile: profile, token: token)
            guard current(token), volumeDrag === drag else { return }
            drag.lastUpdateTime = ProcessInfo.processInfo.systemUptime
            lastDragTransactionDuration = drag.lastUpdateTime - startedAt
            publish() // intermediate readback is authoritative, but UI retains latest intent
            if !success { break }
        }
        guard current(token), volumeDrag === drag else { return }
        volumeDrag = nil; drag.wake()
        queued -= 1; snapshot.busy = queued > 0; publish()
    }
    private enum Command {
        case refresh, volume(Int, Double, AuxVolumeIntent), mute(Int, Bool, AuxVolumeIntent)
        case dragVolume(Int, Double, [AuxFader], AuxPreferences, AuxVolumeIntent)
    }
    private func enqueue(_ command: Command) async {
        guard let profile, eligible, volumeDrag == nil else {
            snapshot.error = volumeDrag != nil ? "Finish the Aux drag before requesting another command." : "Aux DSP is unavailable. Refresh when DSP is ready."
            publish(); return
        }
        let token = generation; let previous = tail
        queued += 1; snapshot.busy = true; publish()
        let work = Task { [weak self] in
            await previous?.value
            guard let self, self.current(token) else { return }
            _ = await self.perform(command, profile: profile, token: token)
            guard self.current(token) else { return }
            self.queued -= 1; self.snapshot.busy = self.queued > 0; self.publish()
        }
        tail = work
        await work.value
    }
    private func current(_ token: Int) -> Bool { token == generation && eligible && !Task.isCancelled }
    private func read(_ profile: Profile, token: Int) async throws -> [AuxFader] {
        let state = try await transport.read(profile: profile)
        guard current(token) else { throw CancellationError() }
        guard Set(state.faders.map(\.id)).count == state.faders.count,
              state.faders.allSatisfy({ (1...4).contains($0.id) && $0.volumeDB.isFinite && $0.maximumDB.isFinite &&
                  $0.maximumDB >= -150 && $0.maximumDB <= 50 && $0.volumeDB >= -150 && $0.volumeDB <= 50 }) else {
            throw SwitcherError.message("CamillaDSP returned invalid Aux fader values")
        }
        if let main = state.main {
            guard main.id == 0, main.volumeDB.isFinite, (-150...50).contains(main.volumeDB),
                  main.maximumDB.isFinite, (-150...50).contains(main.maximumDB) else {
                throw SwitcherError.message("CamillaDSP returned invalid Main volume values")
            }
        }
        mainFader = state.main
        rawFaders = state.faders.sorted { $0.id < $1.id }; snapshot.ready = true
        if needsDefaults && preferencesReadable { snapshot.preferences.visibleIDs = rawFaders.map(\.id) }
        return controlFaders
    }
    private func members(_ id: Int, faders: [AuxFader], linked: Bool = true) throws -> [AuxFader] {
        guard faders.contains(where: { $0.id == id }) else { throw SwitcherError.message("Aux \(id) is not available in the active DSP pipeline") }
        let ids = linked ? snapshot.preferences.linkGroups.first { $0.contains(id) } ?? [id] : [id]
        guard Set(ids).isSubset(of: Set(faders.map(\.id))) else {
            throw SwitcherError.message("A linked Aux fader is unavailable in the active DSP pipeline; update the link group first")
        }
        return faders.filter { ids.contains($0.id) }
    }
    private func perform(_ command: Command, profile: Profile, token: Int) async -> Bool {
        var wrote = false
        var expected: [AuxFader] = []
        do {
            let fresh = try await read(profile, token: token)
            switch command {
            case .refresh: break
            case .volume(let id, let db, let intent):
                guard db.isFinite else { throw SwitcherError.message("Aux volume must be finite") }
                let group = try members(id, faders: fresh, linked: intent == .group)
                let origin = fresh.first { $0.id == id }!
                let lower = group.map { -150 - $0.volumeDB }.max()!
                let upper = group.map { $0.maximumDB - $0.volumeDB }.min()!
                guard lower <= upper else { throw SwitcherError.message("Linked Aux levels cannot satisfy all fader limits with a shared offset") }
                let offset = min(upper, max(lower, db - origin.volumeDB))
                for fader in group where abs(offset) > 0.000001 {
                    guard current(token) else { return false }
                    wrote = true
                    try await transport.setVolume(id: fader.id, db: fader.volumeDB + offset)
                    var target = fader; target.volumeDB += offset; expected.append(target)
                }
            case .dragVolume(let id, let db, let baseline, let preferences, let intent):
                let group = try members(id, faders: fresh, linked: intent == .group)
                guard preferences == snapshot.preferences,
                      Set(group.map(\.id)) == Set(baseline.map(\.id)),
                      group.allSatisfy({ current in baseline.contains { $0.id == current.id && $0.maximumDB == current.maximumDB } }) else {
                    throw SwitcherError.message("Aux drag canceled because its linked members or limits changed")
                }
                let origin = baseline.first { $0.id == id }!
                let lower = baseline.map { -150 - $0.volumeDB }.max()!
                let upper = baseline.map { $0.maximumDB - $0.volumeDB }.min()!
                let offset = min(upper, max(lower, db - origin.volumeDB))
                for initial in baseline {
                    guard current(token) else { return false }
                    let targetDB = initial.volumeDB + offset
                    let actual = fresh.first { $0.id == initial.id }!
                    guard targetDB >= -150 && targetDB <= actual.maximumDB else {
                        throw SwitcherError.message("Aux drag target exceeds the current linked limits")
                    }
                    if abs(actual.volumeDB - targetDB) > 0.000001 {
                        wrote = true
                        try await transport.setVolume(id: initial.id, db: targetDB)
                    }
                    var target = actual; target.volumeDB = targetDB; expected.append(target)
                }
            case .mute(let id, let muted, let intent):
                for fader in try members(id, faders: fresh, linked: intent == .group && snapshot.preferences.linkMutes) where fader.muted != muted {
                    guard current(token) else { return false }
                    wrote = true
                    try await transport.setMute(id: fader.id, muted: muted)
                    var target = fader; target.muted = muted; expected.append(target)
                }
            }
            guard current(token) else { return false }
            if wrote || !expected.isEmpty {
                let confirmed = try await read(profile, token: token)
                guard expected.allSatisfy({ target in confirmed.contains { $0.id == target.id && abs($0.volumeDB - target.volumeDB) < 0.001 && $0.muted == target.muted } }) else {
                    throw SwitcherError.message("CamillaDSP did not confirm the requested Aux values")
                }
            }
            if preferencesReadable { snapshot.error = nil }
            return true
        } catch {
            guard current(token) else { return false }
            let reason = error.localizedDescription
            if wrote {
                do { _ = try await read(profile, token: token) }
                catch { if current(token) { snapshot.ready = false } }
                guard current(token) else { return false }
                snapshot.error = "Aux command may have partially applied; current values were re-read where available: " + reason
            } else { snapshot.ready = false; snapshot.error = reason }
            return false
        }
    }
    private func publish() {
        // Retain same-profile readback while authority is revoked. Ready is
        // false until a fresh read, so cached presentation cannot permit writes.
        snapshot.main = mainFader
        snapshot.preferencesEditable = profile != nil && preferencesReadable && !snapshot.busy
        snapshot.faders = rawFaders.map { fader in
            var named = fader; named.name = snapshot.preferences.labels[String(fader.id)] ?? fader.name; return named
        }
        onChange?(snapshot)
    }
}
