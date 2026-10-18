import AppKit
import AutoAudioPlatform

/// Uses an owned native popup, synthetic keys and a single cancellation deadline.
/// This proves External is an informational selection, not a disabled popup.
enum PresetPopupVerification {
    @MainActor static func externalSelectionOpens() -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 70),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let picker = PresetPopUpButton(frame: NSRect(x: 15, y: 20, width: 290, height: 26), pullsDown: false)
        picker.addItems(withTitles: ["External: GUI preset", "Flat"])
        picker.lastItem?.representedObject = "flat"
        picker.menu?.autoenablesItems = false
        let receiver = PresetPopupFixture(window: window, picker: picker)
        picker.target = receiver; picker.action = #selector(PresetPopupFixture.selected(_:))
        picker.menu?.delegate = receiver
        window.contentView?.addSubview(picker)
        let deadline = Timer(timeInterval: 1, repeats: false) { _ in picker.menu?.cancelTracking() }
        RunLoop.main.add(deadline, forMode: .eventTracking)
        RunLoop.main.add(deadline, forMode: .common)
        defer { deadline.invalidate(); window.close() }
        window.makeKeyAndOrderFront(nil)
        picker.performClick(nil)
        let passed = receiver.opened && receiver.selectedID == "flat"
            && picker.selectedItem?.representedObject as? String == "flat"
        if !passed {
            print("Native preset popup: opened=\(receiver.opened), selected=\(receiver.selectedID ?? "none"), title=\(picker.title)")
        }
        return passed
    }
}

@MainActor private final class PresetPopupFixture: NSObject, NSMenuDelegate {
    let window: NSWindow
    let picker: NSPopUpButton
    var opened = false
    var selectedID: String?
    init(window: NSWindow, picker: NSPopUpButton) { self.window = window; self.picker = picker }
    @objc func selected(_ sender: NSPopUpButton) { selectedID = sender.selectedItem?.representedObject as? String }
    func menuWillOpen(_ menu: NSMenu) {
        opened = true
        for (characters, code) in [("\u{f701}", UInt16(125)), ("\r", UInt16(36))] {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) { NSApp.postEvent(event, atStart: false) }
        }
    }
}
