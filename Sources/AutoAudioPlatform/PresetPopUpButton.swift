import AppKit

/// Opening is a finite user action: inspect first, then let AppKit track the
/// current menu. No menu items are replaced underneath an open popup.
@MainActor package final class PresetPopUpButton: NSPopUpButton, NSPopoverDelegate {
    var prepareMenu: (() async -> Bool)?
    private var opening = false
    private var openingGeneration = 0
    private var listPopover: NSPopover?
    var onListTrackingChanged: ((Bool) -> Void)?
    package var usesScrollableList: Bool { itemArray.count > ScrollablePresetList.visibleRows }

    func cancelOpening() {
        openingGeneration += 1; opening = false
        listPopover?.close()
    }

    package override func mouseDown(with event: NSEvent) { performClick(nil) }
    package override func performClick(_ sender: Any?) {
        guard isEnabled, !opening else { return }
        if let listPopover { listPopover.close(); return }
        guard let prepareMenu else { openPreparedMenu(); return }
        opening = true
        openingGeneration += 1
        let generation = openingGeneration
        Task { @MainActor [weak self] in
            let ready = await prepareMenu()
            guard let self, generation == self.openingGeneration else { return }
            self.opening = false
            guard ready, self.isEnabled, self.window?.isVisible == true else { return }
            self.openPreparedMenu()
        }
    }
    private func openPreparedMenu() {
        guard listPopover == nil else { listPopover?.close(); return }
        guard usesScrollableList else { super.performClick(nil); return }
        let list = ScrollablePresetList(items: itemArray, selectedIndex: indexOfSelectedItem, width: bounds.width,
            choose: { [weak self] item in self?.selectSnapshotItem(item) }, dismiss: { [weak self] in self?.listPopover?.close() })
        let popover = NSPopover()
        popover.contentViewController = list; popover.behavior = .transient
        popover.animates = false; popover.delegate = self
        listPopover = popover
        onListTrackingChanged?(true)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
    package func selectSnapshotItem(_ item: NSMenuItem) {
        listPopover?.close()
        guard isEnabled, let id = item.representedObject as? String,
              let current = itemArray.first(where: { $0.representedObject as? String == id }),
              current.isEnabled else { return }
        select(current)
        sendAction(action, to: target)
    }
    package func popoverDidClose(_ notification: Notification) {
        listPopover = nil
        onListTrackingChanged?(false)
    }
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
