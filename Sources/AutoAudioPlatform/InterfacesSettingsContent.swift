import AppKit
import AutoAudioCore

/// The application owns persistence and activation. This pane only presents saved profiles.
@MainActor public struct InterfaceProfilesHandlers {
    public let load: () throws -> InterfaceProfilesState
    public let save: (InterfaceProfileDraft) async throws -> InterfaceProfilesState
    public let remove: (String) async throws -> InterfaceProfilesState
    public let activate: (String) async throws -> InterfaceProfilesState
    public init(load: @escaping () throws -> InterfaceProfilesState,
                save: @escaping (InterfaceProfileDraft) async throws -> InterfaceProfilesState,
                remove: @escaping (String) async throws -> InterfaceProfilesState,
                activate: @escaping (String) async throws -> InterfaceProfilesState) {
        self.load = load; self.save = save; self.remove = remove; self.activate = activate
    }
}

@MainActor package final class InterfacesSettingsContent: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let handlers: InterfaceProfilesHandlers?
    private let presetsFolder: () -> String?
    private var state = InterfaceProfilesState(profiles: [], devices: [], activeProfileID: nil)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let activateButton = NSButton(title: "Use Profile", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var busy = false
    private var editor: InterfaceProfileEditor?
    private var operationTask: Task<Void, Never>?
    private var selectedID: String? { state.profiles.indices.contains(table.selectedRow) ? state.profiles[table.selectedRow].id : nil }

    package init(handlers: InterfaceProfilesHandlers?, presetsFolder: @escaping () -> String? = { nil }) {
        self.handlers = handlers; self.presetsFolder = presetsFolder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        if let handlers {
            do { apply(try handlers.load()) } catch { show(error.localizedDescription) }
        } else { show("Interface profiles are unavailable in this session.") }
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        for (key, title, width) in [("name", "Profile", 105.0), ("trigger", "Trigger", 105.0),
                                   ("input", "DSP input", 105.0), ("output", "DSP output", 105.0), ("status", "Status", 110.0)] {
            let column = NSTableColumn(identifier: .init(key)); column.title = title
            column.width = width; column.minWidth = 70
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 28
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.target = self; table.doubleAction = #selector(editProfile)
        table.setAccessibilityLabel("Interface profiles")
        scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        for (button, action) in [(addButton, #selector(addProfile)), (removeButton, #selector(removeProfile)),
                                 (editButton, #selector(editProfile)), (refreshButton, #selector(refreshProfiles)),
                                 (activateButton, #selector(activateProfile))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        addButton.setAccessibilityLabel("Add profile"); addButton.toolTip = "Add an interface profile and choose its startup preset."
        removeButton.setAccessibilityLabel("Remove profile")
        activateButton.toolTip = "Use this profile and its startup preset. This can interrupt audio."
        message.font = .systemFont(ofSize: 11); message.maximumNumberOfLines = 4; message.isHidden = true
        let description = NSTextField(wrappingLabelWithString: "Choose devices and a startup preset for each interface.")
        description.textColor = .secondaryLabelColor; description.font = .systemFont(ofSize: 12)
        let toolbar = NSStackView(views: [addButton, removeButton, editButton, NSView(), refreshButton, activateButton])
        toolbar.spacing = 6
        let content = NSStackView(views: [description, scroll, toolbar, message])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor), toolbar.widthAnchor.constraint(equalTo: content.widthAnchor),
            message.widthAnchor.constraint(equalTo: content.widthAnchor), description.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func apply(_ next: InterfaceProfilesState, selecting id: String? = nil) {
        let selection = id ?? selectedID ?? next.selectedProfileID ?? next.activeProfileID
        state = next; table.reloadData()
        if let index = next.profiles.firstIndex(where: { $0.id == selection }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !next.profiles.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateButtons()
    }

    /// Called from the existing runtime presentation. It does not read files or poll devices.
    package func updateRuntime(activeID: String?, selectedID: String?) {
        guard state.activeProfileID != activeID || state.selectedProfileID != selectedID else { return }
        state = InterfaceProfilesState(profiles: state.profiles, devices: state.devices, activeProfileID: activeID,
            selectedProfileID: selectedID, pendingProfileIDs: state.pendingProfileIDs, profileIssues: state.profileIssues)
        table.reloadData(); updateButtons()
    }
    package func updateDevices(_ devices: [AudioDevice]) {
        guard devices != state.devices else { return }
        apply(InterfaceProfilesState(profiles: state.profiles, devices: devices, activeProfileID: state.activeProfileID,
            selectedProfileID: state.selectedProfileID, pendingProfileIDs: state.pendingProfileIDs, profileIssues: state.profileIssues))
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { state.profiles.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard state.profiles.indices.contains(row) else { return nil }
        let profile = state.profiles[row]
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        switch tableColumn?.identifier.rawValue {
        case "name": label.stringValue = profile.name
        case "trigger": label.stringValue = deviceName(profile.triggerUID)
        case "input": label.stringValue = deviceName(profile.captureUID)
        case "output": label.stringValue = deviceName(profile.playbackUID)
        case "status": label.stringValue = status(for: profile)
        default: return nil
        }
        label.toolTip = state.profileIssues[profile.id] ?? label.stringValue
        return label
    }
    private func deviceName(_ uid: String) -> String { state.devices.first { $0.uid == uid }?.name ?? "Offline: \(uid)" }
    private func status(for profile: InterfaceProfileDraft) -> String {
        if state.activeProfileID == profile.id {
            if state.profileIssues[profile.id] != nil { return "Active · needs review" }
            return state.pendingProfileIDs.contains(profile.id) ? "Active · pending use" : "Active"
        }
        if state.profileIssues[profile.id] != nil { return "Needs review" }
        if state.pendingProfileIDs.contains(profile.id) { return "Pending use" }
        if ![profile.triggerUID, profile.captureUID, profile.playbackUID].allSatisfy({ uid in state.devices.contains { $0.uid == uid } }) {
            return "Offline"
        }
        return state.selectedProfileID == profile.id ? "Selected" : "Available"
    }
    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        show(selectedID.flatMap { state.profileIssues[$0] } ?? "")
    }
    private func updateButtons() {
        let enabled = handlers != nil && !busy
        table.isEnabled = enabled
        addButton.isEnabled = enabled; refreshButton.isEnabled = enabled
        let issue = selectedID.flatMap { state.profileIssues[$0] }
        editButton.isEnabled = enabled && selectedID != nil && issue == nil
        editButton.toolTip = issue
        removeButton.isEnabled = enabled && state.profiles.count > 1 && selectedID != nil
            && selectedID != state.activeProfileID && selectedID != state.selectedProfileID
        activateButton.isEnabled = enabled && selectedID != nil && issue == nil
        activateButton.toolTip = issue ?? "Use this profile and its startup preset. This can interrupt audio."
    }
    @objc private func refreshProfiles() {
        guard !busy, let handlers else { return }
        do { apply(try handlers.load()); show("") } catch { show(error.localizedDescription) }
    }
    @objc private func addProfile() {
        guard !busy else { return }
        var draft = InterfaceProfileDraft(managedFeedUID: nil)
        if let paths = InterfaceProfileStore.suggestedDSPPaths(profiles: state.profiles, activeProfileID: state.activeProfileID) {
            draft.executablePath = paths.executablePath
        }
        draft.name = "New Profile"
        openEditor(draft)
    }
    @objc private func editProfile() {
        guard !busy, editButton.isEnabled, let id = selectedID, let draft = state.profiles.first(where: { $0.id == id }) else { return }
        openEditor(draft)
    }
    private func openEditor(_ draft: InterfaceProfileDraft) {
        guard let handlers, let window, window.attachedSheet == nil else { return }
        let sheet = makeEditor(draft: draft, handlers: handlers)
        editor = sheet; sheet.present(asSheetOf: window)
    }
    private func makeEditor(draft: InterfaceProfileDraft, handlers: InterfaceProfilesHandlers) -> InterfaceProfileEditor {
        InterfaceProfileEditor(draft: draft, devices: state.devices, savedProfiles: state.profiles,
            presetsFolder: presetsFolder, refresh: { try handlers.load().devices }, onSave: { [weak self] draft in
                guard let self else { throw SwitcherError.message("Interfaces settings closed.") }
                self.busy = true; self.updateButtons()
                defer { self.busy = false; self.updateButtons() }
                let next = try await handlers.save(draft)
                self.apply(next, selecting: draft.id)
                self.show("Saved. Use Profile to load these changes.", error: false)
            })
    }
    @objc private func removeProfile() {
        guard !busy, removeButton.isEnabled, let id = selectedID, let window else { return }
        let alert = NSAlert(); alert.messageText = "Remove Profile?"
        alert.informativeText = "Preset YAML and DSP files will be kept."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performOperation { handlers in try await handlers.remove(id) }
        }
    }
    @objc private func activateProfile() {
        guard !busy, activateButton.isEnabled, let id = selectedID else { return }
        performOperation { handlers in try await handlers.activate(id) }
    }
    private func performOperation(_ body: @escaping (InterfaceProfilesHandlers) async throws -> InterfaceProfilesState) {
        guard !busy, let handlers else { return }
        busy = true; updateButtons()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.updateButtons() }
            do { self.apply(try await body(handlers)); self.show("") }
            catch { self.show(error.localizedDescription) }
        }
    }
    private func show(_ text: String, error: Bool = true) {
        message.stringValue = text; message.toolTip = text; message.isHidden = text.isEmpty
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    package var profileIdentifiersForVerification: [String] { state.profiles.map(\.id) }
    package var selectedProfileIdentifierForVerification: String? { selectedID }
    package var editEnabledForVerification: Bool { editButton.isEnabled }
    package var displayedErrorForVerification: String { message.stringValue }
    package var activationEnabledForVerification: Bool { activateButton.isEnabled }
    package var profileStatusesForVerification: [String] { state.profiles.map { status(for: $0) } }
    package func selectProfileForVerification(_ id: String) {
        if let index = state.profiles.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }
    package func editorForVerification(_ draft: InterfaceProfileDraft) -> InterfaceProfileEditor? {
        guard let handlers else { return nil }; return makeEditor(draft: draft, handlers: handlers)
    }
    package func rowsFillWidthForVerification(_ width: CGFloat) -> Bool {
        frame = NSRect(x: 0, y: 0, width: width, height: 420); layoutSubtreeIfNeeded()
        return abs(scroll.frame.width - width) < 1 && table.tableColumns.count == 5
    }
}
