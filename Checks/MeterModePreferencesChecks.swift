import Foundation
import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runMeterModePreferencesChecks() throws {
    let legacy = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
    try check(legacy.meterNumericMode == .realtime && UIPreferences().meterNumericMode == .realtime,
              "Missing meter mode preserves the previous Realtime default")
    var saved = UIPreferences(liveLevels: true, meterNumericMode: .peakHold)
    saved.meterOptions.numberHoldMilliseconds = 1200
    let encoded = try JSONEncoder().encode(saved)
    let decoded = try JSONDecoder().decode(UIPreferences.self, from: encoded)
    try check(decoded == saved,
              "Peak Hold mode persists without changing other meter settings")
    var rejected = false
    do { _ = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"meterNumericMode":"unknown"}"#.utf8)) }
    catch { rejected = true }
    try check(rejected, "Unknown saved meter mode is rejected rather than silently changing policy")
    try check(SignalLevelsPanelVerification.savedModeChangesResetHistoryWithoutCallbacks(),
              "Saved mode changes apply immediately without feedback loops, and reset captured maxima only after applying")
    _ = NSApplication.shared
    try check(verifyMenuMeterModePersistence(),
              "Main meter mode saves before applying, reports save errors, retries, and follows external preference changes")
}

@MainActor private func verifyMenuMeterModePersistence() -> Bool {
    let menu = MenuBarController(command: { _ in ControllerReply() },
        guiCommand: { _ in GUIReply() }, quit: {})
    defer { menu.stop() }
    var preferences = UIPreferences()
    var writes: [SignalMeterNumericMode] = []
    var reject = false
    func save(_ next: UIPreferences) throws {
        if reject { throw SwitcherError.message("Fixture persistence unavailable") }
        writes.append(next.meterNumericMode); preferences = next
    }
    menu.setUIPreferences(preferences, save: save)
    // This fixture supplies samples directly instead of starting a DSP reader.
    // Match that sample source's verified readiness explicitly: MenuBar's default
    // target is unavailable, which intentionally cannot seed Peak Hold maxima.
    menu.panel.metersPanel.setReadingContext(profileID: "fixture", ready: true)
    var snapshot = SignalLevelsSnapshot(); snapshot.enabled = true
    snapshot.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -20, peakDB: -3)], output: [])
    menu.panel.metersPanel.render(snapshot)
    menu.panel.metersPanel.clickNumericHeading()
    guard preferences.meterNumericMode == .peakHold, writes == [.peakHold],
          menu.panel.metersPanel.numericModeCaption == "Peak Hold" else { return false }
    snapshot.levels?.input[0].peakDB = -30
    menu.panel.metersPanel.render(snapshot)
    reject = true
    menu.panel.metersPanel.clickNumericHeading()
    guard writes == [.peakHold], preferences.meterNumericMode == .peakHold,
          menu.panel.metersPanel.numericModeCaption == "Peak Hold",
          menu.panel.metersPanel.numericPeaks == ["-3.0"],
          menu.commandError?.contains("Could not save meter mode") == true else { return false }
    reject = false
    menu.panel.metersPanel.clickNumericHeading()
    guard writes == [.peakHold, .realtime], preferences.meterNumericMode == .realtime,
          menu.panel.metersPanel.numericModeCaption == "Realtime", menu.commandError == nil else { return false }
    preferences.meterNumericMode = .peakHold
    menu.setUIPreferences(preferences, save: save)
    guard writes == [.peakHold, .realtime], menu.panel.metersPanel.numericModeCaption == "Peak Hold" else { return false }
    let reopened = MenuBarController(command: { _ in ControllerReply() },
        guiCommand: { _ in GUIReply() }, quit: {})
    defer { reopened.stop() }
    reopened.setUIPreferences(preferences, save: save)
    return reopened.panel.metersPanel.numericModeCaption == "Peak Hold" && writes == [.peakHold, .realtime]
}
