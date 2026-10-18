import Foundation
import AutoAudioCore

@MainActor private final class FakeAuxTransport: AuxDSPTransport {
    var faders = [AuxFader(id: 1, name: "Aux 1", volumeDB: -20, muted: true, maximumDB: 0),
                  AuxFader(id: 3, name: "Aux 3", volumeDB: -10, muted: false, maximumDB: 2)]
    var reads = 0
    var writes: [String] = []
    var failureID: Int?
    var ignoreWrites = false
    var holdRead = false
    var waiting: CheckedContinuation<Void, Never>?
    var cancellations = 0
    var holdWrite = false
    var waitingWrite: CheckedContinuation<Void, Never>?
    func read(profile: Profile) async throws -> AuxDSPState {
        reads += 1
        if holdRead { await withCheckedContinuation { waiting = $0 } }
        return AuxDSPState(faders: faders)
    }
    func setVolume(id: Int, db: Double) async throws {
        if holdWrite { await withCheckedContinuation { waitingWrite = $0 } }
        if failureID == id { throw SwitcherError.message("fixture write failure") }
        writes.append("volume:\(id)")
        if !ignoreWrites, let index = faders.firstIndex(where: { $0.id == id }) { faders[index].volumeDB = db }
    }
    func setMute(id: Int, muted: Bool) async throws {
        if failureID == id { throw SwitcherError.message("fixture write failure") }
        writes.append("mute:\(id)")
        if !ignoreWrites, let index = faders.firstIndex(where: { $0.id == id }) { faders[index].muted = muted }
    }
    func cancel() { cancellations += 1 }
}
@MainActor func runAuxFaderChecks() async throws {
    let profile = Profile(id: "aux-test", name: "Aux test", triggerUID: "trigger", captureUID: "capture",
                          playbackUID: "playback", launchAgentLabel: "aux-test", launchAgentPath: "/unused",
                          websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
    let transport = FakeAuxTransport()
    var saved: [String: AuxPreferences] = [:]
    var failSave = false
    let controller = AuxController(transport: transport, loadPreferences: { saved[$0] }, savePreferences: { id, preferences in
        if failSave { throw SwitcherError.message("fixture preferences failure") }; saved[id] = preferences
    })
    controller.activate(profile: profile)
    try check(transport.reads == 0, "Activating Aux installs no automatic or recurring reads")
    await controller.refresh()
    try check(controller.snapshot.preferences.visibleIDs == [1, 3], "Absent preferences default to applicable sparse Aux IDs")
    try controller.setPreferences(AuxPreferences(visibleIDs: [], labels: ["3": "Rear"], linkGroups: [[1, 3]]))
    try check(controller.snapshot.preferences.visibleIDs.isEmpty && controller.snapshot.faders[1].name == "Rear", "Explicit hide all and labels persist independently of DSP writes")
    try check(transport.writes.isEmpty, "Preference edits issue no DSP mutations")
    try check(controller.snapshot.preferences.lastVisibleIDs == [1, 3], "Explicit empty visibility remembers the previously displayed subset")
    let hideWrites = transport.writes
    let hideLevels = transport.faders
    var subset = controller.snapshot.preferences
    subset.visibleIDs = [3]; subset.linkMutes = false
    try controller.setPreferences(subset)
    let configured = controller.snapshot.preferences
    try controller.setPreferences(configured.hidingVisibility())
    try controller.setPreferences(controller.snapshot.preferences)
    try check(controller.snapshot.preferences.lastVisibleIDs == [3], "Repeated hidden settings saves retain the selected subset")
    let persistedHidden = saved[profile.id]!
    try controller.setPreferences(persistedHidden.restoringVisibility(availableIDs: [1, 3]))
    try check(controller.snapshot.preferences.visibleIDs == [3] && controller.snapshot.preferences.labels == configured.labels &&
              controller.snapshot.preferences.linkGroups == configured.linkGroups && !controller.snapshot.preferences.linkMutes,
              "Restore recovers the prior subset with labels and both link policies preserved")
    try check(transport.writes == hideWrites && transport.faders == hideLevels, "Hide and restore change no DSP levels or mute values")
    try check(AuxPreferences(lastVisibleIDs: [2, 3]).restoringVisibility(availableIDs: [1, 3]).visibleIDs == [3], "Restore excludes unavailable faders")
    try check(AuxPreferences(lastVisibleIDs: [2]).restoringVisibility(availableIDs: [1, 3]).visibleIDs.isEmpty, "A remembered unavailable subset does not enable unrelated faders")
    try check(AuxPreferences(lastVisibleIDs: [3]).restoringVisibility().visibleIDs == [3], "Offline restore recovers remembered preferences without fabricating DSP controls")
    try check(AuxPreferences().restoringVisibility(availableIDs: [3, 1, 1, 9]).visibleIDs == [1, 3], "Restore without memory defaults to applicable valid faders")
    var hiddenLinked = controller.snapshot.preferences.hidingVisibility(); hiddenLinked.linkMutes = true
    try controller.setPreferences(hiddenLinked)
    await controller.refresh()
    try check(controller.snapshot.preferences.visibleIDs.isEmpty, "Hide all is preserved on refresh")
    transport.faders[1].volumeDB = 5
    await controller.refresh()
    try check(controller.snapshot.ready && controller.snapshot.faders[1].volumeDB == 5, "External gain above configured Volume limit is displayed without disabling valid Aux readings")
    transport.faders[1].volumeDB = -10
    await controller.changeVolume(id: 1, db: 0)
    try check(transport.faders.map(\.volumeDB) == [-8, 2], "Linked movement applies common offset clamped by tightest upper limit")
    try check(transport.faders[0].muted, "Changing a muted fader never unmutes it")
    await controller.changeVolume(id: 3, db: -150)
    try check(transport.faders.map(\.volumeDB) == [-150, -140], "Linked movement preserves offsets at tightest lower limit")
    await controller.setMute(id: 3, muted: true)
    try check(transport.faders.allSatisfy(\.muted), "Explicit mute resolves mixed group states including hidden members")
    await controller.setMute(id: 1, muted: false)
    try check(transport.faders.allSatisfy { !$0.muted }, "Explicit unmute applies to each group member")
    var independentMute = controller.snapshot.preferences
    independentMute.linkMutes = false
    try controller.setPreferences(independentMute)
    await controller.setMute(id: 3, muted: true)
    try check(!transport.faders[0].muted && transport.faders[1].muted,
              "Mute Link off permits individual mute while volume stays linked")
    try check(controller.snapshot.preferences.linkGroups == [[1, 3]], "Mute Link toggle preserves level groups")
    await controller.setMute(id: 3, muted: false)
    independentMute.linkMutes = true
    try controller.setPreferences(independentMute)
    transport.faders[0].volumeDB = -20; transport.faders[1].volumeDB = -7
    await controller.changeVolume(id: 1, db: -25)
    try check(transport.faders.map(\.volumeDB) == [-25, -12], "Linked movement reads fresh externally edited values before computing offsets")
    try controller.setPreferences(AuxPreferences(visibleIDs: [], linkGroups: [[1, 2]]))
    let writesBeforeMissing = transport.writes.count
    await controller.changeVolume(id: 1, db: -30)
    try check(transport.writes.count == writesBeforeMissing && controller.snapshot.error?.contains("linked Aux") == true, "Missing linked member rejects the entire command before any write")
    try controller.setPreferences(AuxPreferences(visibleIDs: [], labels: ["3": "Rear"], linkGroups: [[1, 3]]))
    transport.holdRead = true
    let first = Task { await controller.changeVolume(id: 1, db: -26) }
    while transport.waiting == nil { await Task.yield() }
    let secondCommand = Task { await controller.changeVolume(id: 1, db: -27) }
    for _ in 0..<3 { await Task.yield() }
    try check(!controller.snapshot.preferencesEditable, "Preferences cannot change links during queued commands")
    do { try controller.setPreferences(AuxPreferences()); throw CheckFailure.failed("Busy preferences accepted") }
    catch is SwitcherError {}
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    await first.value; await secondCommand.value
    try check(transport.faders.map(\.volumeDB) == [-27, -14] && !controller.snapshot.busy, "Concurrent commands serialize fresh reads and final linked movement")
    transport.faders[0].volumeDB = -25; transport.faders[1].volumeDB = -12
    let lastGood = controller.snapshot.preferences
    failSave = true
    do { try controller.setPreferences(AuxPreferences(visibleIDs: [1])); throw CheckFailure.failed("Preference failure accepted") }
    catch is SwitcherError {}
    try check(controller.snapshot.preferences == lastGood && controller.snapshot.error != nil, "Failed preference save retains last good preferences and reports error")
    failSave = false
    transport.failureID = 3
    await controller.changeVolume(id: 1, db: -30)
    try check(controller.snapshot.error?.contains("partially") == true && controller.snapshot.faders[0].volumeDB == -30 && controller.snapshot.faders[1].volumeDB == -12, "Partial linked failure rereads actual values and reports failure")
    transport.failureID = nil; transport.ignoreWrites = true
    await controller.changeVolume(id: 1, db: -35)
    try check(controller.snapshot.error?.contains("did not confirm") == true, "Ignored DSP writes cannot be reported as successful")
    transport.ignoreWrites = false
    let reads = transport.reads
    for _ in 0..<10 { await Task.yield() }
    try check(transport.reads == reads, "Idle Aux controller performs no recurring polling")
    transport.holdRead = true
    let stale = Task { await controller.changeVolume(id: 1, db: -40) }
    while transport.waiting == nil { await Task.yield() }
    let writes = transport.writes.count
    controller.activate(profile: profile, ready: false)
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    await stale.value
    try check(transport.writes.count == writes && !controller.snapshot.ready && !controller.snapshot.busy, "Readiness loss cancels delayed requests before writes or stale snapshot application")
    try controller.setPreferences(AuxPreferences(visibleIDs: [3]))
    try check(controller.snapshot.preferences.visibleIDs == [3], "Aux preferences remain editable while DSP is off")
    await controller.refresh()
    try check(transport.reads == reads + 1, "Unavailable DSP cannot be refreshed")
    controller.activate(profile: profile, ready: true)
    await controller.refresh()
    try check(controller.snapshot.ready, "Returning readiness permits explicit refresh")
    var second = profile; second.id = "second"
    controller.activate(profile: second, ready: false)
    try check(controller.snapshot.profileID == "second" && controller.snapshot.faders.isEmpty && controller.snapshot.preferences.visibleIDs.isEmpty, "Profile switch resets cached faders and scopes preferences")
    controller.activate(profile: profile, ready: false)
    try check(controller.snapshot.preferences.visibleIDs == [3], "Profile preferences reload independently")
    let corrupt = AuxController(transport: FakeAuxTransport(), loadPreferences: { _ in throw SwitcherError.message("corrupt file") }, savePreferences: { _, _ in throw CheckFailure.failed("Must not overwrite corrupt preferences") })
    corrupt.activate(profile: profile, ready: false)
    do { try corrupt.setPreferences(AuxPreferences()); throw CheckFailure.failed("Corrupt preference overwrite accepted") }
    catch is SwitcherError {}
    try check(!corrupt.snapshot.preferencesEditable && corrupt.snapshot.error?.contains("Cannot load") == true, "Preference loading failures remain actionable and prevent overwrite")
    for invalid in [AuxPreferences(visibleIDs: [1, 1]), AuxPreferences(linkGroups: [[1, 2], [2, 3]]), AuxPreferences(labels: ["5": "Invalid"]), AuxPreferences(lastVisibleIDs: [1, 1]), AuxPreferences(lastVisibleIDs: [5])] {
        do { _ = try invalid.validated(); throw CheckFailure.failed("Malformed Aux preferences accepted") }
        catch is SwitcherError {}
    }
    let legacy = try JSONDecoder().decode(AuxPreferences.self, from: Data(#"{"visibleIDs":[1,3],"labels":{},"linkGroups":[[1,3]]}"#.utf8))
    try check(legacy.sliderMinimumDB == -150 && legacy.linkMutes && legacy.lastVisibleIDs == [1, 3], "Existing saved preferences retain linked mute behavior and visible subset memory")
    let separate = try AuxPreferences(visibleIDs: [1, 3], linkGroups: [[1, 3]], linkMutes: false, lastVisibleIDs: [3]).validated()
    let roundTrip = try JSONDecoder().decode(AuxPreferences.self, from: JSONEncoder().encode(separate))
    try check(!roundTrip.linkMutes && roundTrip.linkGroups == [[1, 3]] && roundTrip.lastVisibleIDs == [3], "Mute Link off and visibility memory survive validation and persistence")
    try await runAuxProposalChecks(profile: profile)
    try await runAuxLiveDragChecks(profile: profile)
    try await runAuxIndividualGestureChecks(profile: profile)
    print("Aux checks: sparse defaults, visibility, links, clamps, fresh reads, mixed mute, cancellation and failures passed")
}

@MainActor private func runAuxIndividualGestureChecks(profile: Profile) async throws {
    let transport = FakeAuxTransport()
    let preferences = AuxPreferences(visibleIDs: [1], linkGroups: [[1, 3]])
    let controller = AuxController(transport: transport, loadPreferences: { _ in preferences }, savePreferences: { _, _ in })
    controller.activate(profile: profile); await controller.refresh()
    try check(controller.beginVolumeDrag(id: 1, intent: .individual), "Individual Aux intent starts a scoped drag without unlinking")
    transport.holdRead = true
    controller.updateVolumeDrag(id: 1, db: -35)
    while transport.waiting == nil { await Task.yield() }
    // A different member may change independently while this drag is active.
    transport.faders[1].volumeDB = -9; transport.faders[1].maximumDB = -5
    controller.endVolumeDrag(id: 1, db: -35)
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    while controller.snapshot.busy { await Task.yield() }
    try check(transport.writes == ["volume:1"] && transport.faders.map(\.volumeDB) == [-35, -9],
              "Individual drag writes only its target and preserves another member's external change")
    try check(controller.snapshot.preferences == preferences && transport.faders[0].muted,
              "Individual trim keeps links, visibility and mute states")
    try check(controller.beginVolumeDrag(id: 1), "Normal linked drag remains available after individual trim")
    controller.endVolumeDrag(id: 1, db: -45)
    while controller.snapshot.busy { await Task.yield() }
    try check(transport.faders.map(\.volumeDB) == [-45, -19], "Next group movement preserves the newly trimmed balance")
    let otherDB = transport.faders[1].volumeDB
    try await controller.changeVolumeForUser(id: 1, db: 4, intent: .individual)
    try check(transport.faders.map(\.volumeDB) == [0, otherDB], "Individual discrete volume obeys the selected Aux maximum only")
    transport.writes.removeAll()
    try await controller.setMuteForUser(id: 1, muted: false, intent: .individual)
    try check(transport.writes == ["mute:1"] && transport.faders.map(\.muted) == [false, false],
              "Individual mute bypasses linked mute scope without changing its preference")
    try await controller.setMuteForUser(id: 3, muted: true, intent: .individual)
    try check(transport.faders.map(\.muted) == [false, true] && controller.snapshot.preferences.linkMutes,
              "Individual mute can produce mixed group states while keeping linked mute enabled")
    try await controller.setMuteForUser(id: 1, muted: true)
    try check(transport.faders.allSatisfy(\.muted), "Normal linked mute still affects all members after individual mute")
    try check(controller.beginVolumeDrag(id: 1, intent: .individual), "Individual drag starts cancellation fixture")
    transport.holdRead = true
    controller.updateVolumeDrag(id: 1, db: -60)
    while transport.waiting == nil { await Task.yield() }
    let writes = transport.writes
    controller.activate(profile: profile, ready: false)
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    for _ in 0..<30 { await Task.yield() }
    try check(transport.writes == writes && !controller.snapshot.busy && !controller.snapshot.ready,
              "Readiness loss cancels individual drag before its setter and never replays its target")
}

@MainActor private func runAuxLiveDragChecks(profile: Profile) async throws {
    let transport = FakeAuxTransport()
    let controller = AuxController(transport: transport, loadPreferences: { _ in
        AuxPreferences(visibleIDs: [1], linkGroups: [[1, 3]])
    }, savePreferences: { _, _ in })
    controller.activate(profile: profile)
    await controller.refresh()
    let initialReads = transport.reads
    try check(controller.beginVolumeDrag(id: 1), "A ready linked group starts one drag session")
    for _ in 0..<20 { await Task.yield() }
    try check(transport.reads == initialReads && transport.writes.isEmpty, "A drag waiting for input performs no polling or writes")
    transport.holdRead = true
    controller.updateVolumeDrag(id: 1, db: -22)
    while transport.waiting == nil { await Task.yield() }
    for target in -30 ... -23 { controller.updateVolumeDrag(id: 1, db: Double(target)) }
    controller.endVolumeDrag(id: 1, db: -31.25)
    await controller.setMute(id: 1, muted: false)
    try check(transport.writes.isEmpty, "Mute cannot bypass the serialized active drag")
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    while controller.snapshot.busy { await Task.yield() }
    try check(transport.faders.map(\.volumeDB) == [-31.25, -21.25], "Final exact target applies to visible and hidden linked members")
    try check(transport.writes.count == 4 && transport.reads == initialReads + 4, "Intermediate targets coalesce into one latest slot instead of a backlog")
    let finishedReads = transport.reads
    for _ in 0..<20 { await Task.yield() }
    try check(transport.reads == finishedReads, "Finished drag leaves no idle polling")
    try check(controller.beginVolumeDrag(id: 1), "A confirmed drag permits a later session")
    transport.holdRead = true
    controller.updateVolumeDrag(id: 1, db: -40)
    while transport.waiting == nil { await Task.yield() }
    let writesBeforeCancel = transport.writes.count
    controller.cancelVolumeDrag()
    controller.updateVolumeDrag(id: 1, db: -50)
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    while controller.snapshot.busy { await Task.yield() }
    try check(!controller.snapshot.busy && transport.writes.count == writesBeforeCancel, "Cancel invalidates in-flight reads and drops pending targets")
    try check(controller.beginVolumeDrag(id: 1), "A fresh drag can exercise cancellation during a setter")
    transport.holdWrite = true
    controller.updateVolumeDrag(id: 1, db: -34)
    while transport.waitingWrite == nil { await Task.yield() }
    controller.cancelVolumeDrag()
    let readsBeforeDrain = transport.reads
    let refreshAfterCancel = Task { await controller.refresh() }
    for _ in 0..<20 { await Task.yield() }
    try check(transport.reads == readsBeforeDrain, "New read waits for a canceled in-flight setter to drain")
    transport.holdWrite = false; transport.waitingWrite?.resume(); transport.waitingWrite = nil
    await refreshAfterCancel.value
    try check(transport.faders.map(\.volumeDB) == [-34, -21.25] && controller.snapshot.faders.map(\.volumeDB) == [-34, -21.25],
              "Cancellation skips remaining linked setters and a later refresh confirms actual partial application")
    transport.failureID = 3
    try check(controller.beginVolumeDrag(id: 1), "A canceled drag releases serialization")
    transport.holdRead = true
    controller.updateVolumeDrag(id: 1, db: -35)
    while transport.waiting == nil { await Task.yield() }
    controller.endVolumeDrag(id: 1, db: -55)
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    while controller.snapshot.busy { await Task.yield() }
    try check(transport.faders.map(\.volumeDB) == [-35, -21.25] && controller.snapshot.error?.contains("partially") == true,
              "Partial drag failure rereads actual values and stops without replaying the latest gain")
    transport.failureID = nil
    await controller.refresh()
    try check(controller.beginVolumeDrag(id: 1), "A refreshed group may start a new drag")
    transport.holdRead = true
    controller.updateVolumeDrag(id: 1, db: -36)
    while transport.waiting == nil { await Task.yield() }
    let writesBeforeLinks = transport.writes.count
    try controller.setPreferences(AuxPreferences(visibleIDs: [1], linkGroups: []))
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    while controller.snapshot.busy { await Task.yield() }
    try check(!controller.snapshot.busy && transport.writes.count == writesBeforeLinks && controller.snapshot.preferences.linkGroups.isEmpty,
              "Link policy changes cancel drag targets before applying new preferences")
    try check(controller.beginVolumeDrag(id: 1), "Independent fader can start after a link change")
    transport.holdRead = true
    controller.updateVolumeDrag(id: 1, db: -37)
    while transport.waiting == nil { await Task.yield() }
    let writesBeforeLifecycle = transport.writes.count
    controller.activate(profile: profile, ready: false)
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    for _ in 0..<20 { await Task.yield() }
    try check(!controller.snapshot.ready && !controller.snapshot.busy && transport.writes.count == writesBeforeLifecycle,
              "Readiness loss cancels live drag before stale writes")
}

@MainActor private func runAuxProposalChecks(profile: Profile) async throws {
    let transport = FakeAuxTransport()
    transport.faders[0].volumeDB = -20; transport.faders[1].volumeDB = -25
    let preferences = AuxPreferences(visibleIDs: [1], linkGroups: [[1, 3]], sliderMinimumDB: -60)
    let controller = AuxController(transport: transport, loadPreferences: { _ in preferences }, savePreferences: { _, _ in })
    controller.activate(profile: profile)
    await controller.refresh()
    let proposal = try await controller.prepareVolumeChange(id: 1, db: -999)
    try check(proposal.requestedDB == -999 && proposal.effectiveDB == -150 && proposal.linked && transport.writes.isEmpty,
              "Finite precise lower outliers normalize independently of the slider floor, with a read-only proposal")
    try check(proposal.group.faders.map(\.volumeDB) == [-145, -150] && proposal.group.available && proposal.group.reason != nil,
              "Group preview includes hidden members and preserves offsets at their true lower bounds")
    try check(proposal.individual.faders.map(\.volumeDB) == [-150] && proposal.individual.available,
              "Individual preview uses the selected fader's true bounds independently of the slider range")
    let applied = try await controller.applyVolumeChange(proposal: proposal, intent: .individual)
    try check(applied == nil && transport.faders.map(\.volumeDB) == [-150, -25] && controller.snapshot.preferences == preferences,
              "Trim changes only one fader while preserving the saved level group and slider floor")
    let noOp = try await controller.prepareVolumeChange(id: 1, db: -150)
    let writesBeforeNoOp = transport.writes.count
    _ = try await controller.applyVolumeChange(proposal: noOp, intent: .individual)
    try check(!noOp.changed && transport.writes.count == writesBeforeNoOp, "Unchanged precise values write nothing")
    transport.faders[0].volumeDB = -20; transport.faders[1].volumeDB = -25
    let preview = try await controller.prepareVolumeChange(id: 1, db: -40)
    transport.faders[1].volumeDB = -28; transport.faders[1].maximumDB = -5
    let writesBeforeStale = transport.writes.count
    guard let renewed = try await controller.applyVolumeChange(proposal: preview, intent: .group) else {
        throw CheckFailure.failed("Stale precise proposal applied without renewed confirmation")
    }
    try check(transport.writes.count == writesBeforeStale && renewed.group.faders.map(\.volumeDB) == [-40, -48],
              "External hidden-member level and limit changes renew consequences without writing")
    _ = try await controller.applyVolumeChange(proposal: renewed, intent: .group)
    try check(transport.faders.map(\.volumeDB) == [-40, -48], "Renewed Group confirmation preserves fresh linked offsets")
    let above = try await controller.prepareVolumeChange(id: 1, db: 30)
    try check(!above.group.available && !above.individual.available && above.effectiveDB == 30,
              "Typed upper outliers remain unavailable and are never silently clamped")
    let writesBeforeInvalid = transport.writes.count
    for invalid in [Double.nan, Double.infinity, -Double.infinity] {
        do { _ = try await controller.prepareVolumeChange(id: 1, db: invalid); throw CheckFailure.failed("Nonfinite precise target accepted") }
        catch is SwitcherError {}
    }
    try check(transport.writes.count == writesBeforeInvalid, "Nonfinite entry has no DSP side effects")
    let membership = try await controller.prepareVolumeChange(id: 1, db: -50)
    var unlinked = preferences; unlinked.linkGroups = []
    try controller.setPreferences(unlinked)
    let membershipResult = try await controller.applyVolumeChange(proposal: membership, intent: .group)
    try check(membershipResult?.linked == false && transport.writes.count == writesBeforeInvalid,
              "Membership edits require a new confirmation instead of applying stale linked consequences")
    try check(controller.beginVolumeDrag(id: 1), "Fixture can reject an explicit user refresh during tracking")
    do { try await controller.refreshForUser(); throw CheckFailure.failed("Active drag refresh silently accepted") }
    catch is SwitcherError {}
    let readsBeforeRejection = transport.reads
    let writesBeforeRejection = transport.writes.count
    do { try await controller.changeVolumeForUser(id: 1, db: -60); throw CheckFailure.failed("Active drag discrete gain silently accepted") }
    catch is SwitcherError {}
    do { try await controller.setMuteForUser(id: 1, muted: true); throw CheckFailure.failed("Active drag discrete mute silently accepted") }
    catch is SwitcherError {}
    try check(transport.reads == readsBeforeRejection && transport.writes.count == writesBeforeRejection,
              "Strict discrete gain and mute rejection during a drag reports failure without issuing DSP operations")
    controller.cancelVolumeDrag()
    while controller.snapshot.busy { await Task.yield() }
    transport.failureID = 1
    let writesBeforeFailure = transport.writes.count
    do { try await controller.changeVolumeForUser(id: 1, db: -70); throw CheckFailure.failed("Setter failure silently accepted by strict gain command") }
    catch is SwitcherError {}
    try check(transport.writes.count == writesBeforeFailure && controller.snapshot.error?.contains("partially") == true,
              "Strict gain returns an actionable setter failure and never replays the target")
    transport.failureID = nil
    await controller.refresh()
    transport.holdRead = true
    let delayedStrict = Task { () -> Bool in
        do { try await controller.changeVolumeForUser(id: 1, db: -75); return false }
        catch is CancellationError { return true }
        catch { return false }
    }
    while transport.waiting == nil { await Task.yield() }
    controller.activate(profile: profile, ready: false)
    transport.holdRead = false; transport.waiting?.resume(); transport.waiting = nil
    let canceledStrict = await delayedStrict.value
    try check(canceledStrict && transport.writes.count == writesBeforeFailure,
              "Authority loss during strict fresh read returns cancellation instead of a stale success or write")
    do { try await controller.changeVolumeForUser(id: 1, db: -70); throw CheckFailure.failed("Unavailable strict gain silently accepted") }
    catch is SwitcherError {}
    do { try await controller.setMuteForUser(id: 1, muted: true); throw CheckFailure.failed("Unavailable strict mute silently accepted") }
    catch is SwitcherError {}
    try check(transport.writes.count == writesBeforeFailure, "Lost authority rejects strict gain and mute before writes")
    do { try await controller.refreshForUser(); throw CheckFailure.failed("Unavailable refresh silently accepted") }
    catch is SwitcherError {}
    for minimum in [Double.nan, Double.infinity, -151, 51] {
        var invalid = preferences; invalid.sliderMinimumDB = minimum
        do { _ = try invalid.validated(); throw CheckFailure.failed("Invalid slider floor accepted") }
        catch is SwitcherError {}
    }
    let persisted = try JSONDecoder().decode(AuxPreferences.self, from: JSONEncoder().encode(preferences.validated()))
    try check(persisted.sliderMinimumDB == -60, "One profile slider floor survives validated persistence")
}
