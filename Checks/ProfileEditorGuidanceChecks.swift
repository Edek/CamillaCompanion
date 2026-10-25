import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runProfileEditorGuidanceChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("profile-guidance-\(UUID().uuidString)")
    let presets = root.appendingPathComponent("Presets"), alternate = root.appendingPathComponent("Other presets")
    try FileManager.default.createDirectory(at: presets, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var configuredFolder: String? = presets.path
    var opened: [URL] = [], saves = 0
    let current = InterfaceProfileDraft(id: "current", name: "Studio", configurationPath: root.appendingPathComponent("startup.yml").path,
        triggerUID: "usb", captureUID: "feed", playbackUID: "usb")
    var alternative = current; alternative.id = "alternative"; alternative.name = "Alternative"
    let editor = InterfaceProfileEditor(draft: alternative, devices: [], savedProfiles: [current],
        presetsFolder: { configuredFolder }, openDirectory: { opened.append($0); return true },
        refresh: { [] }, onSave: { _ in saves += 1 })
    defer { editor.close() }
    try check(editor.presetDirectoryForVerification?.path == presets.path, "Picker prefers the configured presets folder over the selected preset directory")
    editor.openPresetsForVerification()
    try check(opened.map(\.path) == [presets.path], "Open Presets Folder uses the same directory as the picker without saving")
    configuredFolder = alternate.path
    try check(editor.presetDirectoryForVerification?.path == alternate.path, "Folder selection is read on demand after a General preference change")
    configuredFolder = root.appendingPathComponent("missing").path
    try check(editor.presetDirectoryForVerification?.path == root.path, "Unavailable presets folder falls back to the selected preset's directory")

    try check(editor.overlapMessageForVerification.contains("automatic connection trigger")
              && editor.overlapMessageForVerification.contains("Studio"), "New profile warns about another automatic profile with the same trigger")
    editor.setAutoActivateForVerification(false)
    try check(!editor.overlapMessageForVerification.contains("automatic connection trigger")
              && editor.overlapMessageForVerification.contains("only one profile"), "Manual alternative retains shared-device guidance without automatic-trigger warning")
    try check(saves == 0 && editor.draftForVerification.configurationPath == alternative.configurationPath,
              "Folder browsing and overlap guidance never save, activate or replace the selected preset")
    try check(InterfaceProfileOverlap.review(current, against: [current]) == nil, "Editing a profile does not warn about itself")
    alternative.triggerUID = "other-usb"
    try check(InterfaceProfileOverlap.review(alternative, against: [current])?.automaticAmbiguity == false,
              "Different triggers with shared DSP devices are allowed as alternatives")
    alternative.triggerUID = current.triggerUID; alternative.captureUID = "different-input"; alternative.playbackUID = "different-output"
    try check(InterfaceProfileOverlap.review(alternative, against: [current])?.automaticAmbiguity == true,
              "Automatic-trigger ambiguity is detected even with different DSP input/output")

    var confirmation: ((Bool) -> Void)?
    var confirmedNames: [String] = []
    var focusedSaves = 0
    var optInDraft = alternative
    optInDraft.autoActivate = false
    let optIn = InterfaceProfileEditor(draft: optInDraft, devices: [], savedProfiles: [current],
        openDirectory: { _ in true }, refresh: { [] }, onSave: { _ in focusedSaves += 1 },
        confirmationPresenter: { names, completion in confirmedNames = names; confirmation = completion })
    defer { optIn.close() }
    optIn.setAutoActivateForVerification(true)
    try check(confirmedNames == ["Studio"] && focusedSaves == 0 && !optIn.draftForVerification.autoActivate,
              "Enabling auto-activation asks about the conflicting profile without saving")
    confirmation?(false)
    confirmation = nil
    try check(!optIn.draftForVerification.autoActivate && optIn.confirmedReplacementIDsForVerification.isEmpty,
              "Cancel restores the previous auto-activation toggle")
    optIn.setAutoActivateForVerification(true)
    confirmation?(true)
    confirmation = nil
    try check(optIn.draftForVerification.autoActivate
              && optIn.confirmedReplacementIDsForVerification == [current.id] && focusedSaves == 0,
              "Accept records the exact replacement IDs in the draft and does not save")
    optIn.saveForVerification()
    await optIn.waitForOperationForVerification()
    try check(focusedSaves == 1, "The explicit Save Profile action persists the accepted draft once")

    var triggerConfirmation: ((Bool) -> Void)?
    let triggerEditor = InterfaceProfileEditor(draft: alternative, devices: [], savedProfiles: [current],
        openDirectory: { _ in true }, refresh: { [] }, onSave: { _ in focusedSaves += 1 },
        confirmationPresenter: { _, completion in triggerConfirmation = completion })
    defer { triggerEditor.close() }
    triggerEditor.setTriggerForVerification("other-usb")
    try check(triggerEditor.draftForVerification.triggerUID == "other-usb"
              && triggerEditor.confirmedReplacementIDsForVerification.isEmpty,
              "Changing to an unambiguous trigger clears prior replacement approval")
    triggerEditor.setTriggerForVerification("usb")
    triggerConfirmation?(false)
    triggerConfirmation = nil
    try check(triggerEditor.draftForVerification.triggerUID == "other-usb"
              && triggerEditor.confirmedReplacementIDsForVerification.isEmpty,
              "Cancel restores the prior trigger and leaves replacement approval empty")
    triggerEditor.setTriggerForVerification("usb")
    triggerConfirmation?(true)
    triggerConfirmation = nil
    try check(triggerEditor.confirmedReplacementIDsForVerification == [current.id],
              "Changing to a conflicting trigger asks and records draft-only approval")
    triggerEditor.setTriggerForVerification("other-usb")
    try check(triggerEditor.confirmedReplacementIDsForVerification.isEmpty && focusedSaves == 1,
              "A later trigger change invalidates prior approval without saving")

    var priorTriggerConflict = current
    priorTriggerConflict.id = "prior-trigger-conflict"
    priorTriggerConflict.triggerUID = "prior-usb"
    var approvedPriorTrigger = alternative
    approvedPriorTrigger.triggerUID = "prior-usb"
    approvedPriorTrigger.confirmedAutoActivationReplacementIDs = [priorTriggerConflict.id]
    var rejectedTriggerConfirmation: ((Bool) -> Void)?
    let rejectedTrigger = InterfaceProfileEditor(draft: approvedPriorTrigger, devices: [],
        savedProfiles: [current, priorTriggerConflict], openDirectory: { _ in true }, refresh: { [] },
        onSave: { _ in focusedSaves += 1 },
        confirmationPresenter: { _, completion in rejectedTriggerConfirmation = completion })
    defer { rejectedTrigger.close() }
    rejectedTrigger.setTriggerForVerification("usb")
    rejectedTriggerConfirmation?(false)
    try check(rejectedTrigger.draftForVerification.triggerUID == "prior-usb"
              && rejectedTrigger.confirmedReplacementIDsForVerification == [priorTriggerConflict.id],
              "Rejecting a trigger change restores still-valid prior approval")

    var saveConfirmation: ((Bool) -> Void)?
    var saveTimeCalls = 0
    let saveTime = InterfaceProfileEditor(draft: alternative, devices: [], savedProfiles: [current],
        openDirectory: { _ in true }, refresh: { [] }, onSave: { _ in saveTimeCalls += 1 },
        confirmationPresenter: { names, completion in confirmedNames = names; saveConfirmation = completion })
    defer { saveTime.close() }
    saveTime.editNameForVerification("Alternative")
    saveTime.saveForVerification()
    try check(confirmedNames == ["Studio"] && saveTimeCalls == 0,
              "Save-time confirmation is shown before persisting an unconfirmed imported duplicate")
    saveConfirmation?(true)
    await saveTime.waitForOperationForVerification()
    try check(saveTimeCalls == 1, "Accepting the Save-time prompt continues that same Save Profile request")

    var cancelledSaveConfirmation: ((Bool) -> Void)?
    var cancelledSaveCalls = 0
    let cancelledSave = InterfaceProfileEditor(draft: alternative, devices: [], savedProfiles: [current],
        openDirectory: { _ in true }, refresh: { [] }, onSave: { _ in cancelledSaveCalls += 1 },
        confirmationPresenter: { _, completion in cancelledSaveConfirmation = completion })
    defer { cancelledSave.close() }
    cancelledSave.saveForVerification()
    cancelledSaveConfirmation?(false)
    try check(cancelledSaveCalls == 0 && cancelledSave.displayedErrorForVerification == "Profile was not saved.",
              "Canceling Save-time confirmation leaves the profile unsaved")

    let empty = InterfaceProfileEditor(draft: InterfaceProfileDraft(name: "New profile"), devices: [], savedProfiles: [],
        openDirectory: { opened.append($0); return true }, refresh: { [] }, onSave: { _ in saves += 1 })
    defer { empty.close() }
    empty.saveForVerification()
    try check(empty.displayedErrorForVerification == "Choose a startup preset." && saves == 0,
              "Missing startup preset gives a specific error before calling the profile store")
    empty.openPresetsForVerification()
    try check(empty.presetDirectoryForVerification == nil && opened.count == 1,
              "No configured folder or selected preset opens no arbitrary folder")

    let state = InterfaceProfilesState(profiles: [current], devices: [], activeProfileID: current.id)
    let handlers = InterfaceProfilesHandlers(load: { state }, save: { _ in state }, remove: { _ in state }, activate: { _ in state })
    var preferences = UIPreferences(presetsFolderPath: presets.path)
    let settings = NativeSettingsWindow(preferences: preferences, interfaceProfiles: handlers, onChange: { _ in })
    defer { settings.close() }
    guard let integrated = settings.interfaceEditorForVerification(current) else { throw CheckFailure.failed("Interfaces editor unavailable") }
    defer { integrated.close() }
    try check(integrated.presetDirectoryForVerification?.path == presets.path, "Settings General presets folder reaches the Interfaces sheet")
    preferences.presetsFolderPath = alternate.path; settings.updatePreferences(preferences)
    try check(integrated.presetDirectoryForVerification?.path == alternate.path, "An existing sheet uses updated General preferences")
}
