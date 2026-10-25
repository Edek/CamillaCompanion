import AppKit
import AutoAudioPlatform

@MainActor func runScrollablePresetChecks() throws {
    let picker = PresetPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 24), pullsDown: false)
    for i in 0..<8 {
        picker.addItem(withTitle: "Preset \(i)"); picker.lastItem?.representedObject = "id-\(i)"
    }
    try check(!picker.usesScrollableList, "Eight preset entries keep the native compact menu")
    for i in 8..<25 {
        picker.addItem(withTitle: "Preset \(i)"); picker.lastItem?.representedObject = "id-\(i)"
    }
    picker.menu?.autoenablesItems = false
    picker.item(at: 2)?.isEnabled = false
    picker.selectItem(at: 20)
    try check(picker.usesScrollableList && picker.numberOfItems == 25, "Overflow scrolls without truncating the library")
    var selected: String?
    let list = ScrollablePresetList(items: picker.itemArray, selectedIndex: 20, width: 250,
        choose: { selected = $0.representedObject as? String }, dismiss: {})
    _ = list.view
    list.view.layoutSubtreeIfNeeded()
    let table = list.scroll.documentView as! NSTableView
    try check(list.rowCount == 25 && list.viewportHeight == 8 * 24 &&
        list.preferredContentSize.height == 8 * 24 + 8, "Preset viewport stays at eight rows for a larger library")
    try check(table.selectedRow == 20, "Scrollable selector initially focuses the current preset")
    list.accept(row: 2)
    try check(selected == nil, "Disabled preset cannot be activated")
    list.accept(row: 24)
    try check(selected == "id-24", "Preset beyond the visible viewport remains selectable")
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    list.moveSelection(by: 1)
    try check(table.selectedRow == 3, "Keyboard navigation skips disabled presets")
    let snapshot = picker.item(at: 24)!.copy() as! NSMenuItem
    picker.item(at: 24)?.isEnabled = false
    picker.selectSnapshotItem(snapshot)
    try check(picker.indexOfSelectedItem == 20, "Fresh eligibility rejects a preset disabled after opening")
    picker.removeAllItems()
    picker.addItem(withTitle: "Different profile"); picker.lastItem?.representedObject = "other"
    picker.selectSnapshotItem(snapshot)
    try check(picker.indexOfSelectedItem == 0, "A stale list cannot select a removed preset")
    let panel = AudioControlPanel()
    panel.setPresetChoices((0..<12).map { (id: "file-\($0)", title: "Flat") }, selectedID: "file-11", enabled: true, reason: nil)
    try check(panel.presetPicker.numberOfItems == 12 && panel.presetPicker.usesScrollableList &&
        panel.presetPicker.selectedItem?.representedObject as? String == "file-11", "Duplicate display titles retain every preset identity")
    print("Scrollable preset checks: eight-row viewport, complete library, current selection, disabled/stale rejection and keyboard navigation passed")
}
