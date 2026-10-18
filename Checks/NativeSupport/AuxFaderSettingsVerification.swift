import AppKit
import AutoAudioCore
import AutoAudioPlatform

enum AuxFaderSettingsVerification {
    @MainActor static func stagedSettingsChecks() async -> [String: Bool] { await verifyAutosaveSettings() }
}

extension AuxFaderSettingsContent {
    func linkingSectionsAreSeparated() -> Bool {
        let arranged = stack.arrangedSubviews
        guard let linkIndex = arranged.firstIndex(of: linkMutes),
              let noticeIndex = arranged.firstIndex(of: notice),
              let rangeIndex = arranged.firstIndex(where: { ($0 as? NSTextField)?.stringValue == "Slider Range" }),
              let minimumIndex = arranged.firstIndex(where: { $0 === minimum.superview }) else { return false }
        return noticeIndex == linkIndex + 1 && rangeIndex == noticeIndex + 2 && minimumIndex == rangeIndex + 1
            && (arranged[noticeIndex + 1] as? NSBox)?.boxType == .separator
    }
}

@MainActor private final class AuxSettingsSaveGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}

@MainActor private func waitForAuxGate(_ gate: AuxSettingsSaveGate) async -> Bool {
    for _ in 0..<1000 { if gate.entered { return true }; await Task.yield() }
    return false
}

@MainActor private func verifyAutosaveSettings() async -> [String: Bool] {
    _ = NSApplication.shared
    let preferences = AuxPreferences(visibleIDs: [1, 3], labels: ["1": "Left"], linkGroups: [[1, 2]],
        linkMutes: false, lastVisibleIDs: [1, 3], sliderMinimumDB: -80)
    var fixture = AuxFaderSnapshot(profileID: "fixture", faders: [
        AuxFader(id: 1, name: "Aux 1", volumeDB: -3, muted: false, maximumDB: 50),
        AuxFader(id: 2, name: "Aux 2", volumeDB: -6, muted: false, maximumDB: 50),
        AuxFader(id: 3, name: "Aux 3", volumeDB: 0, muted: false, maximumDB: 50)], preferences: preferences, ready: true)
    var result: [String: Bool] = [:]
    var saved: [AuxPreferences] = []
    var attempts = 0
    var rejectSave = true
    let controller = AuxFaderSettingsWindow(snapshot: fixture) { preferences in
        attempts += 1
        if rejectSave { throw SwitcherError.message("Fixture persistence failure") }
        saved.append(preferences)
    }
    defer { controller.close() }
    let content = controller.content
    func edit(_ field: NSTextField, _ value: String) {
        field.stringValue = value
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func selectGroup(_ id: Int, _ group: Int) {
        let popup = content.rows[id]!.group
        popup.selectItem(at: group); _ = NSApp.sendAction(popup.action!, to: popup.target, from: popup)
    }
    result["linking notice precedes separate Slider Range section"] = content.linkingSectionsAreSeparated()
    result["trim includes hidden member and stable reference"] = content.notice.stringValue.contains("Aux 2: -6.0 dB (-3.0 dB vs Aux 1)")
    var busyFixture = fixture; busyFixture.busy = true; busyFixture.preferencesEditable = false
    content.updateSnapshot(busyFixture)
    result["ordinary busy operation disables saves without a red availability warning"] = content.availabilityMessage == nil
        && content.errorLabel.stringValue.isEmpty && !content.minimum.isEnabled
    content.updateSnapshot(fixture)
    let deferredBusy = AuxFaderSettingsContent(snapshot: fixture)
    var busyWrites: [AuxPreferences] = []
    deferredBusy.onSave = { _, preferences in busyWrites.append(preferences) }
    deferredBusy.rows[1]!.label.stringValue = "Draft during busy"
    deferredBusy.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
        object: deferredBusy.rows[1]!.label))
    var busySnapshot = fixture; busySnapshot.busy = true; busySnapshot.preferencesEditable = false
    deferredBusy.updateSnapshot(busySnapshot)
    result["busy snapshot preserves drafts without a warning"] = deferredBusy.rows[1]?.label.stringValue == "Draft during busy"
        && deferredBusy.availabilityMessage == nil && deferredBusy.errorLabel.stringValue.isEmpty
    deferredBusy.updateSnapshot(fixture)
    await deferredBusy.waitForPendingChanges()
    result["retained busy draft saves when authority becomes eligible"] = busyWrites.last?.labels["1"] == "Draft during busy"
    edit(content.minimum, "-65")
    await content.waitForPendingChanges()
    result["failed autosave retains editable pending input and actionable error"] = saved.isEmpty && attempts == 1
        && content.minimum.stringValue == "-65" && content.minimum.isEnabled && content.hasUnsavedChanges
        && content.errorLabel.stringValue.contains("Fixture persistence failure")
    for _ in 0..<3 { content.updateSnapshot(fixture); await Task.yield() }
    result["failed autosave does not retry on repeated snapshots"] = attempts == 1
    rejectSave = false
    edit(content.rows[1]!.label, "Updated Left")
    await content.waitForPendingChanges()
    result["next edit retries previous failure without Apply"] = saved.count == 1 && saved.last?.sliderMinimumDB == -65
        && saved.last?.labels["1"] == "Updated Left" && !content.hasUnsavedChanges

    edit(content.minimum, "-")
    selectGroup(3, 2)
    edit(content.rows[2]!.label, "Right")
    content.linkMutes.performClick(nil)
    await content.waitForPendingChanges()
    result["incomplete floor and singleton group cannot block independent labels or mutes"] = saved.last?.sliderMinimumDB == -65
        && saved.last?.linkGroups == [[1, 2]] && saved.last?.labels["2"] == "Right" && saved.last?.linkMutes == true
        && content.minimum.stringValue == "-" && content.errorLabel.stringValue.contains("Slider minimum")
    edit(content.minimum, "")
    await content.waitForPendingChanges()
    result["empty floor retains last valid preference"] = saved.last?.sliderMinimumDB == -65 && content.minimum.stringValue.isEmpty
    edit(content.minimum, "-70")
    selectGroup(4, 2)
    await content.waitForPendingChanges()
    result["completing a valid group commits its complete membership"] = saved.last?.linkGroups == [[1, 2], [3, 4]]
        && saved.last?.sliderMinimumDB == -70 && !content.hasUnsavedChanges
    content.toggleVisibility(); await content.waitForPendingChanges()
    result["Hide All saves visibility and remembered subset together"] = saved.last?.visibleIDs == [] && saved.last?.lastVisibleIDs == [1, 3]
    content.toggleVisibility(); await content.waitForPendingChanges()
    result["Restore Previous saves the remembered subset"] = saved.last?.visibleIDs == [1, 3]
    var floorsValid = true
    for invalid in ["nan", "inf", "-151", "51", "invalid"] {
        content.minimum.stringValue = invalid
        if (try? content.draftPreferences()) != nil { floorsValid = false }
    }
    content.minimum.stringValue = "-150"
    floorsValid = floorsValid && (try? content.draftPreferences().sliderMinimumDB) == -150
    content.minimum.stringValue = "50"
    floorsValid = floorsValid && (try? content.draftPreferences().sliderMinimumDB) == 50
    result["floor validates finite inclusive bounds"] = floorsValid
    edit(content.minimum, "-55")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let buttons = descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }
    result["standalone Aux settings has only Close action"] = !buttons.contains { ["Save", "Apply", "Cancel"].contains($0.title) }
    buttons.first { $0.title == "Close" }?.performClick(nil)
    await content.waitForPendingChanges()
    result["Close flushes valid pending Aux edit without discarding it"] = saved.last?.sliderMinimumDB == -55 && controller.window?.isVisible == false

    // Keep one save suspended while newer text and unrelated groups change.
    let coalesced = AuxFaderSettingsContent(snapshot: fixture)
    let gate = AuxSettingsSaveGate()
    var coalescedWrites: [AuxPreferences] = []
    var activeWrites = 0
    var maximumActiveWrites = 0
    coalesced.onSave = { _, preferences in
        activeWrites += 1; maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        if coalescedWrites.isEmpty { await gate.wait() }
        coalescedWrites.append(preferences); activeWrites -= 1
    }
    coalesced.rows[1]!.label.stringValue = "First"
    coalesced.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: coalesced.rows[1]!.label))
    coalesced.flushPendingChanges()
    let entered = await waitForAuxGate(gate)
    coalesced.rows[1]!.label.stringValue = "Latest"
    coalesced.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: coalesced.rows[1]!.label))
    coalesced.minimum.stringValue = "-60"
    coalesced.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: coalesced.minimum))
    fixture.faders[1].volumeDB = -9
    coalesced.updateSnapshot(fixture)
    result["in-flight save keeps inputs editable and stale snapshots preserve newer edits"] = entered
        && coalesced.minimum.isEnabled && coalesced.rows[1]?.label.stringValue == "Latest" && coalesced.minimum.stringValue == "-60"
        && coalesced.notice.stringValue.contains("-6.0 dB vs Aux 1")
    gate.release(); await coalesced.waitForPendingChanges()
    result["Aux persistence serializes and coalesces latest edits across awaits"] = maximumActiveWrites == 1 && coalescedWrites.count == 2
        && coalescedWrites.first?.labels["1"] == "First" && coalescedWrites.last?.labels["1"] == "Latest"
        && coalescedWrites.last?.sliderMinimumDB == -60 && !coalesced.hasUnsavedChanges
    coalesced.updateSnapshot(fixture)
    result["successful callback retains local values until matching snapshot confirms them"] = coalesced.rows[1]?.label.stringValue == "Latest"
        && coalesced.minimum.stringValue == "-60"
    var confirmed = fixture; confirmed.preferences = coalescedWrites.last!
    coalesced.updateSnapshot(confirmed)
    confirmed.preferences.labels["1"] = "External update"; coalesced.updateSnapshot(confirmed)
    result["confirmed clean inputs accept later external preference changes"] = coalesced.rows[1]?.label.stringValue == "External update"
    confirmed.ready = false; coalesced.updateSnapshot(confirmed)
    result["offline notice never invents current levels"] = coalesced.notice.stringValue.contains("current levels unavailable")
        && !coalesced.notice.stringValue.contains("-9.0 dB")

    // The production owner canonicalizes remembered visibility and publishes
    // during the save callback, rather than guaranteeing another snapshot later.
    var normalizationSnapshot = fixture
    normalizationSnapshot.preferences.visibleIDs = [1, 2]
    normalizationSnapshot.preferences.lastVisibleIDs = [1, 2, 3, 4]
    let normalized = AuxFaderSettingsContent(snapshot: normalizationSnapshot)
    var normalizedWrites: [AuxPreferences] = []
    normalized.onSave = { _, submitted in
        var accepted = try submitted.validated()
        if !accepted.visibleIDs.isEmpty { accepted.lastVisibleIDs = accepted.visibleIDs }
        else if !normalizationSnapshot.preferences.visibleIDs.isEmpty { accepted.lastVisibleIDs = normalizationSnapshot.preferences.visibleIDs }
        else if accepted.lastVisibleIDs.isEmpty { accepted.lastVisibleIDs = normalizationSnapshot.preferences.lastVisibleIDs }
        normalizationSnapshot.preferences = try accepted.validated()
        normalizedWrites.append(normalizationSnapshot.preferences)
        normalized.updateSnapshot(normalizationSnapshot)
    }
    normalized.rows[1]!.visible.performClick(nil)
    normalized.rows[2]!.visible.performClick(nil)
    await normalized.waitForPendingChanges()
    result["normalized visibility acknowledgement updates remembered subset without a later snapshot"] = normalizedWrites.last?.visibleIDs == []
        && normalizedWrites.last?.lastVisibleIDs == [1, 2] && normalized.rememberedVisibleIDs == [1, 2] && !normalized.hasUnsavedChanges
    normalized.toggleVisibility(); await normalized.waitForPendingChanges()
    result["Restore Previous uses the accepted remembered subset"] = normalizedWrites.last?.visibleIDs == [1, 2]
    normalizationSnapshot.preferences.labels["1"] = "Confirmed external"
    normalized.updateSnapshot(normalizationSnapshot)
    result["normalized confirmation does not freeze later external preference updates"] = normalized.rows[1]?.label.stringValue == "Confirmed external"

    // A trailing separator can be a paused partial label, even when its trimmed
    // persisted value equals the old value. Snapshots cannot rewrite that editor.
    let editingLabel = content.rows[1]!.label
    editingLabel.selectText(nil)
    if let editor = editingLabel.currentEditor() as? NSTextView {
        editingLabel.stringValue = "Updated Left "; editor.string = "Updated Left "
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editingLabel))
        await content.waitForPendingChanges()
        var matching = fixture; matching.preferences = saved.last!
        content.updateSnapshot(matching)
        result["matching snapshot preserves a paused active label separator"] = editor.string == "Updated Left "
            && editingLabel.stringValue == "Updated Left "
        editingLabel.stringValue = "Updated Left side"; editor.string = "Updated Left side"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editingLabel))
        controller.window?.makeFirstResponder(nil)
        await content.waitForPendingChanges()
        result["typing after a paused separator keeps both label words"] = saved.last?.labels["1"] == "Updated Left side"
    } else {
        result["matching snapshot preserves a paused active label separator"] = false
        result["typing after a paused separator keeps both label words"] = false
    }

    let isolated = AuxFaderSettingsContent(snapshot: fixture)
    let profileGate = AuxSettingsSaveGate()
    var profileWrites: [(String, AuxPreferences)] = []
    isolated.onSave = { id, preferences in
        if profileWrites.isEmpty { await profileGate.wait() }
        profileWrites.append((id, preferences))
    }
    isolated.minimum.stringValue = "-66"
    isolated.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: isolated.minimum))
    isolated.flushPendingChanges(); let profileEntered = await waitForAuxGate(profileGate)
    isolated.rows[1]!.label.stringValue = "Queued original"
    isolated.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: isolated.rows[1]!.label))
    isolated.selectProfile("other")
    var other = fixture; other.profileID = "other"; other.preferences.labels["1"] = "Other baseline"
    isolated.updateSnapshot(other)
    isolated.rows[1]!.label.stringValue = "Other edited"
    isolated.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: isolated.rows[1]!.label))
    profileGate.release(); await isolated.waitForPendingChanges()
    result["profile handoff never acknowledges old save into new inputs or dispatches queued old edit"] = profileEntered
        && profileWrites.count == 2 && profileWrites[0].0 == "fixture" && profileWrites[0].1.labels["1"] == "Left"
        && profileWrites[1].0 == "other" && profileWrites[1].1.labels["1"] == "Other edited"
        && isolated.profileID == "other" && isolated.rows[1]?.label.stringValue == "Other edited"
    isolated.selectProfile("fixture")
    var oldConfirmed = fixture; oldConfirmed.preferences = profileWrites[0].1
    isolated.updateSnapshot(oldConfirmed); await isolated.waitForPendingChanges()
    result["returning original profile can persist its retained edit under original identity"] = profileWrites.count == 3
        && profileWrites.last?.0 == "fixture" && profileWrites.last?.1.labels["1"] == "Queued original"
    isolated.invalidateAuthority()
    result["missing authority disables inputs without inventing levels"] = !isolated.canSave && !isolated.minimum.isEnabled
        && isolated.notice.stringValue.contains("current levels unavailable")

    let deferred = AuxFaderSettingsWindow(snapshot: fixture) { preferences in saved.append(preferences) }
    defer { deferred.close() }
    let pending = deferred.content
    let beforeDeferred = saved.count
    pending.rows[1]!.label.stringValue = "Before switch"
    pending.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: pending.rows[1]!.label))
    pending.selectProfile("other"); pending.updateSnapshot(other)
    deferred.close(); await pending.waitForPendingChanges()
    result["switch before debounce and Close retain inactive profile edit without a stale write"] = saved.count == beforeDeferred
        && pending.errorLabel.stringValue.contains("fixture") && pending.errorLabel.stringValue.contains("pending")
    pending.selectProfile("fixture"); pending.updateSnapshot(fixture)
    await pending.waitForPendingChanges()
    result["return after Close automatically saves retained original profile edit"] = saved.count == beforeDeferred + 1
        && saved.last?.labels["1"] == "Before switch"

    let failedHandoff = AuxFaderSettingsContent(snapshot: fixture)
    let failureGate = AuxSettingsSaveGate()
    var failureAttempts: [String] = []
    var recoveredPreferences: AuxPreferences?
    failedHandoff.onSave = { id, preferences in
        failureAttempts.append(id)
        if failureAttempts.count == 1 {
            await failureGate.wait()
            throw SwitcherError.message("Profile changed during held persistence")
        }
        recoveredPreferences = preferences
    }
    failedHandoff.minimum.stringValue = "-64"
    failedHandoff.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: failedHandoff.minimum))
    failedHandoff.flushPendingChanges()
    let failureEntered = await waitForAuxGate(failureGate)
    failedHandoff.selectProfile("other"); failedHandoff.updateSnapshot(other)
    failureGate.release(); await failedHandoff.waitForPendingChanges()
    for _ in 0..<3 { failedHandoff.updateSnapshot(other); await failedHandoff.waitForPendingChanges() }
    result["failed old-profile save remains bounded while another profile is selected"] = failureEntered
        && failureAttempts == ["fixture"] && recoveredPreferences == nil
        && failedHandoff.errorLabel.stringValue.contains("Select that profile to retry saving")
    failedHandoff.selectProfile("fixture"); failedHandoff.updateSnapshot(fixture)
    await failedHandoff.waitForPendingChanges()
    result["explicit return retries one failed valid Aux edit under its original identity"] = failureAttempts == ["fixture", "fixture"]
        && recoveredPreferences?.sliderMinimumDB == -64 && !failedHandoff.hasUnsavedChanges
    return result
}
