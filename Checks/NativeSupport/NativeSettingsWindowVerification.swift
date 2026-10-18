import AppKit
import AutoAudioPlatform

@MainActor extension NativeSettingsWindow {
    @discardableResult func performFaderRefreshForVerification() -> Bool {
        guard refreshFadersButton.isEnabled else { return false }
        refreshFadersButton.performClick(nil)
        return true
    }

    func waitForPendingSaveForVerification() async { await waitForPendingChanges() }

    func performCloseShortcutForVerification(_ characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return false }
        return window.performKeyEquivalent(with: event)
    }
}
