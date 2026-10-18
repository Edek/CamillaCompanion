import AppKit
import AutoAudioCore

@MainActor package final class AuxSettingsTextField: NSTextField {
    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a", let editor = currentEditor() {
            editor.selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Profile presentation settings with serialized, group-validated persistence.
@MainActor public final class AuxFaderSettingsContent: NSView, NSTextFieldDelegate {
    package struct Row {
        package let visible: NSButton
        package let label: AuxSettingsTextField
        package let group: NSPopUpButton
    }
    private var snapshot: AuxFaderSnapshot
    public private(set) var profileID: String?
    private var selectedProfileID: String?
    private var sessions: [String: EditSession] = [:]
    private var restoringInputs = false
    private var inFlightProfileID: String?
    private var debounceTask: Task<Void, Never>?
    package private(set) var saveTask: Task<Void, Never>?
    public var onSave: ((String, AuxPreferences) async throws -> Void)? { didSet { updateEnabled() } }
    public var onDraftChanged: (() -> Void)?
    package private(set) var invalidField: NSView?
    package private(set) var rows: [Int: Row] = [:]
    package private(set) var rememberedVisibleIDs: [Int]
    package let stack = NSStackView()
    package let linkMutes = NSButton(checkboxWithTitle: "Link Mutes", target: nil, action: nil)
    package let minimum = AuxSettingsTextField(string: "")
    private let visibilityButton = NSButton(title: "Hide All", target: nil, action: nil)
    package let notice = NSTextField(wrappingLabelWithString: "")
    package let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var availabilityError: String?

    public init(snapshot: AuxFaderSnapshot) {
        self.snapshot = snapshot
        profileID = snapshot.profileID
        selectedProfileID = snapshot.profileID
        rememberedVisibleIDs = snapshot.preferences.lastVisibleIDs
        super.init(frame: .zero)
        let root = self
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
        let explanation = NSTextField(wrappingLabelWithString:
            "Choose visible Aux faders, labels and groups.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        stack.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for id in 1...4 {
            let visible = NSButton(checkboxWithTitle: "Aux \(id)", target: self, action: #selector(visibilityChanged))
            visible.widthAnchor.constraint(equalToConstant: 75).isActive = true
            let label = AuxSettingsTextField(string: "")
            label.placeholderString = "Label (optional)"
            label.setAccessibilityLabel("Aux \(id) label")
            label.widthAnchor.constraint(equalToConstant: 230).isActive = true
            label.delegate = self
            let group = NSPopUpButton(frame: .zero, pullsDown: false)
            group.addItems(withTitles: ["Unlinked", "Group 1", "Group 2"])
            group.target = self; group.action = #selector(groupChanged)
            group.widthAnchor.constraint(equalToConstant: 135).isActive = true
            group.setAccessibilityLabel("Aux \(id) group")
            rows[id] = Row(visible: visible, label: label, group: group)
            let row = NSStackView(views: [visible, label, group])
            row.orientation = .horizontal; row.spacing = 12
            stack.addArrangedSubview(row)
        }
        visibilityButton.target = self; visibilityButton.action = #selector(toggleVisibility)
        visibilityButton.bezelStyle = .rounded
        stack.addArrangedSubview(visibilityButton)
        let separator = NSBox(); separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        linkMutes.setAccessibilityHelp("Mute grouped outputs together. Shift-click affects only one output.")
        linkMutes.target = self; linkMutes.action = #selector(draftChanged)
        stack.addArrangedSubview(linkMutes)
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.maximumNumberOfLines = 9
        notice.setAccessibilityLabel("Preserved group level differences")
        stack.addArrangedSubview(notice)
        notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let rangeSeparator = NSBox(); rangeSeparator.boxType = .separator
        stack.addArrangedSubview(rangeSeparator)
        rangeSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let rangeHeading = NSTextField(labelWithString: "Slider Range")
        rangeHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(rangeHeading)
        minimum.widthAnchor.constraint(equalToConstant: 85).isActive = true
        minimum.setAccessibilityLabel("Slider minimum in decibels")
        minimum.delegate = self
        let minimumRow = NSStackView(views: [NSTextField(labelWithString: "Minimum"), minimum, NSTextField(labelWithString: "dB")])
        minimumRow.orientation = .horizontal; minimumRow.spacing = 9
        stack.addArrangedSubview(minimumRow)
        let floorHelp = NSTextField(wrappingLabelWithString: "Range: -150 to 50 dB. Display only; DSP gain limits still apply.")
        floorHelp.font = .systemFont(ofSize: 11); floorHelp.textColor = .secondaryLabelColor
        stack.addArrangedSubview(floorHelp)
        floorHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3; errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setAccessibilityLabel("Aux settings error")
        errorLabel.heightAnchor.constraint(equalToConstant: 42).isActive = true
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        resetInputs(to: snapshot.preferences)
        if let id = profileID {
            sessions[id] = EditSession(saved: snapshot.preferences, baseline: draftState, inputs: draftState)
        }
        updateSnapshot(snapshot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rebinding never submits the former profile's pending edits to the new one.
    public func selectProfile(_ id: String?) {
        guard id != selectedProfileID else { return }
        debounceTask?.cancel(); debounceTask = nil
        selectedProfileID = id; profileID = id
        if let id, var session = sessions[id] {
            if session.failure != nil && candidate(inputs: session.inputs, saved: session.saved).preferences != session.saved {
                // Returning to this profile is an explicit retry. Passive
                // snapshots alone cannot retry a failed persistence operation.
                session.failure = nil; session.revision += 1
                sessions[id] = session
            }
            restoreInputs(session.inputs)
        } else { resetInputs(to: AuxPreferences()) }
        invalidateAuthority()
    }

    public func invalidateAuthority() {
        snapshot.preferencesEditable = false; snapshot.ready = false
        availabilityError = "Aux settings are unavailable while the selected profile or settings authority is changing."
        refreshFeedback(); updateNotice(); updateEnabled()
    }

    public func updateSnapshot(_ snapshot: AuxFaderSnapshot) {
        self.snapshot = snapshot
        guard snapshot.profileID == selectedProfileID, let id = selectedProfileID else {
            availabilityError = "Aux settings are unavailable for the selected profile."
            refreshFeedback(); updateNotice(); updateEnabled(); return
        }
        profileID = id
        let incoming = inputs(for: snapshot.preferences)
        if var session = sessions[id] {
            if session.awaitingConfirmation == snapshot.preferences { session.awaitingConfirmation = nil }
            if inFlightProfileID != id && session.awaitingConfirmation == nil {
                for key in EditKey.all {
                    if session.inputs.matches(session.baseline, key: key) && !isEditing(key) { session.inputs.copy(incoming, key: key) }
                    session.baseline.copy(incoming, key: key)
                }
                session.saved = snapshot.preferences
            }
            sessions[id] = session
            restoreInputs(session.inputs)
        } else {
            sessions[id] = EditSession(saved: snapshot.preferences, baseline: incoming, inputs: incoming)
            restoreInputs(incoming)
        }
        if snapshot.preferencesEditable || (snapshot.busy && snapshot.error == nil) {
            availabilityError = nil
        } else {
            availabilityError = snapshot.error ?? "Aux settings are unavailable for the selected profile."
        }
        refreshFeedback(); updateNotice(); updateEnabled()
        if sessions[id]?.failure == nil { scheduleAutosave(debounce: false) }
    }

    private func resetInputs(to preferences: AuxPreferences) { restoreInputs(inputs(for: preferences)) }

    private func restoreInputs(_ state: DraftState) {
        restoringInputs = true
        defer { restoringInputs = false }
        rememberedVisibleIDs = state.remembered
        for id in 1...4 {
            guard let row = rows[id] else { continue }
            row.visible.state = state.visible.contains(id) ? .on : .off
            if row.label.stringValue != state.labels[id - 1] { row.label.stringValue = state.labels[id - 1] }
            row.group.selectItem(at: state.groups[id - 1])
        }
        linkMutes.state = state.mutes ? .on : .off
        if minimum.stringValue != state.minimum { minimum.stringValue = state.minimum }
        visibilityButton.title = state.visible.isEmpty ? "Restore Previous Faders" : "Hide All"
        updateNotice()
    }

    private func inputs(for preferences: AuxPreferences) -> DraftState {
        DraftState(visible: preferences.visibleIDs, labels: (1...4).map { preferences.labels[String($0)] ?? "" },
            groups: (1...4).map { id in preferences.linkGroups.firstIndex(where: { $0.contains(id) }).map { $0 + 1 } ?? 0 },
            mutes: preferences.linkMutes, minimum: String(format: "%g", preferences.sliderMinimumDB), remembered: preferences.lastVisibleIDs)
    }

    package var visibleIDs: [Int] { (1...4).filter { rows[$0]?.visible.state == .on } }
    private var groups: [[Int]] {
        (1...2).map { index in (1...4).filter { rows[$0]?.group.indexOfSelectedItem == index } }
    }

    public func draftPreferences() throws -> AuxPreferences {
        guard let id = profileID, let session = sessions[id] else { throw SwitcherError.message("Select an Aux profile first.") }
        let candidate = candidate(inputs: draftState, saved: session.saved)
        invalidField = candidate.errors.first?.1
        if let error = candidate.errors.first { throw SwitcherError.message(error.0) }
        return candidate.preferences
    }

    @objc private func visibilityChanged() {
        visibilityButton.title = visibleIDs.isEmpty ? "Restore Previous Faders" : "Hide All"
        changed(debounce: false)
    }

    @objc package func toggleVisibility() {
        let ids = visibleIDs
        let restored: [Int]
        if ids.isEmpty { restored = rememberedVisibleIDs.isEmpty ? Array(1...4) : rememberedVisibleIDs }
        else { rememberedVisibleIDs = ids; restored = [] }
        for id in 1...4 { rows[id]?.visible.state = restored.contains(id) ? .on : .off }
        visibilityChanged()
    }

    @objc private func groupChanged() { changed(debounce: false) }
    @objc private func draftChanged() { changed(debounce: false) }
    public func controlTextDidChange(_ notification: Notification) { changed(debounce: true) }
    public func controlTextDidEndEditing(_ notification: Notification) { flushPendingChanges() }

    private func changed(debounce: Bool) {
        guard !restoringInputs, let id = profileID, var session = sessions[id] else { return }
        session.inputs = draftState; session.revision += 1; session.failure = nil
        sessions[id] = session
        updateNotice(); refreshFeedback(); onDraftChanged?()
        scheduleAutosave(debounce: debounce)
    }

    private func updateNotice() {
        var lines = ["Linked movement preserves existing differences, including hidden members. Linking does not equalize levels."]
        for (index, group) in groups.enumerated() where !group.isEmpty {
            guard snapshot.ready, snapshot.profileID == profileID,
                  group.allSatisfy({ id in snapshot.faders.contains { $0.id == id && $0.volumeDB.isFinite } }) else {
                lines.append("Group \(index + 1): current levels unavailable. Differences will be preserved.")
                continue
            }
            let members = group.compactMap { id in snapshot.faders.first { $0.id == id } }.sorted { $0.id < $1.id }
            guard let reference = members.first else { continue }
            let values = members.map { fader in
                let label = rows[fader.id]?.label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = label.isEmpty ? "Aux \(fader.id)" : label
                let delta = fader.volumeDB - reference.volumeDB
                let offset = fader.id == reference.id ? "reference" : String(format: "%+.1f dB vs Aux %d", delta, reference.id)
                return "\(name): \(String(format: "%.1f", fader.volumeDB)) dB (\(offset))"
            }
            lines.append("Group \(index + 1): " + values.joined(separator: "; "))
        }
        notice.stringValue = lines.joined(separator: "\n")
        notice.toolTip = notice.stringValue
        needsLayout = true
    }

    private func setError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = false
        errorLabel.toolTip = message
        needsLayout = true
    }

    private enum EditKey: Hashable {
        case visibility, groups, mutes, minimum, label(Int)
        static let all: [EditKey] = [.visibility, .groups, .mutes, .minimum] + (0..<4).map { .label($0) }
    }
    private struct DraftState: Equatable {
        var visible: [Int]
        var labels: [String]
        var groups: [Int]
        var mutes: Bool
        var minimum: String
        var remembered: [Int]
        mutating func copy(_ other: Self, key: EditKey) {
            switch key {
            case .visibility: visible = other.visible; remembered = other.remembered
            case .groups: groups = other.groups
            case .mutes: mutes = other.mutes
            case .minimum: minimum = other.minimum
            case .label(let index): labels[index] = other.labels[index]
            }
        }
        func matches(_ other: Self, key: EditKey) -> Bool {
            var copy = self; copy.copy(other, key: key); return copy == self
        }
    }
    private struct EditSession {
        var saved: AuxPreferences
        var baseline: DraftState
        var inputs: DraftState
        var revision = 0
        var attemptedRevision = -1
        var awaitingConfirmation: AuxPreferences?
        var failure: String?
    }
    private struct Candidate {
        var preferences: AuxPreferences
        var validKeys: [EditKey]
        var errors: [(String, NSView?)]
    }
    private var draftState: DraftState {
        DraftState(visible: visibleIDs, labels: (1...4).map { rows[$0]?.label.stringValue ?? "" },
            groups: (1...4).map { rows[$0]?.group.indexOfSelectedItem ?? 0 },
            mutes: linkMutes.state == .on, minimum: minimum.stringValue, remembered: rememberedVisibleIDs)
    }
    public var hasUnsavedChanges: Bool {
        guard let id = profileID, let session = sessions[id] else { return false }
        return draftState != session.baseline
    }
    public var isDirty: Bool { hasUnsavedChanges }
    public var canSave: Bool { onSave != nil && snapshot.profileID == selectedProfileID && profileID != nil && snapshot.preferencesEditable }
    public var availabilityMessage: String? { availabilityError }

    private func candidate(inputs: DraftState, saved: AuxPreferences) -> Candidate {
        var result = Candidate(preferences: saved, validKeys: [.visibility, .mutes], errors: [])
        result.preferences.visibleIDs = inputs.visible; result.preferences.lastVisibleIDs = inputs.remembered
        // Match the controller's visibility normalization so confirmation can
        // acknowledge the durable value rather than waiting on an impossible one.
        if !inputs.visible.isEmpty { result.preferences.lastVisibleIDs = inputs.visible }
        else if !saved.visibleIDs.isEmpty { result.preferences.lastVisibleIDs = saved.visibleIDs }
        else if inputs.remembered.isEmpty { result.preferences.lastVisibleIDs = saved.lastVisibleIDs }
        result.preferences.linkMutes = inputs.mutes
        if let floor = Double(inputs.minimum.trimmingCharacters(in: .whitespacesAndNewlines)), floor.isFinite, (-150...50).contains(floor) {
            result.preferences.sliderMinimumDB = floor; result.validKeys.append(.minimum)
        } else { result.errors.append(("Slider minimum must be a finite number from -150 to 50 dB.", minimum)) }
        for index in 0..<4 {
            let label = inputs.labels[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if label.count <= 80 {
                result.preferences.labels[String(index + 1)] = label.isEmpty ? nil : label
                result.validKeys.append(.label(index))
            } else { result.errors.append(("Aux \(index + 1) label must have at most 80 characters.", rows[index + 1]?.label)) }
        }
        let groups = (1...2).map { group in (1...4).filter { inputs.groups[$0 - 1] == group } }
        if let index = groups.firstIndex(where: { $0.count == 1 }) {
            result.errors.append(("Group \(index + 1) needs at least two Aux members, or select Unlinked.", rows[groups[index][0]]?.group))
        } else { result.preferences.linkGroups = groups.filter { !$0.isEmpty }; result.validKeys.append(.groups) }
        // All independently accepted groups preserve the validated saved values
        // for invalid fields. Canonicalize group order before persistence.
        if let validated = try? result.preferences.validated() { result.preferences = validated }
        return result
    }

    private func refreshFeedback() {
        guard let id = profileID, let session = sessions[id] else { setError(availabilityError); return }
        let candidate = candidate(inputs: session.inputs, saved: session.saved)
        invalidField = candidate.errors.first?.1
        let inactive = sessions.keys.sorted().filter { other in
            guard other != id, let pending = sessions[other] else { return false }
            return self.candidate(inputs: pending.inputs, saved: pending.saved).preferences != pending.saved
        }
        let pendingMessage = inactive.isEmpty ? nil : "Aux changes pending for " + inactive.joined(separator: ", ") + ". Select that profile to retry saving."
        setError(session.failure ?? availabilityError ?? candidate.errors.first?.0 ?? pendingMessage)
    }

    private func isEditing(_ key: EditKey) -> Bool {
        switch key {
        case .minimum: minimum.currentEditor() != nil
        case .label(let index): rows[index + 1]?.label.currentEditor() != nil
        default: false
        }
    }

    public func validateDraft() throws -> AuxPreferences { try draftPreferences() }
    public func validateSaveAuthority() throws {
        guard canSave else { throw SwitcherError.message(availabilityError ?? "Aux settings are unavailable for the selected profile.") }
    }
    public func focusInvalidField() {
        guard let invalidField else { return }
        window?.makeFirstResponder(invalidField); (invalidField as? NSTextField)?.selectText(nil)
    }

    private func scheduleAutosave(debounce: Bool) {
        debounceTask?.cancel(); debounceTask = nil
        guard saveTask == nil else { return }
        if debounce {
            debounceTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self else { return }
                self.debounceTask = nil; self.beginAutosave()
            }
        } else { beginAutosave() }
    }

    private func beginAutosave() {
        guard saveTask == nil, canSave, onSave != nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.saveTask = nil; self.inFlightProfileID = nil; self.refreshFeedback() }
            while self.canSave, let id = self.profileID, var session = self.sessions[id], let onSave = self.onSave {
                let submitted = session.inputs
                let candidate = self.candidate(inputs: submitted, saved: session.saved)
                if candidate.preferences == session.saved {
                    for key in candidate.validKeys { session.baseline.copy(submitted, key: key) }
                    self.sessions[id] = session; break
                }
                guard session.revision > session.attemptedRevision else { break }
                let revision = session.revision
                session.attemptedRevision = revision; self.sessions[id] = session
                self.inFlightProfileID = id
                do {
                    try self.validateSaveAuthority()
                    try await onSave(id, candidate.preferences)
                    guard var latest = self.sessions[id] else { break }
                    latest.saved = candidate.preferences
                    for key in candidate.validKeys { latest.baseline.copy(submitted, key: key) }
                    if latest.inputs.matches(submitted, key: .visibility) {
                        latest.inputs.remembered = candidate.preferences.lastVisibleIDs
                    }
                    latest.baseline.remembered = candidate.preferences.lastVisibleIDs
                    latest.awaitingConfirmation = self.snapshot.profileID == id && self.snapshot.preferences == candidate.preferences ? nil : candidate.preferences
                    latest.failure = nil; self.sessions[id] = latest
                    if self.profileID == id { self.restoreInputs(latest.inputs) }
                } catch {
                    if var latest = self.sessions[id] {
                        latest.failure = "Could not save Aux settings: " + error.localizedDescription
                        self.sessions[id] = latest
                    }
                }
                self.inFlightProfileID = nil
                self.refreshFeedback(); self.onDraftChanged?()
                // A newer edit may follow this save; recompute it from the new
                // saved baseline, retaining edits made during the await.
                guard self.selectedProfileID == id else { continue }
            }
        }
    }

    public func flushPendingChanges() {
        debounceTask?.cancel(); debounceTask = nil
        beginAutosave()
    }
    package func waitForPendingChanges() async {
        flushPendingChanges()
        while let task = saveTask { await task.value }
    }
    private func updateEnabled() {
        for row in rows.values { row.visible.isEnabled = canSave; row.label.isEnabled = canSave; row.group.isEnabled = canSave }
        minimum.isEnabled = canSave; linkMutes.isEnabled = canSave; visibilityButton.isEnabled = canSave
    }
}

/// Compatibility host for integrations that open Aux settings separately.
@MainActor public final class AuxFaderSettingsWindow: NSWindowController, NSWindowDelegate {
    public let content: AuxFaderSettingsContent
    public init(snapshot: AuxFaderSnapshot, onSave: @escaping (AuxPreferences) async throws -> Void) {
        content = AuxFaderSettingsContent(snapshot: snapshot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Aux Fader Settings"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let root = NSView(); window.contentView = root
        content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        let close = NSButton(title: "Close", target: self, action: #selector(closeSettings))
        close.bezelStyle = .rounded; close.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(close)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)])
        let boundProfileID = snapshot.profileID
        content.onSave = { id, preferences in
            guard id == boundProfileID else { throw SwitcherError.message("Aux settings are unavailable for this profile.") }
            try await onSave(preferences)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    public func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func updateSnapshot(_ snapshot: AuxFaderSnapshot) { content.updateSnapshot(snapshot) }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { window?.makeFirstResponder(nil); content.flushPendingChanges(); return true }
    public override func close() { window?.makeFirstResponder(nil); content.flushPendingChanges(); super.close() }
    @objc private func closeSettings() { close() }
}
