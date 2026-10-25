import AppKit
import AutoAudioCore

@MainActor private final class InterfaceDeviceBrowserTable: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A read-only device inventory sheet. The only externally visible action is
/// the explicit selection callback after Choose is pressed.
@MainActor public final class InterfaceDeviceBrowser: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let device: AudioDevice?
        let uid: String
        let title: String
        var isOffline: Bool { device == nil }
    }

    private let role: DeviceRole
    private let refreshDevices: @MainActor () throws -> [AudioDevice]
    private let onSelect: @MainActor (String) -> Void
    private let offlineUIDs: [String]
    private var rows: [Row] = []
    private var selectedUID: String?

    private let table = InterfaceDeviceBrowserTable()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: "Copy UID", target: nil, action: nil)
    private let chooseButton = NSButton(title: "Choose", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    public init(devices: [AudioDevice], selectedUID: String?, role: DeviceRole, savedUIDs: [String],
                refresh: @escaping @MainActor () throws -> [AudioDevice],
                onSelect: @escaping @MainActor (String) -> Void) {
        self.role = role
        self.refreshDevices = refresh
        self.onSelect = onSelect
        self.selectedUID = selectedUID.flatMap { $0.isEmpty ? nil : $0 }
        self.offlineUIDs = Array(Set((savedUIDs + [selectedUID].compactMap { $0 }).filter { !$0.isEmpty })).sorted()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Choose Device"
        window.minSize = NSSize(width: 600, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        reloadRows(from: devices)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Attach this controller's window as a sheet. The owner should retain this
    /// controller until the sheet closes.
    public func present(asSheetOf parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }
        let initialUID = selectedUID
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder

        for (identifier, title, width) in [
            ("device", "Device", CGFloat(230)),
            ("input", "Input channels", CGFloat(105)),
            ("output", "Output channels", CGFloat(110)),
            ("availability", "Availability", CGFloat(155))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.rowHeight = 25
        table.onReturn = { [weak self] in self?.chooseSelected() }
        table.onEscape = { [weak self] in self?.closeSheet() }
        table.setAccessibilityIdentifier("interfaceDeviceBrowser.table")
        scroll.documentView = table

        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.textColor = .secondaryLabelColor
        details.lineBreakMode = .byCharWrapping
        details.setAccessibilityLabel("Selected device UID")
        reason.textColor = .secondaryLabelColor
        reason.font = .systemFont(ofSize: 11)
        reason.setAccessibilityIdentifier("interfaceDeviceBrowser.reason")
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.isHidden = true
        errorLabel.setAccessibilityIdentifier("interfaceDeviceBrowser.refreshError")

        copyButton.target = self
        copyButton.action = #selector(copyUID)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        chooseButton.target = self
        chooseButton.action = #selector(choose)
        chooseButton.keyEquivalent = "\r"
        chooseButton.setAccessibilityIdentifier("interfaceDeviceBrowser.choose")
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(closeSheet))
        cancelButton.keyEquivalent = "\u{1b}"

        let identityRow = NSStackView(views: [details, copyButton])
        identityRow.orientation = .horizontal
        identityRow.alignment = .centerY
        identityRow.spacing = 8
        details.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [refreshButton, NSView(), cancelButton, chooseButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let content = NSStackView(views: [scroll, identityRow, reason, errorLabel, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            identityRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            reason.widthAnchor.constraint(equalTo: content.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.uid == initialUID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateSelection()
        window?.defaultButtonCell = chooseButton.cell as? NSButtonCell
    }

    private func reloadRows(from devices: [AudioDevice]) {
        let uniqueDevices = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let online = uniqueDevices.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        rows = online.map { Row(device: $0, uid: $0.uid, title: $0.name) }
        let onlineUIDs = Set(uniqueDevices.keys)
        rows += offlineUIDs.filter { !onlineUIDs.contains($0) }.map {
            Row(device: nil, uid: $0, title: "Saved device (offline)")
        }
        if let selectedUID, !rows.contains(where: { $0.uid == selectedUID }) {
            rows.append(Row(device: nil, uid: selectedUID, title: "Saved device (offline)"))
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let item = rows[row]
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        switch identifier {
        case "device": label.stringValue = item.title
        case "input": label.stringValue = item.device.map { String($0.inputChannels) } ?? "—"
        case "output": label.stringValue = item.device.map { String($0.outputChannels) } ?? "—"
        case "availability": label.stringValue = item.isOffline ? "Offline reference" : "Available"
        default: return nil
        }
        label.toolTip = identifier == "device" ? item.title : label.stringValue
        return label
    }

    public func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func updateSelection() {
        guard rows.indices.contains(table.selectedRow) else {
            selectedUID = nil
            details.stringValue = ""
            reason.stringValue = "Select a device to see its UID."
            copyButton.isEnabled = false
            chooseButton.isEnabled = false
            return
        }
        let row = rows[table.selectedRow]
        selectedUID = row.uid
        details.stringValue = "UID: \(row.uid)"
        copyButton.isEnabled = true
        let eligibility = eligibilityReason(for: row)
        reason.stringValue = eligibility ?? ""
        reason.isHidden = eligibility == nil
        chooseButton.isEnabled = !row.isOffline && eligibility == nil
    }

    private func eligibilityReason(for row: Row) -> String? {
        guard let device = row.device else { return "This saved device is offline and cannot be chosen." }
        return role.unavailableReason(for: device)
    }

    @objc private func copyUID() {
        guard let selectedUID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedUID, forType: .string)
    }

    @objc private func refresh() {
        errorLabel.isHidden = true
        do {
            let devices = try refreshDevices()
            let oldUID = selectedUID
            reloadRows(from: devices)
            table.reloadData()
            if let oldUID, let index = rows.firstIndex(where: { $0.uid == oldUID }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else if !rows.isEmpty {
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            updateSelection()
        } catch {
            errorLabel.stringValue = "Could not refresh devices: \(error.localizedDescription)"
            errorLabel.isHidden = false
        }
    }

    @objc private func choose() { chooseSelected() }

    private func chooseSelected() {
        guard chooseButton.isEnabled, let selectedUID else { return }
        onSelect(selectedUID)
        closeSheet()
    }

    @objc private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel); window.orderOut(nil) }
        else { close() }
    }

    package var visibleUIDsForVerification: [String] { rows.map(\.uid) }
    package var chooseEnabledForVerification: Bool { chooseButton.isEnabled }
    package var selectedUIDForVerification: String? { selectedUID }
    package var displayedReasonForVerification: String { reason.stringValue }
    package var refreshErrorForVerification: String { errorLabel.stringValue }
    package var columnTitlesForVerification: [String] { table.tableColumns.map(\.title) }
    package func selectUIDForVerification(_ uid: String) {
        guard let index = rows.firstIndex(where: { $0.uid == uid }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        updateSelection()
    }
    package func refreshForVerification() { refresh() }
    package func chooseForVerification() { chooseSelected() }
    package func columnWidthsFitForVerification(_ width: CGFloat) -> Bool {
        window?.setContentSize(NSSize(width: width, height: 500))
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let viewportWidth = table.enclosingScrollView?.contentSize.width else { return false }
        return table.tableColumns.reduce(CGFloat.zero) { $0 + $1.width } <= viewportWidth
    }
}
