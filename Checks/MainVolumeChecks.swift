import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class MainVolumeFixture: AuxDSPTransport {
    var main = AuxFader(id: 0, name: "Main Volume", volumeDB: -12, muted: false, maximumDB: 0)
    var faders = [AuxFader(id: 1, name: "Left", volumeDB: -3, muted: false, maximumDB: 0),
                  AuxFader(id: 2, name: "Right", volumeDB: -6, muted: true, maximumDB: 0)]
    var writes: [Int] = []
    var reads = 0
    var hold = false
    var ignoreWrites = false
    var readError: Error?
    var includesMain = true
    var continuation: CheckedContinuation<Void, Never>?
    func read(profile: Profile) async throws -> AuxDSPState {
        reads += 1
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let readError { throw readError }
        return AuxDSPState(faders: faders, main: includesMain ? main : nil)
    }
    func setVolume(id: Int, db: Double) async throws {
        writes.append(id)
        if ignoreWrites { return }
        if id == 0 { main.volumeDB = db } else if let index = faders.firstIndex(where: { $0.id == id }) { faders[index].volumeDB = db }
    }
    func setMute(id: Int, muted: Bool) async throws {
        writes.append(id)
        if ignoreWrites { return }
        if id == 0 { main.muted = muted } else if let index = faders.firstIndex(where: { $0.id == id }) { faders[index].muted = muted }
    }
    func cancel() {}
}
@MainActor func eventually(_ message: String, _ predicate: () -> Bool) async throws {
    for _ in 0..<2000 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw CheckFailure.failed(message)
}
@MainActor func runMainVolumeChecks() async throws {
    let profile = Profile(id: "main", name: "Main fixture", triggerUID: "trigger", captureUID: "capture", playbackUID: "playback",
                          launchAgentLabel: "unused", launchAgentPath: "/unused", websocketURL: "ws://127.0.0.1:1234",
                          expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
    let transport = MainVolumeFixture()
    let preferences = AuxPreferences(visibleIDs: [], linkGroups: [[1, 2]])
    let controller = AuxController(transport: transport, loadPreferences: { _ in preferences }, savePreferences: { _, _ in })
    controller.activate(profile: profile)
    try check(transport.reads == 0, "Main activation adds no idle reader")
    try await controller.refreshForUser()
    try check(controller.snapshot.main?.id == 0 && controller.snapshot.faders.map(\.id) == [1, 2], "Main remains separate from Aux state and visibility")
    let verifiedMain = controller.snapshot.main
    let transitionWrites = transport.writes.count
    await controller.drainForDSPChange()
    try check(controller.snapshot.main == verifiedMain && !controller.snapshot.ready && !controller.snapshot.busy,
              "Same-profile DSP drain retains disabled Main readback")
    var unavailableRejected = false
    do { try await controller.changeVolumeForUser(id: 0, db: -20) } catch { unavailableRejected = true }
    try check(unavailableRejected && transport.writes.count == transitionWrites && !controller.beginVolumeDrag(id: 0),
              "Retained Main presentation has no command or drag authority")
    controller.activate(profile: profile, ready: true)
    try check(controller.snapshot.main == verifiedMain && !controller.snapshot.ready,
              "Same-profile activation waits for readback without removing Main")
    transport.readError = SwitcherError.message("Synthetic restart read failure")
    var refreshFailed = false
    do { try await controller.refreshForUser() } catch { refreshFailed = true }
    try check(refreshFailed && controller.snapshot.main == verifiedMain && !controller.snapshot.ready && transport.writes.count == transitionWrites,
              "Failed restart read retains disabled Main and cannot replay cached gain")
    transport.readError = nil; transport.main.volumeDB = -15
    try await controller.refreshForUser()
    try check(controller.snapshot.ready && controller.snapshot.main?.volumeDB == -15 && transport.writes.count == transitionWrites,
              "Recovery replaces retained Main with fresh DSP values without writing")
    transport.includesMain = false
    try await controller.refreshForUser()
    try check(controller.snapshot.ready && controller.snapshot.main == nil,
              "Authoritative fresh pipeline without Main removes retained Main")
    transport.includesMain = true; transport.main.volumeDB = -12
    try await controller.refreshForUser()
    var otherProfile = profile; otherProfile.id = "other-main"
    controller.activate(profile: otherProfile, ready: false)
    try check(controller.snapshot.main == nil && !controller.snapshot.ready,
              "Profile change clears retained Main before any new read")
    controller.activate(profile: profile)
    try await controller.refreshForUser()
    let aux = transport.faders
    try await controller.changeVolumeForUser(id: 0, db: -24)
    try await controller.setMuteForUser(id: 0, muted: true)
    try check(transport.main.volumeDB == -24 && transport.main.muted && transport.faders == aux && transport.writes == [0, 0], "Main gain and mute never alter linked or hidden Aux members")
    let proposal = try await controller.prepareVolumeChange(id: 0, db: -999)
    try check(!proposal.linked && proposal.effectiveDB == -150, "Main precise entry is unlinked and clamps the lower limit")
    _ = try await controller.applyVolumeChange(proposal: proposal, intent: .individual)
    try check(transport.main.volumeDB == -150, "Main exact entry confirms actual DSP readback")
    let above = try await controller.prepareVolumeChange(id: 0, db: 10)
    try check(!above.individual.available, "Main numeric entry respects configured volume_limit")
    var rejected = false
    do { _ = try await controller.applyVolumeChange(proposal: above, intent: .individual) } catch { rejected = true }
    try check(rejected && transport.main.volumeDB == -150, "Rejected boost issues no Main write")
    try await controller.refreshForUser()
    try check(controller.beginVolumeDrag(id: 0), "Main uses the shared event-driven drag worker")
    controller.updateVolumeDrag(id: 0, db: -10)
    try await eventually("Main audio did not change during drag") { transport.main.volumeDB == -10 }
    let writes = transport.writes.count
    try await Task.sleep(nanoseconds: 60_000_000)
    try check(transport.writes.count == writes && controller.snapshot.busy, "Holding a Main drag without movement causes no repeated DSP writes")
    controller.endVolumeDrag(id: 0, db: -8)
    try await eventually("Main drag did not finish") { !controller.snapshot.busy }
    try check(transport.main.volumeDB == -8 && transport.faders == aux, "Main drag confirms final target and preserves Aux trims/mute")
    let settledReads = transport.reads
    try await Task.sleep(nanoseconds: 60_000_000)
    try check(transport.reads == settledReads, "Completed Main drag installs no idle reads")
    let staleProposal = try await controller.prepareVolumeChange(id: 0, db: -15)
    transport.main.volumeDB = -9
    let beforeStale = transport.writes.count
    let renewed = try await controller.applyVolumeChange(proposal: staleProposal, intent: .individual)
    try check(renewed != nil && renewed?.members.first?.volumeDB == -9 && transport.writes.count == beforeStale,
              "Stale Main confirmation returns fresh consequences without mutation")
    transport.ignoreWrites = true
    var unconfirmed = false
    do { try await controller.changeVolumeForUser(id: 0, db: -11) } catch { unconfirmed = true }
    try check(unconfirmed && controller.snapshot.main?.volumeDB == -9, "Acknowledgement without Main readback cannot report success")
    transport.ignoreWrites = false
    try await controller.refreshForUser()
    transport.hold = true
    let canceledEdit = Task { try await controller.changeVolumeForUser(id: 0, db: -30) }
    try await eventually("Cancelable Main fixture never suspended") { transport.continuation != nil }
    let beforeCancel = transport.writes.count
    canceledEdit.cancel()
    transport.hold = false; transport.continuation?.resume(); transport.continuation = nil
    do { try await canceledEdit.value; throw CheckFailure.failed("Canceled Main edit accepted") } catch is CancellationError {}
    try await eventually("Canceled Main edit retained ready authority") { !controller.snapshot.ready && !controller.snapshot.busy }
    try check(transport.writes.count == beforeCancel && transport.main.volumeDB == -9, "Caller cancellation prevents suspended Main mutation")
    try await controller.refreshForUser()
    transport.hold = true
    let first = Task { try await controller.changeVolumeForUser(id: 0, db: -8) }
    try await eventually("Serialized Main fixture never suspended") { transport.continuation != nil }
    let readCount = transport.reads
    let second = Task { try await controller.changeVolumeForUser(id: 1, db: -4) }
    await Task.yield()
    try check(transport.reads == readCount, "Aux command cannot overlap suspended Main transaction")
    transport.hold = false; transport.continuation?.resume(); transport.continuation = nil
    try await first.value; try await second.value
    try check(Array(transport.writes.suffix(3)) == [0, 1, 2] && transport.main.volumeDB == -8,
              "Concurrent Main and linked Aux commands share one ordered queue")
    transport.hold = true
    let pending = Task { try await controller.changeVolumeForUser(id: 0, db: -30) }
    try await eventually("Main fixture never suspended") { transport.continuation != nil }
    controller.activate(profile: nil, ready: false)
    transport.hold = false; transport.continuation?.resume(); transport.continuation = nil
    do { try await pending.value; throw CheckFailure.failed("Stale Main edit accepted") } catch is CancellationError {}
    try check(controller.snapshot.main == nil && !controller.snapshot.ready && transport.main.volumeDB == -8, "Profile loss clears Main authority and cancels old writes")
    transport.faders = []
    controller.activate(profile: profile)
    try await controller.refreshForUser()
    try check(controller.snapshot.main != nil && controller.snapshot.faders.isEmpty && controller.snapshot.preferences.visibleIDs.isEmpty, "Main works without any configured Aux filters")
    for (name, passed) in MainVolumeDisplayVerification.checks() { try check(passed, "Main native row: " + name) }
    if let path = ProcessInfo.processInfo.environment["AUTOSWITCH_PANEL_RENDER_DIR"] { try MainVolumeDisplayVerification.render(to: URL(fileURLWithPath: path, isDirectory: true)) }
    print("Main volume checks: isolation, limits, readback, stale confirmation, drag, cancellation, serialization, empty Aux and native presentation passed")
}
