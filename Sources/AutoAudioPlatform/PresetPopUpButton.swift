import AppKit

/// Opening is a finite user action: inspect first, then let AppKit track the
/// current menu. No menu items are replaced underneath an open popup.
@MainActor package final class PresetPopUpButton: NSPopUpButton {
    var prepareMenu: (() async -> Bool)?
    private var opening = false
    private var openingGeneration = 0

    func cancelOpening() { openingGeneration += 1; opening = false }

    package override func mouseDown(with event: NSEvent) { performClick(nil) }
    package override func performClick(_ sender: Any?) {
        guard isEnabled, !opening else { return }
        guard let prepareMenu else { super.performClick(sender); return }
        opening = true
        openingGeneration += 1
        let generation = openingGeneration
        Task { @MainActor [weak self] in
            let ready = await prepareMenu()
            guard let self, generation == self.openingGeneration else { return }
            self.opening = false
            guard ready, self.isEnabled, self.window?.isVisible == true else { return }
            self.openNativeMenu()
        }
    }
    private func openNativeMenu() { super.performClick(nil) }
    package override func keyDown(with event: NSEvent) {
        // Preserve native type selection and navigation after opening; the
        // initial keyboard opening follows the same fresh-read path as a click.
        if [" ", "\r", "\u{f700}", "\u{f701}"].contains(event.charactersIgnoringModifiers ?? "") {
            performClick(nil)
        } else { super.keyDown(with: event) }
    }
    package override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
}
