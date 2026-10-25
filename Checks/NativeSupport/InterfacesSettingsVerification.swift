import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor enum InterfacesSettingsVerification {
    static func fixtureState() -> InterfaceProfilesState {
        let first = InterfaceProfileDraft(id: "interface-one", name: "Studio",
            executablePath: "/fixture/camilladsp", configurationPath: "/fixture/studio.yml",
            triggerUID: "offline-trigger", captureUID: "offline-capture", playbackUID: "physical-output", websocketPort: 1234)
        let second = InterfaceProfileDraft(id: "interface-two", name: "Studio",
            executablePath: "/fixture/camilladsp", configurationPath: "/fixture/alternate.yml",
            triggerUID: "physical-output", captureUID: "virtual-capture", playbackUID: "physical-output", websocketPort: 2234)
        let devices = [
            AudioDevice(uid: "virtual-capture", name: "BlackHole", inputChannels: 2, outputChannels: 2),
            AudioDevice(uid: "physical-output", name: "USB Output", inputChannels: 2, outputChannels: 2),
            AudioDevice(uid: "other-output", name: "USB Output", inputChannels: 0, outputChannels: 2)
        ]
        return InterfaceProfilesState(profiles: [first, second], devices: devices, activeProfileID: nil,
            selectedProfileID: "interface-one", pendingProfileIDs: ["interface-two"])
    }
    private static func render(_ view: NSView?, to url: URL) {
        guard let view else { return }
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
    static func checks() async -> [String: Bool] {
        _ = NSApplication.shared
        let state = fixtureState()
        var loads = 0, saves = 0, removals = 0, activations = 0
        let handlers = InterfaceProfilesHandlers(load: { loads += 1; return state }, save: { _ in
            saves += 1; throw SwitcherError.message("Fixture save rejected")
        }, remove: { _ in removals += 1; return state }, activate: { _ in activations += 1; return state })
        let content = InterfacesSettingsContent(handlers: handlers)
        let identifiers = content.profileIdentifiersForVerification
        content.selectProfileForVerification("interface-two")
        let selectionLocal = content.selectedProfileIdentifierForVerification == "interface-two"
            && loads == 1 && saves == 0 && removals == 0 && activations == 0
        let honestStates = content.profileStatusesForVerification == ["Offline", "Pending use"]
        let editor = content.editorForVerification(state.profiles[0])!
        let draftPreserved = editor.draftForVerification == state.profiles[0]
        let pathsHaveWidth = editor.pathMinimumWidthsForVerification
        let groupedAndClear = editor.sectionTitlesForVerification == ["Profile", "Audio Devices", "Startup Preset", "Behavior"]
            && editor.presetNameForVerification == "studio.yml"
            && editor.presetDescriptionForVerification.contains("CamillaDSP YAML preset")
            && editor.advancedHiddenForVerification
        let collapsedHeight = editor.contentHeightForVerification
        let compact = editor.contentFitsForVerification && collapsedHeight < 620
        editor.toggleAdvancedForVerification()
        let advancedResizes = !editor.advancedHiddenForVerification
            && editor.contentHeightForVerification > collapsedHeight
        editor.toggleAdvancedForVerification()
        let restoresCompactHeight = abs(editor.contentHeightForVerification - collapsedHeight) < 1
        let emptyEditor = content.editorForVerification(InterfaceProfileDraft())!
        let emptyClear = emptyEditor.presetNameForVerification == "No preset selected"
            && !emptyEditor.duplicateEnabledForVerification
            && emptyEditor.contentFitsForVerification
        editor.editNameForVerification("Unsaved name")
        let dirtyNotPersisted = saves == 0 && content.activationEnabledForVerification
            && editor.draftForVerification.name == "Unsaved name"
        editor.saveForVerification()
        await editor.waitForOperationForVerification()
        let errorPreservedDraft = editor.displayedErrorForVerification == "Fixture save rejected"
            && editor.draftForVerification.name == "Unsaved name" && saves == 1
        let fits = content.rowsFillWidthForVerification(548)
        content.updateRuntime(activeID: "interface-one", selectedID: "interface-one")
        let runtimeUpdateNoReads = loads == 1 && content.profileStatusesForVerification[0] == "Active"
        let problematic = InterfaceProfilesState(profiles: state.profiles, devices: state.devices,
            activeProfileID: nil, profileIssues: ["interface-two": "Fixture job needs review"])
        let issueContent = InterfacesSettingsContent(handlers: InterfaceProfilesHandlers(load: { problematic },
            save: { _ in problematic }, remove: { _ in problematic }, activate: { _ in problematic }))
        issueContent.selectProfileForVerification("interface-two")
        let issueKeepsRows = issueContent.profileIdentifiersForVerification == ["interface-one", "interface-two"]
            && issueContent.profileStatusesForVerification[1] == "Needs review"
            && !issueContent.activationEnabledForVerification && !issueContent.editEnabledForVerification
            && issueContent.displayedErrorForVerification == "Fixture job needs review"
        issueContent.selectProfileForVerification("interface-one")
        let otherRowUsable = issueContent.activationEnabledForVerification && issueContent.editEnabledForVerification
        issueContent.updateRuntime(activeID: "interface-two", selectedID: "interface-two")
        issueContent.updateDevices(state.devices + [AudioDevice(uid: "new", name: "New", inputChannels: 0, outputChannels: 2)])
        let issueRetainsRuntimeStatus = issueContent.profileStatusesForVerification[1] == "Active · needs review"
        let window = NativeSettingsWindow(preferences: UIPreferences(), interfaceProfiles: handlers, onChange: { _ in })
        window.selectTab(.interfaces)
        let interfacesTabExists = window.selectedTab == .interfaces
        if let directory = ProcessInfo.processInfo.environment["CAMILLACOMPANION_INTERFACES_RENDER"] {
            let root = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let preview = content.editorForVerification(state.profiles[1])!
            render(preview.window?.contentView, to: root.appendingPathComponent("profile-editor.png"))
            render(emptyEditor.window?.contentView, to: root.appendingPathComponent("profile-editor-empty.png"))
            preview.toggleAdvancedForVerification()
            render(preview.window?.contentView, to: root.appendingPathComponent("profile-editor-advanced.png"))
            preview.close()
            render(window.window?.contentView, to: root.appendingPathComponent("profiles.png"))
            let browser = InterfaceDeviceBrowser(devices: state.devices, selectedUID: "physical-output", role: .dspOutput,
                savedUIDs: ["offline-capture"], refresh: { state.devices }, onSelect: { _ in })
            render(browser.window?.contentView, to: root.appendingPathComponent("device-browser.png"))
            browser.close()
        }
        window.close(); editor.close(); emptyEditor.close()
        return [
            "Interfaces tab is present": interfacesTabExists,
            "Editor groups match Settings and explain the startup preset": groupedAndClear && emptyClear,
            "Editor fits collapsed content and resizes for Advanced": compact && advancedResizes && restoresCompactHeight,
            "One unsupported job leaves both profiles visible and only blocks its own actions": issueKeepsRows && otherRowUsable,
            "Job issues survive device and runtime updates without hiding verified activity": issueRetainsRuntimeStatus,
            "Profile table preserves duplicate names with distinct IDs": identifiers == ["interface-one", "interface-two"],
            "Selecting a row never saves or activates a profile": selectionLocal,
            "Offline and pending state do not claim an active engine": honestStates,
            "Saved offline UID and trigger survive opening the editor": draftPreserved,
            "Editing is local until explicit Save": dirtyNotPersisted,
            "Failed save keeps the sheet draft and displays the error": errorPreservedDraft,
            "Empty and nonempty path labels have usable widths": pathsHaveWidth,
            "Profile table fits the native tab width": fits,
            "Runtime state updates are event-driven and perform no reads": runtimeUpdateNoReads
        ]
    }
}
