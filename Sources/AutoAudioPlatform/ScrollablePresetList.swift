import AppKit

/// A bounded view of a menu snapshot. It owns presentation only, never preset I/O.
@MainActor package final class ScrollablePresetList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    package static let visibleRows = 8
    private let items: [NSMenuItem]
    private let selectedIndex: Int
    private let choose: (NSMenuItem) -> Void
    private let dismiss: () -> Void
    private let table = PresetListTable()
    package let scroll = NSScrollView()
    package var rowCount: Int { items.count }
    package var viewportHeight: CGFloat { min(CGFloat(items.count), CGFloat(Self.visibleRows)) * 24 }

    package init(items: [NSMenuItem], selectedIndex: Int, width: CGFloat,
         choose: @escaping (NSMenuItem) -> Void, dismiss: @escaping () -> Void) {
        self.items = items.map { $0.copy() as! NSMenuItem }
        self.selectedIndex = selectedIndex
        self.choose = choose; self.dismiss = dismiss
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: max(220, min(380, width)), height: viewportHeight + 8)
    }
    package required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    package override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        table.frame = NSRect(x: 0, y: 0, width: preferredContentSize.width - 4, height: CGFloat(items.count) * 24)
        table.headerView = nil; table.rowHeight = 24; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.allowsEmptySelection = false
        table.allowsMultipleSelection = false; table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preset"))
        column.width = preferredContentSize.width; table.addTableColumn(column)
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        table.onAccept = { [weak self] in self?.accept(row: self?.table.selectedRow ?? -1) }
        table.onMove = { [weak self] direction in self?.moveSelection(by: direction) }
        table.onDismiss = dismiss
        table.setAccessibilityLabel("Presets")
        scroll.documentView = table
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
        table.reloadData()
        let initial = items.indices.contains(selectedIndex) && items[selectedIndex].isEnabled
            ? selectedIndex : items.firstIndex(where: { $0.isEnabled })
        if let initial {
            table.selectRowIndexes(IndexSet(integer: initial), byExtendingSelection: false)
            table.scrollRowToVisible(initial)
        }
    }
    package override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(table)
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }
    package func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    package func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].isEnabled }
    package func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { items[row].title }
    package func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { items[row].title }
    package func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: items[row].title)
        text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingTail
        text.textColor = items[row].isEnabled ? .labelColor : .disabledControlTextColor
        if items[row].isEnabled, let title = items[row].attributedTitle, title.length > 0 { text.attributedStringValue = title }
        let mark = NSImageView()
        if row == selectedIndex { mark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current preset") }
        mark.imageScaling = .scaleProportionallyDown
        for child in [mark, text] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            mark.widthAnchor.constraint(equalToConstant: 14), mark.heightAnchor.constraint(equalToConstant: 14),
            mark.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = text; cell.imageView = mark
        cell.toolTip = items[row].toolTip ?? items[row].title
        return cell
    }
    package func moveSelection(by direction: Int) {
        var row = table.selectedRow < 0 ? (direction > 0 ? -1 : items.count) : table.selectedRow
        row += direction
        while items.indices.contains(row) {
            if items[row].isEnabled {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
                return
            }
            row += direction
        }
    }
    @objc private func clicked() { accept(row: table.clickedRow) }
    package func accept(row: Int) {
        guard items.indices.contains(row), items[row].isEnabled,
              items[row].representedObject is String else { return }
        choose(items[row])
    }
}

@MainActor private final class PresetListTable: NSTableView {
    var onAccept: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125 { onMove?(1); return }
        if event.keyCode == 126 { onMove?(-1); return }
        if event.keyCode == 53 { onDismiss?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { onAccept?(); return }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
