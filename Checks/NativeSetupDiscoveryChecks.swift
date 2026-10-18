import AppKit
import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runNativeSetupDiscoveryChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-discovery-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func identified<T: NSView>(_ identifier: String, in window: NSWindow, as type: T.Type) throws -> T {
        guard let content = window.contentView,
              let found = descendants(content).compactMap({ $0 as? T }).first(where: { $0.accessibilityIdentifier() == identifier }) else {
            throw CheckFailure.failed("Missing discovery UI element: " + identifier)
        }
        return found
    }
    func button(_ title: String, in window: NSWindow) throws -> NSButton {
        guard let content = window.contentView,
              let found = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
            throw CheckFailure.failed("Missing discovery button: " + title)
        }
        return found
    }
    func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CheckFailure.failed("Setup discovery UI did not settle inside its finite deadline")
    }
    let result = SetupDiscoveryResult(dsp: [
        .init(executablePath: "/fixture/first/camilladsp", configurationPath: "/fixture/first/dsp.yml",
              launchAgentPath: "/fixture/first/dsp.plist", websocketPort: 4321),
        .init(executablePath: "/fixture/second/camilladsp")
    ], gui: [.init(executablePath: "/fixture/camillagui", configurationPath: "/fixture/gui.yml", url: "http://127.0.0.1:5555"),
             .init(executablePath: "/fixture/other/camillagui", configurationPath: "/fixture/other/gui.yml")],
       summary: "Found installations.", searchTruncated: false)
    let configuration = root.appendingPathComponent("config.json")
    let state = root.appendingPathComponent("runtime.json")
    let controller = SetupWindowController(configurationURL: configuration, runtimeStateURL: state,
        devices: { [] }, discovery: { result }, onActivate: { _ in throw CheckFailure.failed("Discovery must not activate") })
    guard let window = controller.window else { throw CheckFailure.failed("Missing Setup window") }
    controller.showSetup()
    defer {
        if let sheet = window.attachedSheet {
            NSApplication.shared.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
        }
        window.close()
    }
    let dsp = try identified("setup.dspExecutable", in: window, as: NSTextField.self)
    let gui = try identified("setup.guiExecutable", in: window, as: NSTextField.self)
    dsp.stringValue = "/manual/camilladsp"; gui.stringValue = "/manual/gui"
    let find = try identified("setup.findAutomatically", in: window, as: NSButton.self)
    find.performClick(nil)
    try await settle { window.attachedSheet != nil }
    guard let firstSheet = window.attachedSheet else { throw CheckFailure.failed("Missing candidate sheet") }
    let useSelection = try button("Use Selection", in: firstSheet)
    try check(!useSelection.isEnabled,
              "Discovery requires an explicit candidate choice before applying")
    try check(dsp.stringValue == "/manual/camilladsp" && gui.stringValue == "/manual/gui",
              "Finding candidates leaves manually entered paths unchanged")
    try button("Cancel", in: firstSheet).performClick(nil)
    try await settle { window.attachedSheet == nil }
    try check(dsp.stringValue == "/manual/camilladsp" && gui.stringValue == "/manual/gui",
              "Cancel preserves all manual choices")

    find.performClick(nil)
    try await settle { window.attachedSheet != nil }
    guard let dspSheet = window.attachedSheet else { throw CheckFailure.failed("Missing DSP choices") }
    let dspMenu = try identified("setup.discovery.dsp", in: dspSheet, as: NSPopUpButton.self)
    dspMenu.selectItem(at: 1)
    NSApplication.shared.sendAction(dspMenu.action!, to: dspMenu.target, from: dspMenu)
    try button("Use Selection", in: dspSheet).performClick(nil)
    try await settle { window.attachedSheet == nil }
    let yaml = try identified("setup.dspConfiguration", in: window, as: NSTextField.self)
    let job = try identified("setup.dspJob", in: window, as: NSTextField.self)
    let port = try identified("setup.dspPort", in: window, as: NSTextField.self)
    try check(dsp.stringValue == "/fixture/first/camilladsp" && yaml.stringValue == "/fixture/first/dsp.yml" &&
              job.stringValue == "/fixture/first/dsp.plist" && port.stringValue == "4321" && gui.stringValue == "/manual/gui",
              "Selecting DSP fills its paired configuration, job and port while preserving GUI choices")

    let absent = try button("CamillaGUI is not installed", in: window)
    absent.performClick(nil)
    find.performClick(nil)
    try await settle { window.attachedSheet != nil }
    guard let guiSheet = window.attachedSheet else { throw CheckFailure.failed("Missing GUI choices") }
    let guiMenu = try identified("setup.discovery.gui", in: guiSheet, as: NSPopUpButton.self)
    guiMenu.selectItem(at: 1)
    NSApplication.shared.sendAction(guiMenu.action!, to: guiMenu.target, from: guiMenu)
    try button("Use Selection", in: guiSheet).performClick(nil)
    try await settle { window.attachedSheet == nil }
    let guiConfig = try identified("setup.guiConfiguration", in: window, as: NSTextField.self)
    let guiURL = try identified("setup.guiURL", in: window, as: NSTextField.self)
    try check(gui.stringValue == "/fixture/camillagui" && guiConfig.stringValue == "/fixture/gui.yml" &&
              guiURL.stringValue == "http://127.0.0.1:5555" && absent.state == .off && gui.isEnabled &&
              dsp.stringValue == "/fixture/first/camilladsp",
              "Explicit GUI selection re-enables GUI fields, fills the pair and preserves DSP selection")
    find.performClick(nil)
    try await settle { window.attachedSheet != nil }
    guard let unknownSheet = window.attachedSheet else { throw CheckFailure.failed("Missing alternate GUI choices") }
    let unknownMenu = try identified("setup.discovery.gui", in: unknownSheet, as: NSPopUpButton.self)
    unknownMenu.selectItem(at: 2)
    NSApplication.shared.sendAction(unknownMenu.action!, to: unknownMenu.target, from: unknownMenu)
    try button("Use Selection", in: unknownSheet).performClick(nil)
    try await settle { window.attachedSheet == nil }
    try check(guiConfig.stringValue == "/fixture/other/gui.yml" && guiURL.stringValue.isEmpty && !guiURL.isHiddenOrHasHiddenAncestor,
              "A discovered GUI configuration without a safe address clears stale endpoint and exposes manual entry")
    try check(!FileManager.default.fileExists(atPath: configuration.path) && !FileManager.default.fileExists(atPath: state.path),
              "Discovery and applying choices write no settings or runtime state")

    let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
    let closingConfig = root.appendingPathComponent("closing/config.json")
    let closing = SetupWindowController(configurationURL: closingConfig,
        runtimeStateURL: root.appendingPathComponent("closing/runtime.json"), devices: { [] }, discovery: {
            started.signal()
            _ = finish.wait(timeout: .now() + 2)
            return result
        }, onActivate: { _ in throw CheckFailure.failed("Closing discovery must not activate") })
    guard let closingWindow = closing.window else { throw CheckFailure.failed("Missing closing fixture window") }
    defer { finish.signal(); closingWindow.close() }
    closing.showSetup()
    try identified("setup.findAutomatically", in: closingWindow, as: NSButton.self).performClick(nil)
    try await settle { started.wait(timeout: .now()) == .success }
    closingWindow.close(); finish.signal()
    try await Task.sleep(nanoseconds: 50_000_000)
    try check(closingWindow.attachedSheet == nil && !FileManager.default.fileExists(atPath: closingConfig.path),
              "Closing Setup during discovery prevents a late confirmation sheet or saved files")

    let empty = SetupWindowController(configurationURL: root.appendingPathComponent("empty/config.json"),
        runtimeStateURL: root.appendingPathComponent("empty/runtime.json"), devices: { [] },
        discovery: { .init(summary: "No installations found.") },
        onActivate: { _ in throw CheckFailure.failed("Empty discovery must not activate") })
    guard let emptyWindow = empty.window else { throw CheckFailure.failed("Missing empty fixture window") }
    defer { emptyWindow.close() }
    empty.showSetup()
    let emptyFind = try identified("setup.findAutomatically", in: emptyWindow, as: NSButton.self)
    emptyFind.performClick(nil)
    try await settle { emptyFind.isEnabled }
    try check(emptyWindow.attachedSheet == nil && !FileManager.default.fileExists(atPath: root.appendingPathComponent("empty/config.json").path),
              "An empty discovery result keeps manual Setup available without presenting or saving a choice")
    print("Native Setup discovery confirmation, cancellation and pairing checks passed.")
}
