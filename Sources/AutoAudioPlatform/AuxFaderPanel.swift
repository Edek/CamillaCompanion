import AppKit
import AutoAudioCore

@MainActor package final class AuxFaderPanel: NSView {
    package var onPreciseVolume: ((Int, Double, String?) -> Void)?
    package var onVolume: ((Int, Double, String?, AuxVolumeIntent) -> Void)?
    package var onVolumeDragBegin: ((Int, String?, AuxVolumeIntent) -> Bool)?
    package var onVolumeDragUpdate: ((Int, Double, String?) -> Void)?
    package var onVolumeDragEnd: ((Int, Double, String?) -> Void)?
    package var onVolumeDragCancel: (() -> Void)?
    package var onMute: ((Int, Bool, String?, AuxVolumeIntent) -> Void)?
    package var onExpand: (() -> Void)?
    package var onLayout: (() -> Void)?
    private let mainOnly: Bool
    private var mainSliderMinimumDB = -50.0
    private var mainSliderMaximumDB = 6.0
    package func setMainSliderRange(minimumDB: Double, maximumDB: Double) {
        guard mainOnly, minimumDB.isFinite, maximumDB.isFinite,
              minimumDB >= -150, maximumDB <= 50, minimumDB < maximumDB,
              mainSliderMinimumDB != minimumDB || mainSliderMaximumDB != maximumDB else { return }
        cancelVolumeDrag()
        mainSliderMinimumDB = minimumDB; mainSliderMaximumDB = maximumDB
        render(snapshot)
    }
    private func faders(in value: AuxFaderSnapshot) -> [AuxFader] { mainOnly ? (value.main.map { [$0] } ?? []) : value.faders }
    private let stack = NSStackView()
    private let disclosure = NSButton(title: "Aux Levels", target: nil, action: nil)
    package var disclosureForVerification: NSButton { disclosure }
    private let body = NSStackView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var snapshot: AuxFaderSnapshot?
    private var rows: [Int: FaderRow] = [:]
    private var expanded = true
    package var isExpanded: Bool { expanded }
    private var identity = ""
    private var pendingVolumes: [Int: Double] = [:]
    private var pendingMutes: [Int: Bool] = [:]
    private struct DragPreview {
        var id: Int
        var intent: AuxVolumeIntent
        var profileID: String?
        var preferences: AuxPreferences
        var baseline: [Int: Double]
        var originDB: Double
        var lower: Double
        var upper: Double
        var ended = false
    }
    private var dragPreview: DragPreview?
    private var canCommit: Bool { snapshot?.ready == true && snapshot?.busy == false && pendingVolumes.isEmpty && pendingMutes.isEmpty && dragPreview == nil }
    private var pendingPreferences: AuxPreferences?
    private var pendingSawBusy = false
    // Native offscreen checks inspect numeric presentation without parsing labels.
    package var displayedNames: [Int: String] { rows.mapValues { $0.displayedName } }
    package var sliderPositions: [Int: Double] { rows.mapValues { $0.sliderPosition } }
    package var displayedVolumes: [Int: Double] { rows.mapValues { $0.displayedDB } }
    package var enabledControls: [Int: [Bool]] { rows.mapValues { $0.enabledControls } }
    package var displayedMuteStates: [Int: Int] { rows.mapValues { $0.displayedMuteState.rawValue } }
    package var muteButtonStyles: [Int: Bool] { rows.mapValues { $0.hasRoundedMuteStyle } }
    package var muteTextColors: [Int: NSColor] { rows.mapValues { $0.muteTextColor } }
    package var muteAccessibilityValues: [Int: String] { rows.mapValues { $0.muteAccessibilityValue } }
    @discardableResult package func submitPreciseValue(id: Int, text: String) -> Bool { rows[id]?.submitPreciseValue(text) ?? false }
    package func preciseField(id: Int) -> NSTextField? { rows[id]?.preciseField }
    package func restorePreciseValue(id: Int) { rows[id]?.restorePreciseValue() }
    package var preciseEntryErrors: [Int: String] { rows.mapValues { $0.entryError } }
    package func simulateVolumePointer(id: Int, type: NSEvent.EventType, db: Double, modifiers: NSEvent.ModifierFlags = []) {
        rows[id]?.simulatePointer(type: type, db: db, modifiers: modifiers)
    }
    package func simulateVolumeKey(id: Int, modifiers: NSEvent.ModifierFlags = []) { rows[id]?.simulateVolumeKey(modifiers: modifiers) }
    package func simulateMuteActivation(id: Int, modifiers: NSEvent.ModifierFlags = []) { rows[id]?.activateMute(modifiers: modifiers) }

    package init(frame: NSRect, mainOnly: Bool = false) {
        self.mainOnly = mainOnly
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        AudioControlStyle.configureDisclosure(disclosure)
        disclosure.target = self; disclosure.action = #selector(toggle)
        stack.addArrangedSubview(disclosure)
        disclosure.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        disclosure.isHidden = mainOnly
        updateDisclosure()
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 9
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        note.isHidden = true; body.isHidden = true
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func toggle() {
        expanded.toggle()
        updateDisclosure()
        updateBodyVisibility()
        if expanded { onExpand?() }
        onLayout?()
    }
    package func collapse() {
        guard expanded else { return }
        expanded = false; updateDisclosure(); updateBodyVisibility()
        onLayout?()
    }
    package func expand() {
        guard !expanded else { return }
        expanded = true; updateDisclosure(); updateBodyVisibility()
        onExpand?(); onLayout?()
    }
    private func updateDisclosure() {
        AudioControlStyle.refreshDisclosure(disclosure, expanded: expanded)
    }
    private func updateBodyVisibility() {
        body.isHidden = !expanded || (rows.isEmpty && note.isHidden)
    }
    package func refreshFocusAppearance() { updateDisclosure() }
    /// Lifecycle authority can decline a command before any busy snapshot is published.
    package func commandRejected() { clearPendingVolumes(); render(snapshot) }
    private func clearPendingVolumes() {
        if dragPreview != nil { rows.values.forEach { $0.stopTracking() } }
        pendingVolumes.removeAll()
        pendingMutes.removeAll()
        dragPreview = nil
        pendingPreferences = nil
        pendingSawBusy = false
    }
    @discardableResult package func beginVolumeDrag(id: Int, profileID: String?, intent: AuxVolumeIntent = .group) -> Bool {
        guard let current = snapshot, current.profileID == profileID, canCommit,
              let origin = faders(in: current).first(where: { $0.id == id }) else { return false }
        let scope: AuxVolumeIntent = mainOnly ? .group : intent
        let ids = mainOnly || scope == .individual ? [id] : (current.preferences.linkGroups.first { $0.contains(id) } ?? [id])
        let members = faders(in: current).filter { ids.contains($0.id) }
        guard Set(ids).isSubset(of: Set(members.map(\.id))) else { return false }
        let lower = members.map { -150 - $0.volumeDB }.max()!
        let upper = members.map { $0.maximumDB - $0.volumeDB }.min()!
        guard lower <= upper else { return false }
        let baseline = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.volumeDB) })
        dragPreview = DragPreview(id: id, intent: scope, profileID: profileID, preferences: current.preferences,
                                  baseline: baseline, originDB: origin.volumeDB, lower: lower, upper: upper)
        pendingVolumes = baseline; pendingPreferences = current.preferences; pendingSawBusy = false
        guard onVolumeDragBegin?(id, profileID, scope) == true else {
            clearPendingVolumes(); render(current); return false
        }
        return true
    }
    package func updateVolumeDrag(id: Int, db: Double, profileID: String?) {
        guard let drag = dragPreview, !drag.ended, drag.id == id, drag.profileID == profileID, db.isFinite else { return }
        let offset = min(drag.upper, max(drag.lower, db - drag.originDB))
        pendingVolumes = drag.baseline.mapValues { $0 + offset }
        render(snapshot)
        onVolumeDragUpdate?(id, drag.originDB + offset, profileID)
    }
    package func endVolumeDrag(id: Int, db: Double, profileID: String?) {
        guard let drag = dragPreview, drag.id == id, drag.profileID == profileID, !drag.ended else { return }
        updateVolumeDrag(id: id, db: db, profileID: profileID)
        dragPreview?.ended = true
        onVolumeDragEnd?(id, pendingVolumes[id] ?? drag.originDB, profileID)
    }
    package func cancelVolumeDrag() {
        guard dragPreview != nil else { return }
        clearPendingVolumes()
        onVolumeDragCancel?()
        render(snapshot)
    }
    package func commitVolume(id: Int, db: Double, profileID: String?, intent: AuxVolumeIntent = .group) {
        guard let current = snapshot, current.profileID == profileID, canCommit,
              let origin = faders(in: current).first(where: { $0.id == id }), db.isFinite else {
            render(snapshot)
            return
        }
        let scope: AuxVolumeIntent = mainOnly ? .group : intent
        let group = mainOnly || scope == .individual ? [id] : (current.preferences.linkGroups.first { $0.contains(id) } ?? [id])
        let members = faders(in: current).filter { group.contains($0.id) }
        guard Set(group).isSubset(of: Set(members.map(\.id))) else { return }
        let lower = members.map { -150 - $0.volumeDB }.max()!
        let upper = members.map { $0.maximumDB - $0.volumeDB }.min()!
        guard lower <= upper else { return }
        let offset = min(upper, max(lower, db - origin.volumeDB))
        pendingVolumes = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.volumeDB + offset) })
        pendingPreferences = current.preferences
        pendingSawBusy = false
        // Set local intent before enqueue publishes its busy, old-value snapshot.
        render(current)
        onVolume?(id, origin.volumeDB + offset, profileID, scope)
    }
    package func commitMute(id: Int, profileID: String?, intent: AuxVolumeIntent = .group) {
        guard let current = snapshot, current.profileID == profileID, canCommit else {
            render(snapshot)
            return
        }
        let scope: AuxVolumeIntent = mainOnly ? .group : intent
        let group = !mainOnly && scope == .group && current.preferences.linkMutes ? (current.preferences.linkGroups.first { $0.contains(id) } ?? [id]) : [id]
        let members = faders(in: current).filter { group.contains($0.id) }
        guard !members.isEmpty, Set(group).isSubset(of: Set(members.map(\.id))) else { return }
        let target = !members.allSatisfy(\.muted)
        pendingMutes = Dictionary(uniqueKeysWithValues: members.map { ($0.id, target) })
        pendingPreferences = current.preferences
        pendingSawBusy = false
        render(current)
        onMute?(id, target, profileID, scope)
    }
    // The menu's permanent Status row owns lifecycle and command feedback.
    // Standalone fader surfaces keep their existing inline feedback by default.
    package var presentsStatusFeedbackLocally = true
    @discardableResult package func render(_ value: AuxFaderSnapshot?) -> Bool {
        let wasHidden = isHidden
        let wasBodyHidden = body.isHidden
        let previousMessage = note.stringValue
        let previousIdentity = identity
        let previousProfile = snapshot?.profileID
        snapshot = value
        guard let value else {
            let hadDrag = dragPreview != nil
            clearPendingVolumes(); isHidden = true
            if hadDrag { onVolumeDragCancel?() }
            return !wasHidden
        }
        if previousProfile != value.profileID || !value.ready ||
            !Set(pendingVolumes.keys).union(pendingMutes.keys).isSubset(of: Set(faders(in: value).map(\.id))) ||
            (pendingPreferences != nil && pendingPreferences != value.preferences) {
            let hadDrag = dragPreview != nil
            clearPendingVolumes()
            if hadDrag { onVolumeDragCancel?() }
        } else if !pendingVolumes.isEmpty || !pendingMutes.isEmpty {
            if value.busy { pendingSawBusy = true }
            // Completion, including a partial failure, must show confirmed actual
            // values. A queued busy snapshot must retain the user's local intent.
            if pendingSawBusy && !value.busy { clearPendingVolumes() }
        }
        let hidden = mainOnly ? value.main == nil : (value.preferences.visibleIDs.isEmpty || (value.ready && value.faders.isEmpty))
        if isHidden != hidden { isHidden = hidden }
        let visible = faders(in: value).filter { mainOnly || value.preferences.visibleIDs.contains($0.id) }
        let key = "\(value.profileID ?? ""):\(visible.map { String($0.id) }.joined(separator: ","))"
        if identity != key {
            identity = key
            for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
            rows.removeAll()
            for fader in visible {
                let row = FaderRow(id: fader.id, profileID: value.profileID)
                row.onVolume = { [weak self] id, db, profile, intent in self?.commitVolume(id: id, db: db, profileID: profile, intent: intent) }
                row.onPreciseVolume = { [weak self] id, db, profile in self?.onPreciseVolume?(id, db, profile) }
                row.onMute = { [weak self] id, profile, intent in self?.commitMute(id: id, profileID: profile, intent: intent) }
                row.onValidationLayout = { [weak self] in self?.onLayout?() }
                row.canBeginInteraction = { [weak self] in self?.canCommit == true }
                row.onDragBegin = { [weak self] id, profile, intent in self?.beginVolumeDrag(id: id, profileID: profile, intent: intent) == true }
                row.onDragUpdate = { [weak self] id, db, profile in self?.updateVolumeDrag(id: id, db: db, profileID: profile) }
                row.onDragEnd = { [weak self] id, db, profile in self?.endVolumeDrag(id: id, db: db, profileID: profile) }
                row.onDragCancel = { [weak self] in self?.cancelVolumeDrag() }
                rows[fader.id] = row
                body.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
            body.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        var invalidRange = false
        var unavailableGroup = false
        for fader in visible {
            let group = mainOnly ? [fader.id] : (value.preferences.linkGroups.first { $0.contains(fader.id) } ?? [fader.id])
            let members = faders(in: value).filter { group.contains($0.id) }
            let muteMembers = value.preferences.linkMutes ? members : [fader]
            let muteValues = muteMembers.map { pendingMutes[$0.id] ?? $0.muted }
            let muteState: NSControl.StateValue = muteValues.allSatisfy { $0 } ? .on : (muteValues.contains(true) ? .mixed : .off)
            let minimum = fader.volumeDB + (members.map { -150 - $0.volumeDB }.max() ?? -150 - fader.volumeDB)
            let maximum = fader.volumeDB + (members.map { $0.maximumDB - $0.volumeDB }.min() ?? fader.maximumDB - fader.volumeDB)
            let complete = Set(group).isSubset(of: Set(faders(in: value).map(\.id)))
            invalidRange = invalidRange || minimum > maximum
            unavailableGroup = unavailableGroup || !complete
            let trimming = dragPreview?.intent == .individual && dragPreview?.id == fader.id
            rows[fader.id]?.alphaValue = value.ready ? 1 : 0.55
            rows[fader.id]?.render(fader, displayDB: pendingVolumes[fader.id] ?? fader.volumeDB, enabled: value.ready && complete, numericEnabled: value.ready, muteEnabled: value.ready && (!value.preferences.linkMutes || complete), muteState: muteState, channelMuted: pendingMutes[fader.id] ?? fader.muted, group: group, groupNumber: value.preferences.linkGroups.firstIndex(where: { $0.contains(fader.id) }).map { $0 + 1 }, linkMutes: value.preferences.linkMutes, preview: dragPreview != nil, trimming: trimming, blockedReason: !value.ready ? "DSP is stopped or disconnected." : (!complete ? "A linked Aux member is unavailable." : (minimum > maximum ? "Linked limits leave no valid shared level." : nil)), minimum: trimming ? -150 : minimum, maximum: trimming ? fader.maximumDB : maximum, sliderMinimum: mainOnly ? mainSliderMinimumDB : value.preferences.sliderMinimumDB, sliderMaximum: mainOnly ? min(mainSliderMaximumDB, fader.maximumDB) : fader.maximumDB)
        }
        let message: String
        if !presentsStatusFeedbackLocally {
            // Structural fader warnings do not disappear when a separate status
            // failure arrives. Readiness and command detail belong to the header.
            if unavailableGroup { message = "A linked Aux member is unavailable. Unlink the group in Aux Faders to adjust available members." }
            else if invalidRange { message = "Linked levels cannot move within the allowed limits. Adjust levels in the Web Interface or unlink the group." }
            else if visible.isEmpty && value.ready { message = "No configured Aux controls are available in this DSP configuration." }
            else { message = "" }
        }
        else {
            message = value.error ?? (!value.ready ? "Levels unavailable while DSP is stopped or disconnected. Open Levels to refresh when DSP is ready." : (visible.isEmpty ? "No configured Aux controls are available in this DSP configuration." : (unavailableGroup ? "A linked Aux member is unavailable. Unlink the group in Aux Faders to adjust available members." : (invalidRange ? "Linked levels cannot move within the allowed limits. Adjust levels in the Web Interface or unlink the group." : ""))))
        }
        if note.stringValue != message { note.stringValue = message }
        let noteColor: NSColor = value.error == nil ? .secondaryLabelColor : .systemRed
        if note.textColor != noteColor { note.textColor = noteColor }
        // Keep layout stable while a finite command is in progress.
        // Do not insert an updating message that changes the popup's height.
        if note.isHidden != message.isEmpty { note.isHidden = message.isEmpty }
        updateBodyVisibility()
        return wasHidden != isHidden || (expanded && (previousIdentity != identity || previousMessage != message || wasBodyHidden != body.isHidden))
    }
}

@MainActor private final class FaderRow: NSStackView, NSTextFieldDelegate {
    let id: Int
    let profileID: String?
    var onPreciseVolume: ((Int, Double, String?) -> Void)?
    var onVolume: ((Int, Double, String?, AuxVolumeIntent) -> Void)?
    var onMute: ((Int, String?, AuxVolumeIntent) -> Void)?
    var onDragBegin: ((Int, String?, AuxVolumeIntent) -> Bool)?
    var onDragUpdate: ((Int, Double, String?) -> Void)?
    var onDragEnd: ((Int, Double, String?) -> Void)?
    var onValidationLayout: (() -> Void)?
    var onDragCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let value = PreciseAuxTextField(labelWithString: "")
    private let slider = CommitSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var scale = AuxFaderScale()
    private var gestureMinimum = -150.0
    private var gestureMaximum = 0.0
    var displayedName: String { label.stringValue }
    var sliderPosition: Double { slider.doubleValue }
    var preciseField: NSTextField { value }
    private(set) var displayedDB = 0.0
    private var accessibilityName = ""
    var muteTextColor: NSColor { mute.foregroundColor }
    var muteAccessibilityValue: String { mute.accessibilityValue() as? String ?? "" }
    private var accessibilityMuteDescription = ""
    private var editingValue = false
    private let entryNote = NSTextField(wrappingLabelWithString: "")
    var entryError: String { entryNote.stringValue }
    var canBeginInteraction: (() -> Bool)? {
        didSet { slider.canBeginInteraction = canBeginInteraction }
    }
    var enabledControls: [Bool] { [slider.isEnabled, mute.isEnabled, reset.isEnabled] }
    var displayedMuteState: NSControl.StateValue { mute.state }
    var hasRoundedMuteStyle: Bool { mute.bezelStyle == reset.bezelStyle && mute.controlSize == reset.controlSize }
    private let mute = AudioMuteButton(title: "Mute", target: nil, action: nil)
    private let reset = AudioRoundedButton(title: "0 dB", target: nil, action: nil)
    init(id: Int, profileID: String?) {
        self.id = id; self.profileID = profileID
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 3
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 65).isActive = true
        value.isEditable = true; value.isSelectable = true; value.delegate = self
        value.setAccessibilityLabel(id == 0 ? "Enter Main volume in decibels" : "Enter a precise Aux level in decibels")
        value.toolTip = "Click to enter an exact dB level. Return applies; Escape restores."
        AudioControlStyle.configureRounded(mute)
        mute.widthAnchor.constraint(equalToConstant: 54).isActive = true
        mute.heightAnchor.constraint(equalToConstant: 24).isActive = true
        reset.widthAnchor.constraint(equalToConstant: 54).isActive = true
        reset.heightAnchor.constraint(equalToConstant: 24).isActive = true
        mute.setButtonType(.pushOnPushOff); mute.allowsMixedState = true
        mute.target = self; mute.action = #selector(mutePressed)
        AudioControlStyle.configureRounded(reset)
        reset.target = self; reset.action = #selector(resetPressed)
        let header = NSStackView(views: [label, NSView(), value, mute, reset])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 7
        addArrangedSubview(header); header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        slider.installAppearanceCell()
        slider.isContinuous = true
        slider.allowsIndividualIntent = id != 0
        slider.onBegin = { [weak self] grabbedKnob, intent in
            guard let self else { return false }
            if grabbedKnob && (self.displayedDB < self.scale.minimumDB || self.displayedDB > self.scale.maximumDB) {
                // Include the actual value for this gesture only. A pinned knob
                // can then move continuously without jumping to the travel edge.
                self.scale = AuxFaderScale(minimumDB: min(self.gestureMinimum, self.displayedDB),
                                          maximumDB: max(self.gestureMaximum, self.displayedDB),
                                          midpointDB: self.id == 0 ? -10 : nil)
                self.slider.doubleValue = self.scale.position(for: self.displayedDB)
            }
            return self.onDragBegin?(self.id, self.profileID, intent) == true
        }
        slider.onCommit = { [weak self] in
            guard let self else { return }
            self.onDragEnd?(self.id, self.scale.decibels(at: self.slider.doubleValue), self.profileID)
        }
        slider.onCancel = { [weak self] in self?.onDragCancel?() }
        slider.target = self; slider.action = #selector(sliderChanged)
        addArrangedSubview(slider); slider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        entryNote.font = .systemFont(ofSize: 11); entryNote.textColor = .systemRed
        entryNote.isHidden = true
        addArrangedSubview(entryNote); entryNote.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func render(_ fader: AuxFader, displayDB: Double, enabled: Bool, numericEnabled: Bool, muteEnabled: Bool, muteState: NSControl.StateValue, channelMuted: Bool, group: [Int], groupNumber: Int?, linkMutes: Bool, preview: Bool, trimming: Bool, blockedReason: String?, minimum: Double, maximum: Double, sliderMinimum: Double, sliderMaximum: Double) {
        let name = fader.name + (group.count > 1 ? " · Group \(groupNumber ?? 1)" : "") + (displayDB < sliderMinimum ? " · Below slider range" : (displayDB > sliderMaximum ? " · Above slider range" : ""))
        if label.stringValue != name { label.stringValue = name }
        if !slider.tracking || preview {
            displayedDB = displayDB
            let text = String(format: "%.1f dB", displayDB)
            if !editingValue && value.stringValue != text {
                value.stringValue = text
                slider.setAccessibilityValue(text)
            }
        }
        // Individual presentation endpoints never follow linked offsets. The
        // shared movement limits only constrain commands and slider eligibility.
        gestureMinimum = sliderMinimum; gestureMaximum = sliderMaximum
        let rangeValid = sliderMinimum < sliderMaximum && max(minimum, sliderMinimum) < min(maximum, sliderMaximum)
        if !slider.tracking {
            if scale.minimumDB != min(sliderMinimum, sliderMaximum) || scale.maximumDB != sliderMaximum {
                scale = AuxFaderScale(minimumDB: min(sliderMinimum, sliderMaximum), maximumDB: sliderMaximum,
                                      midpointDB: id == 0 ? -10 : nil)
            }
            let position = scale.position(for: displayDB)
            if abs(slider.doubleValue - position) > 1e-12 { slider.doubleValue = position }
        } else if preview {
            // The pointer can enter an unreachable portion of an individual
            // scale. Keep the knob on the same clamped value as the number.
            slider.doubleValue = scale.position(for: displayDB)
        }
        value.isEnabled = numericEnabled
        let sliderEnabled = enabled && rangeValid
        if slider.isEnabled != sliderEnabled { slider.isEnabled = sliderEnabled }
        if mute.isEnabled != muteEnabled { mute.isEnabled = muteEnabled }
        let resetEnabled = enabled && minimum <= 0 && maximum >= 0
        if reset.isEnabled != resetEnabled { reset.isEnabled = resetEnabled }
        AudioControlStyle.setMuteState(mute, state: muteState)
        mute.channelMuted = channelMuted
        let muteDescription = muteState == .mixed ? (channelMuted ? "Muted; linked group has mixed mute states" : "Unmuted; linked group has mixed mute states") : (muteState == .on ? "Muted" : "Unmuted")
        if accessibilityMuteDescription != muteDescription {
            accessibilityMuteDescription = muteDescription
            mute.setAccessibilityValue(muteDescription)
        }
        let linked = id == 0 ? "Main volume affects every DSP output; Aux trims stay unchanged." : group.count > 1 ? "Linked Aux \(group.map(String.init).joined(separator: ", ")). Changes include hidden members." : "Aux \(id)"
        if label.toolTip != linked { label.toolTip = linked }
        let context = blockedReason.map { "Unavailable: " + $0 + " " } ?? (fader.muted ? "Muted: level changes are saved; unmute to hear them. " : "")
        let outsideRange = displayDB < sliderMinimum ? "Current level is below the slider range. " : (displayDB > sliderMaximum ? "Current level is above the slider range. " : "")
        let emptyRange = !rangeValid ? "Slider travel has no usable interval within the allowed limits. Exact dB entry remains available. " : ""
        let rangeTip = (trimming ? "Trim only this Aux. " : "") + context + outsideRange + emptyRange + linked + " Slider travel: \(String(format: "%.1f", sliderMinimum)) to \(String(format: "%.1f", sliderMaximum)) dB. " + (group.count > 1 ? "Linked movement clamps at shared bounds. Hold Shift to adjust only this Aux. " : "") + " Allowed movement range: \(String(format: "%.1f", minimum)) to \(String(format: "%.1f", maximum)) dB."
        if slider.toolTip != rangeTip { slider.toolTip = rangeTip }
        slider.setAccessibilityHelp(rangeTip)
        if accessibilityName != fader.name {
            accessibilityName = fader.name
            slider.setAccessibilityLabel("\(fader.name) level in decibels")
            mute.setAccessibilityLabel("\(fader.name) mute")
        }
        let muteTip = linkMutes && group.count > 1 ? (muteState == .mixed ? (channelMuted ? "This Aux is muted. " : "This Aux is unmuted. ") + "Linked members have mixed mute states. Select to mute all members." : linked) + " Shift-click toggles only this Aux." : (id == 0 ? "Mute all DSP output channels." : "Mute only Aux \(id). Level links remain unchanged.")
        if mute.toolTip != muteTip { mute.toolTip = muteTip }
        let resetTip = "Set \(fader.name) to 0 dB, preserving linked level differences."
        if reset.toolTip != resetTip { reset.toolTip = resetTip }
    }
    func stopTracking() { slider.finishTracking() }
    func simulatePointer(type: NSEvent.EventType, db: Double, modifiers: NSEvent.ModifierFlags = []) {
        guard let cell = slider.cell as? NSSliderCell else { return }
        let knob = cell.knobRect(flipped: slider.isFlipped)
        let track = cell.trackRect
        let left = track.minX + knob.width / 2
        let right = track.maxX - knob.width / 2
        let point = NSPoint(x: left + CGFloat(scale.position(for: db)) * (right - left), y: slider.bounds.midY)
        let location = slider.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: slider.mouseDown(with: event)
        case .leftMouseDragged: slider.mouseDragged(with: event)
        case .leftMouseUp: slider.mouseUp(with: event)
        default: break
        }
    }
    func simulateVolumeKey(modifiers: NSEvent.ModifierFlags = []) {
        guard window?.makeFirstResponder(slider) == true else {
            print("Aux arrow fixture could not focus slider \(id)"); return
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers.union([.function, .numericPad]),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) else { return }
        slider.keyDown(with: event)
    }
    func activateMute(modifiers: NSEvent.ModifierFlags) {
        guard mute.isEnabled else { return }
        let intent: AuxVolumeIntent = id != 0 && modifiers.contains(.shift) ? .individual : .group
        onMute?(id, profileID, intent)
    }
    private func setEntryError(_ text: String) {
        let geometryChanged = entryNote.isHidden != text.isEmpty
        if entryNote.stringValue != text { entryNote.stringValue = text }
        entryNote.isHidden = text.isEmpty
        if geometryChanged { onValidationLayout?() }
    }
    @discardableResult package func submitPreciseValue(_ text: String) -> Bool {
        guard canBeginInteraction?() == true, value.isEnabled else {
            setEntryError("Wait for the current command or refresh unavailable Aux values.")
            return false
        }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " dB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(raw), parsed.isFinite else {
            setEntryError("Enter a finite dB value. NaN, infinity and overflow are unavailable.")
            return false
        }
        let db = max(-150, parsed)
        // Linked candidates have different bounds. The shared core evaluates
        // them after a fresh read and the caller presents their exact results.
        guard abs(db - displayedDB) > 0.000001 else { restorePreciseValue(); return true }
        finishPreciseEditing()
        setEntryError("")
        onPreciseVolume?(id, parsed, profileID)
        return true
    }
    private func finishPreciseEditing() {
        editingValue = false
        // Detach the native editor before replacing presentation text. Mutating
        // the editor's storage during insertText corrupts its undo ranges.
        if value.currentEditor() != nil { window?.makeFirstResponder(nil) }
        value.stringValue = String(format: "%.1f dB", displayedDB)
    }
    func restorePreciseValue(clearError: Bool = true) {
        finishPreciseEditing()
        if clearError { setEntryError("") }
    }
    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        canBeginInteraction?() == true && value.isEnabled
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        // AppKit sends this while the first insertText transaction is in flight.
        // Leave the native editor's content and undo transaction intact.
        editingValue = true
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard editingValue else { return }
        if !submitPreciseValue(value.stringValue) {
            restorePreciseValue(clearError: false)
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSText.selectAll(_:)) { textView.selectAll(nil); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            restorePreciseValue(); window?.makeFirstResponder(nil); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if submitPreciseValue(textView.string) { window?.makeFirstResponder(nil) }
            return true
        }
        return false
    }
    @objc private func sliderChanged() {
        let db = scale.decibels(at: slider.doubleValue)
        displayedDB = db
        value.stringValue = String(format: "%.1f dB", db)
        slider.setAccessibilityValue(String(format: "%.1f dB", db))
        if slider.tracking { onDragUpdate?(id, db, profileID) }
        else { onVolume?(id, db, profileID, slider.activationIntent) }
    }
    @objc private func resetPressed() { onVolume?(id, 0, profileID, .group) }
    @objc private func mutePressed() { activateMute(modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
}

/// Native slider drawing and keyboard handling with event-by-event mouse
/// tracking. Returning after every event lets MainActor DSP tasks run before
/// release; NSSlider's nested mouseDown tracking loop would not guarantee that.
@MainActor package final class CommitSlider: NSSlider {
    package func installAppearanceCell() {
        guard let old = cell as? NSSliderCell, !(old is ActiveColorsSliderCell) else { return }
        let replacement = ActiveColorsSliderCell()
        replacement.minValue = old.minValue; replacement.maxValue = old.maxValue
        replacement.doubleValue = old.doubleValue
        replacement.controlSize = old.controlSize
        replacement.sliderType = old.sliderType
        replacement.isVertical = old.isVertical
        cell = replacement
    }
    var tracking = false
    var allowsIndividualIntent = true
    private(set) var activationIntent: AuxVolumeIntent = .group
    var onBegin: ((Bool, AuxVolumeIntent) -> Bool)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var canBeginInteraction: (() -> Bool)?
    private var startX: CGFloat = 0
    private var endX: CGFloat = 1
    private var grabOffset: CGFloat = 0
    private var changed = false
    package override func mouseDown(with event: NSEvent) {
        guard isEnabled, canBeginInteraction?() != false,
              let sliderCell = cell as? NSSliderCell else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let knob = sliderCell.knobRect(flipped: isFlipped)
        let bar = sliderCell.barRect(flipped: isFlipped)
        // knobRect caches its drawn POSITION; changing doubleValue does not
        // recompute it. Use only its size and the native bar's full width.
        startX = bar.minX + knob.width / 2
        endX = bar.maxX - knob.width / 2
        let original = sliderCell.doubleValue
        let unit = maxValue > minValue ? (original - minValue) / (maxValue - minValue) : 0
        let continuousCenter = startX + CGFloat(unit) * (endX - startX)
        let currentKnob = NSRect(x: continuousCenter - knob.width / 2, y: knob.minY,
                                 width: knob.width, height: knob.height)
        let grabbedKnob = currentKnob.contains(point)
        tracking = true; changed = false
        activationIntent = allowsIndividualIntent && event.modifierFlags.contains(.shift) ? .individual : .group
        guard canBeginInteraction?() != false, onBegin?(grabbedKnob, activationIntent) == true else { finishTracking(); return }
        // Preserve the initial continuous gain, including an off-center grab.
        grabOffset = grabbedKnob ? point.x - continuousCenter : 0
        tracking = true
        if !grabbedKnob { updatePointer(with: event) }
    }
    package override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        updatePointer(with: event)
    }
    package override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        updatePointer(with: event)
        tracking = false
        if changed { onCommit?() } else { onCancel?() }
        activationIntent = .group
    }
    package override func keyDown(with event: NSEvent) {
        guard !tracking, isEnabled, canBeginInteraction?() != false else { return }
        activationIntent = allowsIndividualIntent && event.modifierFlags.contains(.shift) ? .individual : .group
        defer { activationIntent = .group }
        guard [UInt16(123), 124, 125, 126].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        // Interpret ordinary arrows through AppKit's native movement commands,
        // which determine the increment and dispatch our target action. Shift
        // selects Aux write scope rather than the text-selection key binding.
        if activationIntent == .individual,
           let nativeArrow = NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
                modifierFlags: event.modifierFlags.subtracting(.shift), timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, characters: event.characters ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) {
            interpretKeyEvents([nativeArrow])
            return
        }
        interpretKeyEvents([event])
    }
    func finishTracking() { tracking = false; activationIntent = .group }
    package override func cancelOperation(_ sender: Any?) {
        guard tracking else { super.cancelOperation(sender); return }
        finishTracking()
        onCancel?()
    }
    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil && tracking {
            finishTracking()
            onCancel?()
        }
    }
    private func updatePointer(with event: NSEvent) {
        guard endX > startX else { return }
        let point = convert(event.locationInWindow, from: nil)
        let unit = min(1, max(0, Double((point.x - grabOffset - startX) / (endX - startX))))
        let desired = minValue + unit * (maxValue - minValue)
        if abs(doubleValue - desired) > 1e-12 {
            changed = true
            doubleValue = desired
            sendAction(action, to: target)
        }
    }
}

/// Native knob and tracking remain authoritative. Only the inactive filled bar
/// changes when the user explicitly preserves active control colors.
@MainActor package final class ActiveColorsSliderCell: NSSliderCell {
    package var preservesTrackColor: Bool {
        AudioControlStyle.keepActiveColors && !AudioControlStyle.windowIsActive(controlView?.window)
            && isEnabled && !isVertical && sliderType == .linear
    }
    package func preservedFillRect(in rect: NSRect, flipped: Bool) -> NSRect {
        let knobWidth = knobRect(flipped: flipped).width
        let travel = max(0, rect.width - knobWidth)
        let unit = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        let center = rect.minX + knobWidth / 2 + CGFloat(unit) * travel
        return NSRect(x: rect.minX, y: rect.minY, width: max(0, center - rect.minX), height: rect.height)
    }
    package override func drawBar(inside rect: NSRect, flipped: Bool) {
        super.drawBar(inside: rect, flipped: flipped)
        guard preservesTrackColor else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).addClip()
        NSColor.controlAccentColor.setFill()
        preservedFillRect(in: rect, flipped: flipped).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Accessory popovers may have no application Edit menu. Handle the shortcut
/// locally using AppKit's current field editor, preserving ordinary selection.
@MainActor private final class PreciseAuxTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a",
           let editor = currentEditor() {
            editor.selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
