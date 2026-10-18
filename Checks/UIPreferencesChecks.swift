import AppKit
import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runUIPreferencesChecks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("camillacompanion-ui-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("runtime.json")
    let url = stateURL.appendingPathExtension("ui-preferences.json")
    let store = JSONUIPreferencesStore(runtimeStateURL: stateURL)
    let missing = try store.load()
    try check(missing == UIPreferences(), "Missing UI preferences default to Silent Mode and Keep Active Colors off")
    try check(missing.showMenuBarIcon, "Show Menu Bar Icon defaults on for a new preference store")
    try check(!missing.keepActiveColors, "Keep Active Colors defaults off")
    try check(!missing.followMacOSOutput, "Follow macOS Output defaults off to preserve existing target behavior")
    try check(missing.automaticSwitching && missing.companionDSPMode == .automatic && missing.companionProfileID == nil,
              "Automatic Switching defaults on and companion DSP intent defaults to Auto without a pinned profile")
    try check(!FileManager.default.fileExists(atPath: url.path), "Reading defaults creates no preferences file")
    try store.save(UIPreferences(silentMode: true))
    try check(FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: stateURL.path), "UI preferences persist separately beside route state")
    let restored = try JSONUIPreferencesStore(runtimeStateURL: stateURL).load()
    try check(restored.silentMode && restored.version == 1, "Silent Mode survives store recreation")
    try store.save(UIPreferences(showMenuBarIcon: false))
    let iconOffRestored = try store.load()
    try check(!iconOffRestored.showMenuBarIcon, "Turning Show Menu Bar Icon off survives store recreation")
    try store.save(UIPreferences())
    try store.save(UIPreferences(silentMode: true, liveLevels: true))
    let metersRestored = try store.load()
    try check(metersRestored.liveLevels && metersRestored.silentMode, "Live Levels persists separately from Silent Mode")
    try store.save(UIPreferences(silentMode: true, liveLevels: true, keepActiveColors: true))
    let colorsRestored = try JSONUIPreferencesStore(runtimeStateURL: stateURL).load()
    try check(colorsRestored.keepActiveColors && colorsRestored.silentMode && colorsRestored.liveLevels,
              "Keep Active Colors persists independently alongside notification and metering preferences")
    try store.save(UIPreferences(keepActiveColors: false))
    let colorsDisabled = try store.load()
    try check(!colorsDisabled.keepActiveColors, "Turning Keep Active Colors off survives persistence")
    try store.save(UIPreferences(silentMode: true, liveLevels: true, keepActiveColors: true, followMacOSOutput: true))
    let followingRestored = try JSONUIPreferencesStore(runtimeStateURL: stateURL).load()
    try check(followingRestored.followMacOSOutput && followingRestored.keepActiveColors && followingRestored.silentMode && followingRestored.liveLevels,
              "Follow macOS Output persists independently alongside existing preferences")
    try store.save(UIPreferences(followMacOSOutput: false))
    let followingDisabled = try JSONUIPreferencesStore(runtimeStateURL: stateURL).load()
    try check(!followingDisabled.followMacOSOutput, "Turning Follow macOS Output off survives store recreation")
    let companionPreferences = UIPreferences(automaticSwitching: false, companionDSPMode: .forceOn, companionProfileID: "studio")
    try store.save(companionPreferences)
    let companionRestored = try store.load()
    try check(!companionRestored.automaticSwitching && companionRestored.companionDSPMode == .forceOn && companionRestored.companionProfileID == "studio",
              "Companion mode and saved DSP intent persist independently")
    var customized = UIPreferences(liveLevels: true, meterOptions: .init(peakHoldMilliseconds: 0, falloffDBPerSecond: 25, refreshHz: 120,
        minimumDB: -60, maximumDB: 0, numericPeakHoldMilliseconds: 8000, numberHoldMilliseconds: 750),
        mainSliderRanges: ["bedroom": .init(minimumDB: -40, maximumDB: 3), "studio": .init(minimumDB: -80, maximumDB: 10)])
    try store.save(customized)
    let customRestored = try store.load()
    try check(customRestored == customized && customRestored.mainSliderRange(profileID: "new") == MainSliderRange(),
              "Meter options and independent profile ranges round-trip with defaults for new profiles")
    var folderPreferences = customRestored
    folderPreferences.presetsFolderPath = directory.appendingPathComponent("Unplugged Presets", isDirectory: true).path
    try check(!FileManager.default.fileExists(atPath: folderPreferences.presetsFolderPath!),
              "Preset folder fixture is unavailable rather than an existing directory")
    try store.save(folderPreferences)
    let folderRestored = try JSONUIPreferencesStore(runtimeStateURL: stateURL).load()
    try check(folderRestored == folderPreferences,
              "An absolute presets folder path persists without requiring the folder to exist")
    let validFolderData = try Data(contentsOf: url)
    for path in ["", " ", "relative/presets", "~/Presets", "file:///tmp/Presets", "/tmp/invalid\0name"] {
        var invalidFolder = folderPreferences; invalidFolder.presetsFolderPath = path
        do { try store.save(invalidFolder); throw CheckFailure.failed("Invalid presets path saved") }
        catch is CheckFailure { throw CheckFailure.failed("Invalid presets path saved") }
        catch { }
        let preserved = try Data(contentsOf: url)
        try check(preserved == validFolderData, "Invalid presets path preserves the last good preferences file")
    }
    folderPreferences.presetsFolderPath = nil
    try store.save(folderPreferences)
    let clearedFolder = try store.load()
    try check(clearedFolder.presetsFolderPath == nil, "Clearing presets folder restores the default choice")
    try store.save(customRestored)
    let legacyMeterOptions = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"meterOptions":{"peakHoldMilliseconds":2000,"falloffDBPerSecond":120,"refreshHz":30}}"#.utf8))
    try check(legacyMeterOptions.meterOptions.peakHoldMilliseconds == 2000 && legacyMeterOptions.meterOptions.falloffDBPerSecond == 120 &&
        legacyMeterOptions.meterOptions.refreshHz == 30 && legacyMeterOptions.meterOptions.minimumDB == -96 &&
        legacyMeterOptions.meterOptions.maximumDB == 6 && legacyMeterOptions.meterOptions.numericPeakHoldMilliseconds == 5000 && legacyMeterOptions.meterOptions.numberHoldMilliseconds == 500,
        "Installed legacy meter options preserve custom choices and default new range/number hold fields")
    let explicitLegacyHold = try JSONDecoder().decode(SignalMeterOptions.self, from: Data(#"{"numericPeakHoldMilliseconds":12000}"#.utf8))
    try check(explicitLegacyHold.numericPeakHoldMilliseconds == 12000 && explicitLegacyHold.numberHoldMilliseconds == 500,
              "Legacy timed numeric setting never supplies the new Realtime Number hold")
    for duration in [0.0, 5000.0] {
        _ = try SignalMeterOptions(numberHoldMilliseconds: duration).validated()
    }
    let validData = try Data(contentsOf: url)
    for invalid in [SignalMeterOptions(peakHoldMilliseconds: -1), SignalMeterOptions(peakHoldMilliseconds: 10001),
                    SignalMeterOptions(falloffDBPerSecond: 0), SignalMeterOptions(falloffDBPerSecond: .infinity),
                    SignalMeterOptions(refreshHz: 0), SignalMeterOptions(refreshHz: 121),
                    SignalMeterOptions(minimumDB: -151), SignalMeterOptions(maximumDB: 21),
                    SignalMeterOptions(minimumDB: 0, maximumDB: 0), SignalMeterOptions(minimumDB: .nan),
                    SignalMeterOptions(numberHoldMilliseconds: -1), SignalMeterOptions(numberHoldMilliseconds: 5001),
                    SignalMeterOptions(numberHoldMilliseconds: .infinity), SignalMeterOptions(numericPeakHoldMilliseconds: -1), SignalMeterOptions(numericPeakHoldMilliseconds: 60001)] {
        customized.meterOptions = invalid
        do { try store.save(customized); throw CheckFailure.failed("Invalid meter options saved") }
        catch is CheckFailure { throw CheckFailure.failed("Invalid meter options saved") }
        catch { }
        let preserved = try Data(contentsOf: url)
        try check(preserved == validData, "Invalid meter save preserves last good file")
    }
    for range in [MainSliderRange(minimumDB: -151), MainSliderRange(maximumDB: 51),
                  MainSliderRange(minimumDB: 6, maximumDB: 6), MainSliderRange(minimumDB: .nan)] {
        customized = customRestored; customized.mainSliderRanges["bedroom"] = range
        do { try store.save(customized); throw CheckFailure.failed("Invalid Main range saved") }
        catch is CheckFailure { throw CheckFailure.failed("Invalid Main range saved") }
        catch { }
        let preserved = try Data(contentsOf: url)
        try check(preserved == validData, "Invalid range save preserves last good file")
    }
    try store.save(UIPreferences())
    let reset = try store.load()
    try check(!reset.silentMode, "Turning Silent Mode off persists atomically")
    for legacy in [#"{}"#, #"{"version":1}"#, #"{"silentMode":true}"#, #"{"presetsFolderPath":null}"#] {
        try Data(legacy.utf8).write(to: url, options: .atomic)
        let decoded = try store.load()
        try check(decoded.version == 1 && decoded.silentMode == legacy.contains("true") && !decoded.liveLevels && !decoded.keepActiveColors && decoded.showMenuBarIcon && !decoded.followMacOSOutput && decoded.presetsFolderPath == nil, "Older preference documents decode with defaults")
        let retainedLegacyData = try Data(contentsOf: url)
        try check(retainedLegacyData == Data(legacy.utf8), "Loading legacy and null presets paths never rewrites preferences")
    }
    for invalid in [#"{"version":2,"silentMode":true}"#, #"{"version":1,"silentMode":"true"}"#,
                    #"{"keepActiveColors":"true"}"#,
                    #"{"followMacOSOutput":"true"}"#,
                    #"{"automaticSwitching":"false"}"#,
                    #"{"companionProfileID":""}"#,
                    #"{"companionProfileID":"  "}"#,
                    #"{"companionProfileID":"bad\u0000id"}"#,
                    #"{"meterOptions":{"peakHoldMilliseconds":3000,"falloffDBPerSecond":40,"refreshHz":121}}"#,
                    #"{"mainSliderRanges":{"bedroom":{"minimumDB":6,"maximumDB":-50}}}"#,
                    #"{"presetsFolderPath":"relative/presets"}"#, #"{"presetsFolderPath":""}"#,
                    #"{"presetsFolderPath":12}"#, "broken json"] {
        let data = Data(invalid.utf8)
        try data.write(to: url, options: .atomic)
        do { _ = try store.load(); throw CheckFailure.failed("Invalid preferences unexpectedly loaded") }
        catch is CheckFailure { throw CheckFailure.failed("Invalid preferences unexpectedly loaded") }
        catch { }
        do { try store.save(UIPreferences()); throw CheckFailure.failed("Invalid preferences unexpectedly replaced") }
        catch is CheckFailure { throw CheckFailure.failed("Invalid preferences unexpectedly replaced") }
        catch { }
        let preserved = try Data(contentsOf: url)
        try check(preserved == data, "Save preserves malformed or unsupported preference documents")
    }
    let unreadableURL = directory.appendingPathComponent("directory-instead-of-file")
    try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: false)
    let unreadable = JSONUIPreferencesStore(url: unreadableURL)
    do { _ = try unreadable.load(); throw CheckFailure.failed("Unreadable preferences unexpectedly treated as missing") }
    catch is CheckFailure { throw CheckFailure.failed("Unreadable preferences unexpectedly treated as missing") }
    catch { }
    do { try unreadable.save(UIPreferences()); throw CheckFailure.failed("Unreadable preferences unexpectedly replaced") }
    catch is CheckFailure { throw CheckFailure.failed("Unreadable preferences unexpectedly replaced") }
    catch { }

    try await checkNativeSettingsAutosave(customRestored: customRestored, directory: directory)
    print("UI preferences checks: defaults, legacy decoding, persistence, independent native autosave and error preservation passed")
}

@MainActor private func checkNativeSettingsAutosave(customRestored: UIPreferences, directory: URL) async throws {
    _ = NSApplication.shared
    var saved = UIPreferences()
    var applied: [UIPreferences] = []
    var rejectSave = false
    var refreshDispatches = 0
    var auxWrites: [(String, AuxPreferences)] = []
    var holdAux = false
    var auxEntered = false
    var releaseAux: CheckedContinuation<Void, Never>?
    var openedSettingsDirectory: URL?
    var rejectFolderReveal = false
    let auxSnapshot = AuxFaderSnapshot(profileID: "bedroom", faders: [
        AuxFader(id: 1, name: "Aux 1", volumeDB: -3, muted: false, maximumDB: 50),
        AuxFader(id: 2, name: "Aux 2", volumeDB: -6, muted: false, maximumDB: 50)],
        preferences: AuxPreferences(visibleIDs: [1, 2], labels: ["1": "Left"], linkGroups: [[1, 2]], lastVisibleIDs: [1, 2], sliderMinimumDB: -80), ready: true)
    let controller = NativeSettingsWindow(preferences: saved, error: "Could not load preferences", profileID: "bedroom", profileName: "Bedroom",
        auxSnapshot: auxSnapshot, settingsDirectoryURL: directory, revealSettingsDirectory: { url in
            openedSettingsDirectory = url
            return !rejectFolderReveal
        }, onSaveAux: { id, preferences in
            if holdAux { auxEntered = true; await withCheckedContinuation { releaseAux = $0 } }
            auxWrites.append((id, preferences))
        },
        onRefreshFaders: { refreshDispatches += 1 }) { next in
        if rejectSave { throw SwitcherError.message("Fixture save failed") }
        saved = next; applied.append(next)
    }
    defer { controller.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = controller.window!.contentView!
    let tabs = descendants(root).compactMap { $0 as? NSTabView }.first!
    let allViews = descendants(root) + tabs.tabViewItems.compactMap(\.view).flatMap(descendants)
    var seen = Set<ObjectIdentifier>()
    let views = allViews.filter { seen.insert(ObjectIdentifier($0)).inserted }
    let buttons = views.compactMap { $0 as? NSButton }
    for title in ["Silent Mode", "Show Menu Bar Icon", "Keep Active Colors", "Follow macOS Output", "Automatic Switching", "Clear", "Open Settings Folder"] {
        try check(buttons.contains { $0.title == title }, "Missing Settings button: " + title)
    }
    for name in ["Number hold", "Peak marker hold", "Falloff", "Refresh rate", "Meter minimum", "Meter maximum", "Main minimum", "Main maximum"] {
        try check(views.compactMap({ $0 as? NSTextField }).contains { $0.identifier?.rawValue == name }, "Missing Settings field: " + name)
    }
    func button(_ title: String) -> NSButton { buttons.first { $0.title == title }! }
    func field(_ name: String) -> NSTextField { views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == name }! }
    func edit(_ name: String, _ value: String) {
        let valueField = field(name); valueField.stringValue = value
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: valueField))
    }
    let feedback = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Settings error" }!
    let mode = views.compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == "Meter numeric mode" }!
    let aux = views.compactMap { $0 as? AuxFaderSettingsContent }.first!
    let initialSize = root.bounds.size
    try check(!buttons.contains { ["Apply", "Save", "Cancel", "Close"].contains($0.title) }, "Settings has no footer close or manual save and discard actions")
    try check(controller.performCloseShortcutForVerification("\u{1b}", modifiers: [], keyCode: 53)
              && controller.performCloseShortcutForVerification("w", modifiers: .command, keyCode: 13),
              "Escape and Command-W route through native Settings closing")
    try check(views.compactMap({ $0 as? NSTextField }).contains { $0.stringValue == "Choose the folder containing your CamillaDSP presets." },
              "General explains what the Presets folder contains")
    try check(!feedback.isHidden && feedback.stringValue.contains("Could not load"), "Settings displays preference load failures")
    try check(button("Open Settings Folder").isEnabled, "The active runtime settings folder is available through General")
    button("Open Settings Folder").performClick(nil)
    try check(openedSettingsDirectory?.standardizedFileURL == directory.standardizedFileURL,
              "Open Settings Folder reveals the injected active runtime directory")
    try check(feedback.stringValue.contains("Could not load"),
              "Opening the settings folder does not clear an unrelated preference load failure")
    rejectFolderReveal = true
    button("Open Settings Folder").performClick(nil)
    try check(feedback.stringValue.contains("Could not open the settings folder"), "An inaccessible Settings folder reports a concise error")
    rejectFolderReveal = false
    button("Open Settings Folder").performClick(nil)
    button("Show Menu Bar Icon").performClick(nil)
    try check(!saved.showMenuBarIcon, "Show Menu Bar Icon persists through the existing preference change path")
    button("Show Menu Bar Icon").performClick(nil)
    try check(saved.showMenuBarIcon, "Show Menu Bar Icon can be restored")
    button("Silent Mode").performClick(nil)
    try check(saved.silentMode && feedback.isHidden, "Silent Mode persists on its native action")
    rejectSave = true
    button("Show Menu Bar Icon").performClick(nil)
    try check(saved.showMenuBarIcon && button("Show Menu Bar Icon").state == .on && feedback.stringValue.contains("Fixture save failed"),
              "Failed menu icon preference save restores the confirmed checkbox state and reports the error")
    button("Silent Mode").performClick(nil)
    try check(saved.silentMode && button("Silent Mode").state == .on && feedback.stringValue.contains("Fixture save failed"),
              "Failed checkbox persistence restores the last confirmed state and explains the error")
    rejectSave = false
    button("Automatic Switching").performClick(nil)
    try check(!saved.automaticSwitching && !button("Follow macOS Output").isEnabled, "Automatic Switching immediately updates dependent availability")
    button("Automatic Switching").performClick(nil)
    try check(saved.automaticSwitching && button("Follow macOS Output").isEnabled, "Re-enabling switching restores its dependent control")

    edit("Refresh rate", "999")
    edit("Number hold", "-")
    button("Keep Active Colors").performClick(nil)
    edit("Falloff", "12")
    await controller.waitForPendingSaveForVerification()
    try check(saved.keepActiveColors && saved.meterOptions.falloffDBPerSecond == 12 && saved.meterOptions.refreshHz == 10
              && saved.meterOptions.numberHoldMilliseconds == 500 && field("Number hold").stringValue == "-",
              "Invalid or incomplete fields preserve saved values while unrelated settings persist")
    edit("Number hold", "")
    await controller.waitForPendingSaveForVerification()
    try check(saved.meterOptions.numberHoldMilliseconds == 500 && field("Number hold").stringValue.isEmpty,
              "Empty numeric typing remains editable without overwriting the last valid value")
    edit("Number hold", "750")
    edit("Refresh rate", "24")
    // Exercise the actual finite typing debounce, without an Apply or focus change.
    try await Task.sleep(nanoseconds: 300_000_000)
    try check(saved.meterOptions.numberHoldMilliseconds == 750 && saved.meterOptions.refreshHz == 24 && feedback.isHidden,
              "Complete numeric edits persist after the short typing pause")

    let beforeMeterPair = saved.meterOptions
    edit("Meter maximum", "-120")
    await controller.waitForPendingSaveForVerification()
    try check(saved.meterOptions == beforeMeterPair && feedback.stringValue.contains("Meter display endpoints"),
              "A temporarily crossed meter pair cannot persist one invalid endpoint")
    edit("Meter minimum", "-130")
    await controller.waitForPendingSaveForVerification()
    try check(saved.meterOptions.minimumDB == -130 && saved.meterOptions.maximumDB == -120,
              "Completing a valid meter endpoint pair saves both endpoints together")
    edit("Main minimum", "10")
    await controller.waitForPendingSaveForVerification()
    try check(saved.mainSliderRange(profileID: "bedroom") == MainSliderRange(), "Crossed Main endpoints keep the saved profile range")
    edit("Main maximum", "20")
    await controller.waitForPendingSaveForVerification()
    try check(saved.mainSliderRange(profileID: "bedroom") == MainSliderRange(minimumDB: 10, maximumDB: 20),
              "Main endpoint pair commits automatically when both values are valid")

    rejectSave = true
    edit("Refresh rate", "31")
    await controller.waitForPendingSaveForVerification()
    try check(saved.meterOptions.refreshHz == 24 && field("Refresh rate").stringValue == "31" && feedback.stringValue.contains("Fixture save failed"),
              "Numeric persistence failure keeps the accepted preference and editable pending input")
    var externallyChanged = saved; externallyChanged.meterNumericMode = .peakHold
    controller.updatePreferences(externallyChanged, preserveNumericDrafts: true); saved = externallyChanged
    try check(mode.selectedSegment == 1 && field("Refresh rate").stringValue == "31" && !feedback.isHidden,
              "Main-panel meter mode updates Settings without erasing a failed numeric edit or its error")
    rejectSave = false
    edit("Falloff", "15")
    await controller.waitForPendingSaveForVerification()
    try check(saved.meterOptions.refreshHz == 31 && saved.meterOptions.falloffDBPerSecond == 15 && saved.meterNumericMode == .peakHold,
              "The next edit retries pending valid settings and merges the latest main-panel mode")
    mode.selectedSegment = 0
    try check(NSApp.sendAction(mode.action!, to: mode.target, from: mode) && saved.meterNumericMode == .realtime,
              "Settings Realtime selector persists through its native action")
    rejectSave = true; mode.selectedSegment = 1
    _ = NSApp.sendAction(mode.action!, to: mode.target, from: mode)
    try check(saved.meterNumericMode == .realtime && mode.selectedSegment == 0 && feedback.stringValue.contains("Fixture save failed"),
              "Failed mode save restores the confirmed selector state")
    rejectSave = false

    edit("Main minimum", "-")
    controller.updateProfile(id: "studio", name: "Studio")
    try check(field("Main minimum").stringValue == "-50" && controller.window?.attachedSheet == nil,
              "Profile handoff immediately shows the new profile without a discard dialog")
    edit("Main minimum", "-70")
    await controller.waitForPendingSaveForVerification()
    try check(saved.mainSliderRange(profileID: "studio").minimumDB == -70 && saved.mainSliderRange(profileID: "bedroom").minimumDB == 10,
              "New-profile Main edits cannot overwrite the former profile")
    controller.updateProfile(id: "bedroom", name: "Bedroom")
    controller.updateAuxSnapshot(auxSnapshot)
    try check(field("Main minimum").stringValue == "-", "Returning to a profile retains its incomplete input without writing it elsewhere")
    edit("Main minimum", "-60")
    await controller.waitForPendingSaveForVerification()
    try check(saved.mainSliderRange(profileID: "bedroom").minimumDB == -60 && saved.mainSliderRange(profileID: "studio").minimumDB == -70,
              "Corrected retained Main input persists only for its original profile")
    rejectSave = true
    edit("Main minimum", "-62")
    await controller.waitForPendingSaveForVerification()
    controller.updateProfile(id: "studio", name: "Studio")
    controller.close()
    rejectSave = false
    controller.updateProfile(id: "bedroom", name: "Bedroom")
    controller.updateAuxSnapshot(auxSnapshot)
    try check(saved.mainSliderRange(profileID: "bedroom").minimumDB == -62 && saved.mainSliderRange(profileID: "studio").minimumDB == -70,
              "Returning after Close automatically retries a retained valid Main edit for its original profile")

    let auxViews = descendants(aux)
    let floor = auxViews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Slider minimum in decibels" }!
    let auxLabel = auxViews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Aux 1 label" }!
    floor.stringValue = "-"; aux.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: floor))
    holdAux = true
    auxLabel.stringValue = "New Left"; aux.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: auxLabel))
    aux.flushPendingChanges()
    try await eventually("Aux autosave fixture did not enter its held callback") { auxEntered }
    edit("Refresh rate", "42")
    button("Follow macOS Output").performClick(nil)
    try check(button("Keep Active Colors").isEnabled && button("Follow macOS Output").isEnabled && field("Refresh rate").isEnabled && saved.followMacOSOutput,
              "A held Aux save does not disable or block unrelated General and Main settings")
    controller.window?.performClose(nil)
    holdAux = false; releaseAux?.resume(); releaseAux = nil
    await controller.waitForPendingSaveForVerification()
    try check(saved.meterOptions.refreshHz == 42 && saved.followMacOSOutput && auxWrites.last?.0 == "bedroom"
              && auxWrites.last?.1.labels["1"] == "New Left" && auxWrites.last?.1.sliderMinimumDB == -80 && floor.stringValue == "-",
              "Close flushes valid Main and Aux changes while an incomplete Aux floor cannot block unrelated settings")
    try check(controller.window?.isVisible == false, "Synthetic native settings checks do not show a window")

    controller.updateFaderRefreshAvailability(reason: "DSP offline")
    try check(!controller.performFaderRefreshForVerification(), "Unavailable DSP refresh has no callback")
    controller.updateFaderRefreshAvailability(reason: nil)
    try check(controller.performFaderRefreshForVerification() && refreshDispatches == 1, "Ready Read Levels action invokes exactly one refresh")
    controller.updateFaderRefreshResult(error: "Fixture refresh failed")
    try check(controller.faderRefreshResult == "Fixture refresh failed", "DSP read failure remains visible independently of persistence")

    var folder = saved; folder.presetsFolderPath = directory.appendingPathComponent(String(repeating: "Long folder name ", count: 12)).path
    controller.updatePreferences(folder); saved = folder
    let pathLabel = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "CamillaDSP presets folder" }!
    root.layoutSubtreeIfNeeded()
    try check(pathLabel.toolTip == folder.presetsFolderPath && pathLabel.lineBreakMode == .byTruncatingMiddle && root.bounds.size == initialSize,
              "Long preset paths truncate without resizing Settings")
    button("Clear").performClick(nil)
    try check(saved.presetsFolderPath == nil, "Clearing the preset folder persists immediately")
    controller.updatePreferences(folder); saved = folder; rejectSave = true
    button("Clear").performClick(nil)
    try check(saved.presetsFolderPath == folder.presetsFolderPath && pathLabel.stringValue == folder.presetsFolderPath && !feedback.isHidden,
              "Failed folder clearing preserves the last saved path and shows its error")
    rejectSave = false

    for tab in [SettingsTab.general, .mainOutput, .auxOutputs] {
        controller.selectTab(tab); root.layoutSubtreeIfNeeded()
        try check(root.bounds.insetBy(dx: -1, dy: -1).contains(tabs.convert(tabs.bounds, to: root)) && root.bounds.size == initialSize,
                  "Every Settings tab fills the available window without a footer")
        controller.window?.setContentSize(NSSize(width: initialSize.width, height: 320)); root.layoutSubtreeIfNeeded()
        try check(root.bounds.insetBy(dx: -1, dy: -1).contains(tabs.convert(tabs.bounds, to: root)), "Short Settings windows keep tab controls reachable")
        if let scroll = tabs.tabViewItems[tab.rawValue].view as? NSScrollView {
            scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
            try check(scroll.documentView!.frame.height > scroll.contentSize.height && scroll.hasVerticalScroller,
                      "A short Settings tab scrolls its content")
        }
        controller.window?.setContentSize(initialSize)
    }
    if let path = ProcessInfo.processInfo.environment["AUTOSWITCH_PANEL_RENDER_DIR"] {
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        controller.updatePreferences(customRestored)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            controller.window?.appearance = NSAppearance(named: appearanceName)
            for (tab, filename) in [(SettingsTab.general, "general-settings"), (.mainOutput, "meter-main-settings"), (.auxOutputs, "aux-settings")] {
                controller.selectTab(tab)
                for short in [false, true] {
                    controller.window?.setContentSize(short ? NSSize(width: initialSize.width, height: 320) : initialSize)
                    root.layoutSubtreeIfNeeded()
                    guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw CheckFailure.failed("Settings render unavailable") }
                    root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure.failed("Settings PNG unavailable") }
                    try data.write(to: destination.appendingPathComponent(filename + (short ? "-short-" : "-") + appearanceName.rawValue + ".png"))
                }
            }
        }
        controller.window?.setContentSize(initialSize)
    }
}

@MainActor func runSilentHUDChecks() async throws {
    for (scenario, passed) in await FeedbackHUDVerification.silentModeChecks() {
        try check(passed, "Silent HUD runtime: \(scenario)")
    }
    print("Silent HUD checks: burst cancellation, quiet error and preview suppression, idle and configured policy passed")
}
