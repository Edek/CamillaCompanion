import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor extension AudioControlPanel {
    fileprivate func verifyFallbackControls() -> Bool {
        let first = AudioDevice(uid: "first", name: "Same output name", hasOutput: true)
        let second = AudioDevice(uid: "second", name: "Same output name", hasOutput: true)
        let devices = [first, second]
        var automatic = FallbackOutputPreference(mode: .automatic, outputUID: first.uid, outputName: first.name)
        automatic.outputSelection = .device
        var force = automatic; force.mode = .manual
        var off = automatic; off.mode = .off
        renderFallback(profileID: "fixture", preference: automatic, devices: devices, enabled: true, automaticOutput: second)
        let size = measureNaturalSize(), pickerFrame = fallbackPicker.frame
        let pickerRect = convert(fallbackPicker.bounds, from: fallbackPicker)
        let trackRect = convert(routingControl.bounds.insetBy(dx: 0.5, dy: 0.5), from: routingControl)
        guard abs(pickerRect.width - trackRect.width) < 0.5,
              abs(pickerRect.maxX - trackRect.maxX) < 0.5,
              fallbackControl.segmentCount == 3,
              (0..<3).allSatisfy({ fallbackControl.label(forSegment: $0) == ["Auto", "Force", "Off"][$0] }),
              fallbackControl.isEnabled, fallbackControl.selectedSegment == 0, !fallbackPicker.isEnabled,
              fallbackPicker.itemTitles == devices.map(\.name),
              fallbackPicker.selectedItem?.representedObject as? String == second.uid else {
            print("Fallback automatic device/track failed"); return false
        }
        var modeCalls: [FallbackOutputMode] = [], outputCalls: [AudioDevice] = []
        var modeProfiles: [String] = [], outputProfiles: [String] = []
        onFallbackMode = { modeProfiles.append($0); modeCalls.append($1) }
        onFallbackOutput = { outputProfiles.append($0); outputCalls.append($1) }
        fallbackOutputChanged()
        guard outputCalls.isEmpty, modeCalls.isEmpty else { return false }
        // Even a synthetic action with the native enabled bit changed cannot edit Auto.
        fallbackPicker.isEnabled = true; fallbackPicker.selectItem(at: 0); fallbackOutputChanged()
        guard outputCalls.isEmpty else { return false }
        fallbackPicker.isEnabled = false
        fallbackControl.selectedSegment = 1; fallbackModeChanged()
        guard modeCalls == [.manual], fallbackControl.selectedSegment == 0 else { return false }
        renderFallback(profileID: "fixture", preference: force, devices: devices, enabled: true, automaticOutput: second)
        guard fallbackPicker.isEnabled, fallbackControl.selectedSegment == 1,
              fallbackControl.selectedSegmentBezelColor == .systemOrange,
              fallbackPicker.selectedItem?.representedObject as? String == first.uid,
              measureNaturalSize() == size, fallbackPicker.frame == pickerFrame else { return false }
        fallbackOutputChanged()
        guard outputCalls.isEmpty else { return false }
        // Simulate persistence rejection: choosing another device restores the saved UID.
        fallbackPicker.selectItem(at: 1); fallbackOutputChanged()
        guard outputCalls == [second], fallbackPicker.selectedItem?.representedObject as? String == first.uid else { return false }
        fallbackControl.selectedSegment = 2; fallbackModeChanged()
        guard modeCalls == [.manual, .off], fallbackControl.selectedSegment == 1 else { return false }
        renderFallback(profileID: "fixture", preference: off, devices: devices, enabled: true, automaticOutput: second)
        guard fallbackPicker.isEnabled, fallbackControl.selectedSegment == 2,
              fallbackControl.selectedSegmentBezelColor == AudioMuteButton.activeFill,
              fallbackPicker.selectedItem?.representedObject as? String == first.uid,
              measureNaturalSize() == size, fallbackPicker.frame == pickerFrame else { return false }
        // Auto shows its live suggestion; returning to Force/Off restores the explicit UID.
        renderFallback(profileID: "fixture", preference: automatic, devices: devices, enabled: true, automaticOutput: second)
        guard !fallbackPicker.isEnabled, fallbackPicker.selectedItem?.representedObject as? String == second.uid else { return false }
        renderFallback(profileID: "fixture", preference: off, devices: devices, enabled: true, automaticOutput: second)
        guard fallbackPicker.isEnabled, fallbackPicker.selectedItem?.representedObject as? String == first.uid else { return false }
        var suggestedOff = off; suggestedOff.outputSelection = .automatic
        renderFallback(profileID: "fixture", preference: suggestedOff, devices: devices, enabled: true, automaticOutput: second)
        fallbackOutputChanged()
        guard outputCalls == [second, second], fallbackPicker.selectedItem?.representedObject as? String == second.uid else { return false }
        var missing = off; missing.outputUID = "missing"; missing.outputName = String(repeating: "Long missing output ", count: 8)
        renderFallback(profileID: "fixture", preference: missing, devices: devices, enabled: true)
        guard fallbackPicker.selectedItem?.representedObject as? String == "missing",
              fallbackPicker.selectedItem?.isEnabled == false, fallbackPicker.isEnabled,
              measureNaturalSize() == size, fallbackPicker.frame == pickerFrame,
              fallbackPicker.itemArray.count == 3 else { print("Long fallback name changed track"); return false }
        fallbackOutputChanged()
        guard outputCalls == [second, second] else { return false }
        guard let menu = fallbackPicker.menu else { return false }
        menuWillOpen(menu)
        var pendingAuto = missing; pendingAuto.mode = .automatic
        renderFallback(profileID: "fixture", preference: pendingAuto, devices: devices, enabled: true, automaticOutput: second)
        fallbackPicker.selectItem(at: 0); fallbackOutputChanged()
        guard outputCalls == [second, second] else { print("Tracked picker edited pending Auto"); return false }
        pendingFallbackState = nil; menuDidClose(menu)
        renderFallback(profileID: "fixture", preference: force, devices: devices, enabled: true, automaticOutput: second)
        menuWillOpen(menu)
        renderFallback(profileID: "new-profile", preference: off, devices: [second], enabled: true, automaticOutput: second)
        fallbackPicker.selectItem(at: 1); fallbackOutputChanged()
        fallbackControl.selectedSegment = 0; fallbackModeChanged()
        guard modeProfiles == ["fixture", "fixture", "fixture"],
              outputProfiles == ["fixture", "fixture", "fixture"] else { return false }
        pendingFallbackState = nil; menuDidClose(menu)
        // Mode preference stays editable offline, while an empty device picker cannot act.
        renderFallback(profileID: "fixture", preference: automatic, devices: [], enabled: true)
        guard fallbackControl.isEnabled, !fallbackPicker.isEnabled,
              fallbackPicker.itemTitles == ["No Outputs Available"],
              fallbackPicker.selectedItem?.isEnabled == false else { return false }
        renderFallback(profileID: nil, preference: off, devices: devices, enabled: false)
        guard !fallbackControl.isEnabled, !fallbackPicker.isEnabled else { return false }
        fallbackControl.selectedSegment = 0; fallbackModeChanged(); fallbackOutputChanged()
        guard modeCalls == [.manual, .off, .automatic], outputCalls == [second, second, second] else { return false }
        return verifyControlsDisclosure()
    }

    private func verifyControlsDisclosure() -> Bool {
        let expandedSize = measureNaturalSize()
        let independentSections: [NSView] = [mainPanel, metersPanel, auxPanel]
        let independentVisibility = independentSections.map(\.isHidden)
        let independentFrames = independentSections.map { convert($0.bounds, from: $0) }
        guard verifySectionOrder() else { return false }
        var layouts = 0, policies = 0
        onLayout = { layouts += 1 }
        onDSPMode = { _ in policies += 1 }; onGUIMode = { _ in policies += 1 }
        onRouting = { _ in policies += 1 }; onFallbackMode = { _, _ in policies += 1 }
        onOpen = { policies += 1 }; onRestart = { policies += 1 }
        defer { onLayout = nil }
        guard controlsExpanded, !controlsBody.isHidden,
              controlsDisclosure.font == NSFont.systemFont(ofSize: 12, weight: .medium),
              controlsDisclosure.accessibilityValue() as? String == "Expanded" else { print("Fallback/disclosure fixture failed at guard 14, picker \(fallbackPicker.frame), routing \(routingControl.frame), expanded \(controlsExpanded)"); return false }
        let menu = fallbackPicker.menu!
        let nestedMenu = NSMenu()
        var trackingEvents: [Bool] = []
        onChildMenuTracking = { trackingEvents.append($0) }
        defer { onChildMenuTracking = nil }
        menuWillOpen(menu); menuWillOpen(nestedMenu)
        setControlsExpanded(false)
        guard controlsExpanded, !controlsBody.isHidden, layouts == 0 else { print("Fallback/disclosure fixture failed at guard 15, picker \(fallbackPicker.frame), routing \(routingControl.frame), expanded \(controlsExpanded)"); return false }
        menuDidClose(menu)
        guard controlsExpanded, !controlsBody.isHidden, layouts == 0,
              pendingControlsExpansion == false, trackingEvents == [true, true, false] else { print("Fallback/disclosure fixture failed at guard 16, picker \(fallbackPicker.frame), routing \(routingControl.frame), expanded \(controlsExpanded)"); return false }
        // The last close may dispatch collapse only after native tracking returns.
        // Consume that same pending transition synchronously in this fixture.
        let deferredExpansion = pendingControlsExpansion
        pendingControlsExpansion = nil; menuDidClose(nestedMenu)
        guard trackedMenus.isEmpty, deferredExpansion == false,
              trackingEvents == [true, true, false, false] else { print("Fallback/disclosure fixture failed at guard 17, picker \(fallbackPicker.frame), routing \(routingControl.frame), expanded \(controlsExpanded)"); return false }
        let focusWindow = OwnedRasterWindow(contentRect: NSRect(origin: .zero, size: expandedSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        focusWindow.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(origin: .zero, size: expandedSize))
        focusWindow.contentView = host
        host.addSubview(self)
        defer { removeFromSuperview(); focusWindow.close() }
        focusWindow.makeFirstResponder(dspControl)
        setControlsExpanded(deferredExpansion ?? true)
        let collapsedSize = measureNaturalSize()
        guard !controlsExpanded, controlsBody.isHidden, layouts == 1,
              collapsedSize.width == expandedSize.width, collapsedSize.height < expandedSize.height,
              controlsDisclosure.accessibilityValue() as? String == "Collapsed",
              focusWindow.firstResponder === controlsDisclosure,
              !header.isHidden, !statusUpdateLabel.isHidden,
              independentSections.map(\.isHidden) == independentVisibility,
              independentSections.map({ convert($0.bounds, from: $0) }) == independentFrames,
              verifySectionOrder() else { print("Fallback/disclosure fixture failed at guard 18, picker \(fallbackPicker.frame), routing \(routingControl.frame), expanded \(controlsExpanded)"); return false }
        // A normal status/focus refresh does not expand the section or call policy.
        refreshSelectionAppearance(); setControlsExpanded(false)
        guard !controlsExpanded, layouts == 1, policies == 0 else { print("Fallback/disclosure fixture failed at guard 19, picker \(fallbackPicker.frame), routing \(routingControl.frame), expanded \(controlsExpanded)"); return false }
        setControlsExpanded(true)
        return measureNaturalSize() == expandedSize && layouts == 2 && policies == 0
    }

    private func verifySectionOrder() -> Bool {
        guard let statusGroup = dspOutputLabel.superview,
              let footer = moreButton.superview else { return false }
        let expected: [NSView] = [header, statusGroup, mainPanel, metersPanel, auxPanel,
                                  controlsDisclosure, controlsBody, footer]
        let members = stack.arrangedSubviews
        let indexes = expected.compactMap { expectedView in members.firstIndex { $0 === expectedView } }
        return indexes.count == expected.count && zip(indexes, indexes.dropFirst()).allSatisfy { $0 < $1 }
    }

    fileprivate func verifyRoutineLayout(_ models: [MenuBarPresentation]) -> Bool {
        guard let first = models.first else { return false }
        render(first, error: nil)
        guard verifySectionOrder() else { return false }
        let height = measureNaturalSize().height
        for model in models {
            render(model, error: nil)
            guard measureNaturalSize().height == height,
                  statusUpdateLabel.stringValue == "Status: " + model.panelStatus().text,
                  statusLabel.stringValue == model.dspStatusText,
                  routingStatusLabel.stringValue == model.routingStatusText else { return false }
        }
        return true
    }

    fileprivate func verifyCompanionControlsHidden(_ model: MenuBarPresentation) -> Bool {
        guard model.companionMode else { return false }
        let normal = MenuBarPresentation(mode: model.mode, state: model.state,
            preferredProfileID: model.preferredProfileID, outputName: model.outputName,
            suspended: model.suspended, released: model.released, recovering: model.recovering,
            profiles: model.profiles, outputUID: model.observedOutputUID,
            routingRestoring: model.routingRestoring, routingError: model.routingError,
            dspPlaybackUID: model.dspPlaybackUID, dspPlaybackName: model.dspPlaybackName,
            reconfiguringAudio: model.reconfiguringAudio, automaticSwitching: true)
        let window = OwnedRasterWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.focusedForVerification = true
        window.contentView = self
        defer { window.close() }
        render(normal, error: nil)
        let normalHeight = measureNaturalSize().height
        guard controlsBody.arrangedSubviews.filter(\.isHidden).isEmpty,
              dspControl.segmentCount == 3,
              (0..<3).map({ dspControl.label(forSegment: $0) }) == ["Auto", "On", "Off"],
              dspControl.selectedSegment == 1 else { return false }
        guard window.makeFirstResponder(fallbackControl) else { return false }
        render(model, error: nil)
        let hiddenRows = controlsBody.arrangedSubviews.filter(\.isHidden)
        let companionHeight = measureNaturalSize().height
        guard hiddenRows.count == 3 && !routingControl.isEnabled && companionHeight < normalHeight &&
              window.firstResponder === dspControl && dspControl.segmentCount == 2 &&
              (0..<2).map({ dspControl.label(forSegment: $0) }) == ["On", "Off"] &&
              dspControl.selectedSegment == 0 && dspControl.isEnabled(forSegment: 0) &&
              dspControl.isEnabled(forSegment: 1) else { return false }
        var callbacks: [Int] = []
        onDSPMode = { callbacks.append($0) }
        dspControl.selectedSegment = 1
        guard let action = dspControl.action,
              NSApp.sendAction(action, to: dspControl.target, from: dspControl),
              callbacks == [1] else { return false }
        let companionOff = MenuBarPresentation(mode: .forceOff, state: .idle,
            preferredProfileID: model.selectedProfileID, outputName: model.outputName,
            suspended: false, released: false, recovering: false, profiles: model.profiles,
            automaticSwitching: false)
        render(companionOff, error: nil)
        guard dspControl.selectedSegment == 1,
              dspControl.selectedSegmentBezelColor == AudioMuteButton.activeFill else { return false }
        render(normal, error: nil)
        return dspControl.segmentCount == 3 &&
            (0..<3).map({ dspControl.label(forSegment: $0) }) == ["Auto", "On", "Off"] &&
            dspControl.selectedSegment == 1 && dspControl.isEnabled(forSegment: 0) &&
            !dspControl.isEnabled(forSegment: 1) && dspControl.isEnabled(forSegment: 2)
    }

    fileprivate func verifyStatusFeedbackLayout() -> Bool {
        let guiFailure = GUIStatus(profileID: "fixture", policy: .manualOn, autoStart: false,
                                   desiredRunning: true, observed: .failed, url: "http://localhost:5005", lastError: "GUI deadline")
        func model(_ state: RuntimeState = .active("fixture"), available: Bool = true,
                   released: Bool = false, suspended: Bool = false, recovering: Bool = false,
                   routingRestoring: Bool = false, reconfiguring: Bool = false,
                   mode: AutomationMode = .automatic, gui: GUIStatus? = nil) -> MenuBarPresentation {
            MenuBarPresentation(mode: mode, state: state, preferredProfileID: "fixture", outputName: "Fixture output",
                suspended: suspended, released: released, recovering: recovering,
                profiles: [ControllerProfile(id: "fixture", name: "Fixture", available: available,
                    guiUnavailableReason: gui == nil ? "Not configured" : nil, gui: gui, captureUID: "capture")],
                outputUID: released ? "physical" : "capture", routingRestoring: routingRestoring,
                reconfiguringAudio: reconfiguring)
        }
        let ready = model()
        let faders = AuxFaderSnapshot(profileID: "fixture",
            faders: [AuxFader(id: 1, name: "Left", volumeDB: -6, muted: false, maximumDB: 6)],
            preferences: AuxPreferences(visibleIDs: [1]), ready: true,
            main: AuxFader(id: 0, name: "Main", volumeDB: -3, muted: false, maximumDB: 6))
        mainPanel.render(faders); auxPanel.render(faders)
        render(ready, error: nil)
        let size = measureNaturalSize()
        let landmarks: [NSView] = [dspControl, guiControl, routingControl, openButton, restartButton,
                                  mainPanel, metersPanel, auxPanel, presetPicker, moreButton,
                                  statusUpdateLabel, statusActionSlot]
        let frames = landmarks.map { convert($0.bounds, from: $0) }
        guard let row = statusUpdateLabel.superview,
              let group = dspOutputLabel.superview as? NSStackView,
              group.arrangedSubviews.last === row,
              group.arrangedSubviews.dropLast().last === dspOutputLabel,
              row.frame.height == AudioControlStyle.compactControlHeight,
              group.customSpacing(after: dspOutputLabel) == 0 else {
            print("Status row location/height failed: output parent \(String(describing: dspOutputLabel.superview)), row \(String(describing: statusUpdateLabel.superview?.frame))")
            return false
        }
        let longError = String(repeating: "Detailed failure with configuration and output information.\n", count: 20)
        let variants = [ready, model(released: true), model(routingRestoring: true), model(.starting("fixture")),
            model(.stopping("fixture")), model(recovering: true), model(reconfiguring: true),
            model(.idle, available: false), model(.idle, mode: .forceOff), model(.suspended, suspended: true),
            model(.failed("DSP deadline")), model(gui: guiFailure), model(.failed("DSP deadline"), gui: guiFailure)]
        for variant in variants {
            for error in [nil, "Short failure", longError] as [String?] {
                let changed = render(variant, error: error)
                let expected = variant.panelStatus(surfacedError: error)
                var aux = faders; aux.error = error
                mainPanel.render(aux); auxPanel.render(aux)
                guard !changed, measureNaturalSize() == size,
                      landmarks.map({ convert($0.bounds, from: $0) }) == frames,
                      !statusUpdateLabel.isHidden,
                      statusUpdateLabel.stringValue == "Status: " + expected.text,
                      statusUpdateLabel.toolTip == expected.detail,
                      statusUpdateLabel.accessibilityLabel() == statusUpdateLabel.stringValue,
                      statusUpdateLabel.accessibilityHelp() == expected.detail,
                      statusActionButton.isHidden == expected.actions.isEmpty,
                      statusActions == expected.actions else {
                    print("Status geometry failed: \(expected.text), error length \(error?.count ?? 0), changed \(changed), size \(measureNaturalSize()) vs \(size), frames \(landmarks.map { convert($0.bounds, from: $0) }) vs \(frames), actions \(statusActions) vs \(expected.actions)")
                    return false
                }
            }
        }
        var waitingFaders = faders; waitingFaders.ready = false
        render(model(.idle, available: false), error: nil)
        mainPanel.render(waitingFaders); auxPanel.render(waitingFaders)
        guard measureNaturalSize() == size else { print("Waiting fader status resized panel"); return false }
        mainPanel.render(faders); auxPanel.render(faders)
        var incomplete = faders
        incomplete.preferences = AuxPreferences(visibleIDs: [1], linkGroups: [[1, 2]])
        auxPanel.render(incomplete)
        let structuralSize = measureNaturalSize()
        incomplete.error = longError; auxPanel.render(incomplete)
        guard measureNaturalSize() == structuralSize else { return false }
        incomplete.ready = false; auxPanel.render(incomplete)
        guard measureNaturalSize() == structuralSize else { return false }
        mainPanel.render(faders); auxPanel.render(faders)
        var dispatched: [String] = []
        onDSPContext = { dispatched.append("DSP") }
        onGUIContext = { dispatched.append("GUI") }
        onDismissError = { dispatched.append("Dismiss") }
        render(ready, error: "One failed action")
        guard statusActionButton.title == "Dismiss" else { return false }
        statusActionPressed()
        guard dispatched == ["Dismiss"] else { return false }
        let failed = model(.failed("DSP deadline"), gui: guiFailure)
        render(failed, error: longError)
        let menu = makeStatusActionsMenu()
        guard statusActionButton.title == "Actions", menu.delegate === self,
              menu.items.map(\.title) == ["Retry DSP", "Retry GUI", "Dismiss"] else { return false }
        var tracking: [Bool] = []
        onChildMenuTracking = { tracking.append($0) }
        menuWillOpen(menu); menuDidClose(menu)
        guard tracking == [true, false] else { return false }
        for item in menu.items { statusMenuAction(item) }
        guard dispatched == ["Dismiss", "DSP", "GUI", "Dismiss"] else { return false }
        render(ready, error: nil)
        for item in menu.items { statusMenuAction(item) }
        guard dispatched == ["Dismiss", "DSP", "GUI", "Dismiss"], measureNaturalSize() == size,
              statusActionButton.isHidden, statusUpdateLabel.stringValue == "Status: Ready" else { return false }
        render(model(.failed(longError)), error: nil)
        return statusUpdateLabel.toolTip == "DSP failed" && statusActions == [.retryDSP]
            && measureNaturalSize() == size
    }

    fileprivate func verifyFooterControls() -> Bool {
        let buttons = [openButton, restartButton, statusActionButton, moreButton]
        guard buttons.allSatisfy({ $0.font == NSFont.systemFont(ofSize: 12) }),
              moreButton.title == "More",
              restartButton.bezelStyle == openButton.bezelStyle,
              restartButton.controlSize == openButton.controlSize,
              restartButton.cell?.cellSize.height == openButton.cell?.cellSize.height,
              presetPicker.font == NSFont.systemFont(ofSize: 12),
              let footer = moreButton.superview as? NSStackView,
              footer.arrangedSubviews.count == 2,
              footer.arrangedSubviews.first === presetPicker,
              footer.arrangedSubviews.last === moreButton,
              footer.arrangedSubviews.dropLast().last === presetPicker else { return false }
        let naturalSize = measureNaturalSize()
        guard abs(restartButton.frame.height - openButton.frame.height) < 0.5,
              abs(presetPicker.frame.height - moreButton.bezelRect.height) < 0.5,
              abs(presetPicker.frame.midY - moreButton.frame.midY) < 0.5 else { return false }
        let moreWidth = moreButton.frame.width
        let shortPickerWidth = presetPicker.frame.width
        let fullName = String(repeating: "Long preset name ", count: 16)
        let path = "/fixture/" + fullName + ".yml"
        let restartHelp = "Restarts audio\nSamplerate: 48000 → 96000\n" + path
        setPresetChoices([(id: path, title: fullName)], selectedID: path, enabled: true, reason: nil,
                         restartingIDs: [path: restartHelp])
        guard measureNaturalSize() == naturalSize,
              abs(moreButton.frame.width - moreWidth) < 0.5,
              abs(presetPicker.frame.width - shortPickerWidth) < 0.5,
              abs(presetPicker.frame.minX) < 0.5,
              abs(moreButton.frame.maxX - footer.bounds.width) < 0.5,
              presetPicker.selectedItem?.title == fullName,
              presetPicker.selectedItem?.image != nil,
              presetPicker.selectedItem?.attributedTitle?.string == fullName,
              presetPicker.selectedItem?.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange,
              presetPicker.selectedItem?.accessibilityHelp() == restartHelp,
              presetPicker.selectedItem?.toolTip == restartHelp,
              presetPicker.toolTip == restartHelp,
              presetPicker.selectedItem?.isEnabled == true,
              (presetPicker.cell as? NSPopUpButtonCell)?.lineBreakMode == .byTruncatingTail else { return false }
        setPresetChoices([(id: path, title: fullName)], selectedID: path, enabled: true, reason: nil,
                         unavailableIDs: [path: "Incompatible channels"], restartingIDs: [path: restartHelp])
        guard presetPicker.selectedItem?.image == nil, presetPicker.selectedItem?.attributedTitle == nil,
              presetPicker.selectedItem?.isEnabled == false,
              presetPicker.selectedItem?.toolTip == "Incompatible channels" else { return false }
        var selections: [String] = []
        onPreset = { selections.append($0) }
        setPresetChoices([(id: "flat", title: "Flat"), (id: "warm", title: "Warm")], selectedID: "flat", enabled: true, reason: nil)
        let items = presetPicker.itemArray
        setPresetChoices([(id: "flat", title: "Flat"), (id: "warm", title: "Warm")], selectedID: "warm", enabled: true, reason: nil)
        guard selections.isEmpty, zip(items, presetPicker.itemArray).allSatisfy({ $0.0 === $0.1 }),
              (presetPicker.selectedItem?.representedObject as? String) == "warm" else { return false }
        presetPicker.sendAction(presetPicker.action, to: presetPicker.target)
        guard selections == ["warm"] else { return false }
        setPresetChoices([(id: "flat", title: "Flat"), (id: "warm", title: "Warm")], selectedID: "warm", enabled: true, reason: nil, unavailableIDs: ["warm": "Incompatible channels"])
        guard zip(items, presetPicker.itemArray).allSatisfy({ $0.0 === $0.1 }),
              presetPicker.selectedItem?.isEnabled == false,
              presetPicker.selectedItem?.toolTip == "Incompatible channels" else { return false }
        presetPicker.sendAction(presetPicker.action, to: presetPicker.target)
        guard selections == ["warm"] else { return false }
        setPresetChoices([(id: "flat", title: "Flat")], selectedID: "external", enabled: true, reason: nil, placeholderTitle: "External preset")
        guard presetPicker.isEnabled, presetPicker.selectedItem?.title == "External preset",
              presetPicker.selectedItem?.isEnabled == true,
              presetPicker.selectedItem?.representedObject == nil else { return false }
        presetPicker.sendAction(presetPicker.action, to: presetPicker.target)
        guard selections == ["warm"] else { return false }
        presetPicker.selectItem(at: 1)
        presetPicker.sendAction(presetPicker.action, to: presetPicker.target)
        guard selections == ["warm", "flat"] else { return false }
        setPresetChoices([], selectedID: nil, enabled: false, reason: "Unavailable")
        presetPicker.sendAction(presetPicker.action, to: presetPicker.target)
        return selections == ["warm", "flat"] && presetPicker.itemTitles == ["Presets…"]
            && !presetPicker.isEnabled && presetPicker.toolTip == "Unavailable"
    }
}

public struct NativePanelLayoutSample {
    public let name: String
    public let documentHeight: CGFloat
    public let viewportHeight: CGFloat
    public let hasScroller: Bool
    public let contentFits: Bool
}

/// An owned, unshown surface supplies focus state without activating the application.
@MainActor private final class OwnedRasterWindow: NSWindow, AudioFocusVerificationWindow {
    var focusedForVerification = false
    override var isKeyWindow: Bool { focusedForVerification }
    override var isMainWindow: Bool { focusedForVerification }
}

/// Exercises native AppKit layout in an unshown window using synthetic snapshots.
/// Optional PNGs render only these owned views, never the desktop or live controller.
@MainActor public enum NativePanelLayoutVerification {
    public static func fallbackControlsKeepLayout() -> Bool { AudioControlPanel().verifyFallbackControls() }
    public static func footerControlsAreConsistent() -> Bool { AudioControlPanel().verifyFooterControls() }
    public static func statusFeedbackKeepsLayout() -> Bool { AudioControlPanel().verifyStatusFeedbackLayout() }

    public static func routineFeedbackKeepsLayout(_ models: [MenuBarPresentation]) -> Bool {
        AudioControlPanel().verifyRoutineLayout(models)
    }
    public static func companionControlsAreHidden(_ model: MenuBarPresentation) -> Bool {
        AudioControlPanel().verifyCompanionControlsHidden(model)
    }

    public static func focusStatusIsConsistent(_ off: MenuBarPresentation, failed: MenuBarPresentation, stopping: MenuBarPresentation) -> Bool {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { return false }
            let panel = AudioControlPanel()
            let window = OwnedRasterWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = panel
            defer { window.close() }
            panel.render(off, error: nil)
            let height = panel.measureNaturalSize().height
            let pinFrame = panel.pinButton.frame
            guard abs(pinFrame.width - AudioControlStyle.pinWidth) < 0.5,
                  abs(pinFrame.height - AudioControlStyle.compactControlHeight) < 0.5,
                  pinFrame.width < panel.compactButtons[1].frame.width else { return false }
            panel.setPinned(true)
            let offSymbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?.tiffRepresentation
            for focused in [true, false, true] {
                window.focusedForVerification = focused
                panel.refreshGUIStatusAppearance()
                panel.restartButton.refreshAppearance()
                guard panel.measureNaturalSize().height == height,
                      panel.pinButton.state == .on,
                      panel.pinButton.fillColor == NSColor.systemBlue,
                      panel.pinButton.foregroundColor == NSColor.white,
                      panel.pinButton.frame == pinFrame,
                      panel.pinButton.accessibilityLabel() == "Pin panel",
                      panel.guiStatusIcon.image?.tiffRepresentation == offSymbol,
                      panel.guiStatusLabel.stringValue == "GUI Off",
                      panel.guiStatusLabel.accessibilityLabel() == "GUI Off",
                      panel.guiStatusLabel.font == NSFont.systemFont(ofSize: 12, weight: .bold),
                      panel.guiStatusLabel.textColor == NSColor.systemRed,
                      panel.guiStatusIcon.contentTintColor == panel.guiStatusLabel.textColor,
                      panel.restartButton.foregroundColor == (focused ? NSColor.systemRed : .labelColor),
                      panel.restartButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == (focused ? NSColor.systemRed : nil),
                      panel.restartButton.bezelStyle == panel.openButton.bezelStyle else { return false }
                panel.restartButton.isEnabled = false
                guard panel.restartButton.bezelStyle == panel.openButton.bezelStyle else { return false }
                panel.restartButton.isEnabled = true
            }
            panel.setPinned(false)
            guard panel.pinButton.state == .off,
                  panel.pinButton.fillColor == panel.pinButton.neutralFill,
                  panel.pinButton.foregroundColor == NSColor.labelColor,
                  panel.measureNaturalSize().height == height,
                  panel.pinButton.frame == pinFrame else { return false }
            var pinChoices: [Bool] = []
            panel.onPin = { pinChoices.append($0) }
            panel.pinButton.performClick(nil)
            panel.pinButton.performClick(nil)
            guard pinChoices == [true, false], panel.pinButton.state == .off,
                  panel.measureNaturalSize().height == height, panel.pinButton.frame == pinFrame else { return false }
            for model in [failed, stopping] {
                panel.render(model, error: nil)
                panel.refreshGUIStatusAppearance()
                guard panel.guiStatusIcon.image?.tiffRepresentation != offSymbol,
                      panel.guiStatusLabel.stringValue == model.guiStatusText else { return false }
            }
        }
        return true
    }

    public static func compactButtonsKeepSharedGeometry() -> Bool {
        _ = NSApplication.shared
        let panel = AudioControlPanel()
        let width = AudioControlStyle.compactWidth
        let height = AudioControlStyle.compactControlHeight
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        guard AudioControlStyle.compactTitles.allSatisfy({ NSAttributedString(string: $0, attributes: font).size().width + AudioControlStyle.compactHorizontalPadding <= width }),
              AudioControlStyle.pinWidth >= NSAttributedString(string: "Pin", attributes: font).size().width + AudioControlStyle.compactHorizontalPadding,
              AudioControlStyle.pinWidth < width,
              AudioControlStyle.compactWidth(for: ["A longer translated retry action"]) > width else { return false }
        for button in panel.compactButtons {
            let isPin = button === panel.pinButton
            let expectedWidth = isPin ? AudioControlStyle.pinWidth : width
            guard button.constraints.contains(where: { $0.firstAttribute == .width && $0.constant == expectedWidth }),
                  button.constraints.contains(where: { $0.firstAttribute == .height && $0.constant == height }),
                  button.controlSize == .small, button.font == NSFont.systemFont(ofSize: 12) else { return false }
            let constraints = button.constraints.map { $0.constant }
            for title in isPin ? ["Pin"] : AudioControlStyle.compactTitles {
                button.title = title
                button.isEnabled.toggle()
                button.state = button.state == .on ? .off : .on
                guard button.constraints.map({ $0.constant }) == constraints else { return false }
            }
        }
        return panel.openButton.controlSize != .small && panel.restartButton.controlSize != .small
    }

    public static func primaryActionsMatchSharedHeight() -> Bool {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let panel = AudioControlPanel()
            let window = OwnedRasterWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: name)
            window.contentView = panel
            defer { window.close() }
            _ = panel.measureNaturalSize()
            let buttons: [AudioRoundedButton] = [panel.openButton, panel.restartButton]
            let frames = buttons.map { $0.frame }
            for focused in [true, false] {
                window.focusedForVerification = focused
                panel.restartButton.refreshAppearance()
                for enabled in [true, false] {
                    buttons.forEach { $0.isEnabled = enabled }
                    _ = panel.measureNaturalSize()
                    guard buttons.map({ $0.frame }) == frames,
                          panel.openButton.frame.width > panel.restartButton.frame.width,
                          buttons.allSatisfy({ $0.frame.width > AudioControlStyle.compactWidth }),
                          buttons.allSatisfy({
                              $0.frame.height == AudioControlStyle.compactControlHeight
                                  && $0.bezelRect.height == panel.compactButtons[0].bezelRect.height
                                  && $0.focusRingMaskBounds == $0.bezelRect
                                  && $0.font == NSFont.systemFont(ofSize: 12)
                          }) else {
                        let details = buttons.map { button in
                            "\(button.title): frame=\(button.frame), bounds=\(button.bounds), bezel=\(button.bezelRect), focus=\(button.focusRingMaskBounds), font=\(String(describing: button.font)), constraints=\(button.constraints)"
                        }.joined(separator: "\n")
                        print("Primary action geometry failed for \(name.rawValue), focused=\(focused), enabled=\(enabled). Expected frames: \(frames); comparison bezel: \(panel.compactButtons[0].bezelRect).\n\(details)")
                        return false
                    }
                }
            }
        }
        return true
    }

    public static func controlStyleIsConsistent() -> Bool {
        let control = NSSegmentedControl(labels: ["Auto", "On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
        AudioControlStyle.setOffSelected(control, selected: true)
        let selected = control.selectedSegmentBezelColor == nil
            && !AudioControlStyle.usesNativeSelectionAppearance(control)
            && (0..<3).allSatisfy { control.image(forSegment: $0) == nil }
            && control.label(forSegment: 2) == "Off"
        AudioControlStyle.setOffSelected(control, selected: false)
        return selected && control.selectedSegmentBezelColor == nil

    }

    public static func verifyAboutWindow(renderDirectory: URL? = nil) throws -> Bool {
        try AboutDiagnosticsWindow.verifyOwnedWindow(renderDirectory: renderDirectory)
    }

    public static func routingSelectionMatchesObservation(_ model: MenuBarPresentation) -> Bool {
        let panel = AudioControlPanel()
        panel.render(model, error: nil)
        let expected: Int
        switch model.routingControlSelection { case .processed: expected = 0; case .direct: expected = 1; case .pending, .unknown: expected = -1 }
        return panel.routingControl.selectedSegment == expected
            && panel.routingControl.isEnabled(forSegment: 0) == (expected == 0 || model.routingProcessed.enabled)
            && panel.routingControl.isEnabled(forSegment: 1) == (expected == 1 || model.routingDirect.enabled)
    }

    public static func offlineRoutingAndStatusAreTruthful() -> Bool {
        let profile = ControllerProfile(id: "fixture", name: "Fixture", available: false,
            guiUnavailableReason: "Not configured", gui: nil, captureUID: "virtual")
        let cases: [(RuntimeState, AutomationMode, Bool, Bool, String, NSColor)] = [
            (.idle, .forceOff, false, false, "xmark.circle.fill", .systemRed),
            (.idle, .forceOn, false, false, "circle", .systemYellow),
            (.suspended, .automatic, false, false, "circle", .systemYellow),
            (.failed("Fixture failure"), .forceOn, false, false, "exclamationmark.circle.fill", .systemRed),
            (.starting("fixture"), .forceOn, false, false, "clock", .systemOrange),
            (.active("fixture"), .forceOn, true, false, "clock", .systemOrange),
            (.active("fixture"), .forceOn, false, true, "clock", .systemOrange),
            (.active("fixture"), .forceOn, false, false, "checkmark.circle.fill", .systemGreen)
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let panel = AudioControlPanel()
            let window = OwnedRasterWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearanceName)
            window.contentView = panel
            defer { window.close() }
            var routeCommands = 0
            panel.onRouting = { _ in routeCommands += 1 }
            for (runtime, mode, recovering, reconfiguring, symbol, color) in cases {
                let model = MenuBarPresentation(mode: mode, state: runtime, preferredProfileID: "fixture",
                    outputName: "Virtual output", suspended: false, released: false, recovering: recovering,
                    profiles: [profile], outputUID: "virtual", reconfiguringAudio: reconfiguring)
                panel.render(model, error: nil)
                let confirmed = runtime == .active("fixture") && !recovering && !reconfiguring
                guard let expectedImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.tiffRepresentation else { return false }
                let size = panel.measureNaturalSize()
                for focused in [true, false] {
                    window.focusedForVerification = focused; panel.refreshSelectionAppearance()
                    guard panel.routingControl.selectedSegment == (confirmed ? 0 : -1),
                          panel.dspStatusIcon.image?.tiffRepresentation == expectedImage,
                          panel.statusLabel.textColor == color,
                          panel.routingControl.accessibilityValue() as? String == model.routingStatusText,
                          panel.routingControl.toolTip(forSegment: 0) == model.routingProcessedHelp,
                          panel.measureNaturalSize() == size, routeCommands == 0 else { return false }
                }
                // Reverting a declined action must restore the same honest selection.
                panel.routingControl.selectedSegment = 0
                panel.routingControl.sendAction(panel.routingControl.action, to: panel.routingControl.target)
                guard panel.routingControl.selectedSegment == (confirmed ? 0 : -1) else { return false }
            }
        }
        return true
    }

    private static func statusColor(_ emphasis: MenuStatusEmphasis) -> NSColor {
        switch emphasis {
        case .active: return .systemGreen
        case .off, .error: return .systemRed
        case .direct, .waiting: return .systemYellow
        case .bypassed, .transition: return .systemOrange
        case .neutral: return .secondaryLabelColor
        }
    }

    public static func headerMatchesPresentation(_ model: MenuBarPresentation) -> Bool {
        let panel = AudioControlPanel()
        panel.render(model, error: nil)
        let expected: NSColor
        let weight: NSFont.Weight
        let symbol: String
        let displayedEmphasis = model.guiStatusEmphasis
        switch displayedEmphasis {
        case .active: expected = .systemGreen; weight = .bold; symbol = "checkmark.circle.fill"
        case .error: expected = .systemRed; weight = .bold; symbol = "exclamationmark.circle.fill"
        case .off: expected = .systemRed; weight = .bold; symbol = "xmark.circle.fill"
        case .direct: expected = .systemYellow; weight = .bold; symbol = "arrow.triangle.branch"
        case .bypassed: expected = .systemOrange; weight = .bold; symbol = "arrow.triangle.branch"
        case .transition: expected = .systemOrange; weight = .medium; symbol = "clock"
        case .waiting: expected = .systemYellow; weight = .medium; symbol = "circle"
        case .neutral: expected = .secondaryLabelColor; weight = .medium; symbol = "circle"
        }
        guard let expectedIcon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let expectedPixels = expectedIcon.tiffRepresentation,
              panel.guiStatusIcon.image?.tiffRepresentation == expectedPixels else { return false }
        let naturalHeight = panel.measureNaturalSize().height
        guard let row = panel.guiStatusLabel.superview else { return false }
        let rowHeight = row.frame.height
        // Exercise the styling transitions in place. Context/actions retain the
        // same model, isolating any height change caused by status font/icon work.
        for emphasis in [MenuStatusEmphasis.neutral, .active, .error, .transition, .bypassed, .off, .direct, .waiting] {
            panel.emphasize(panel.guiStatusLabel, icon: panel.guiStatusIcon, state: emphasis)
            guard panel.measureNaturalSize().height == naturalHeight, row.frame.height == rowHeight else { return false }
        }
        panel.refreshGUIStatusAppearance()
        let focusWindow = OwnedRasterWindow(contentRect: NSRect(origin: .zero, size: panel.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        focusWindow.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        focusWindow.contentView = host; host.addSubview(panel)
        defer { panel.removeFromSuperview(); focusWindow.close() }
        for focused in [true, false] {
            focusWindow.focusedForVerification = focused
            panel.refreshSelectionAppearance()
            guard panel.statusLabel.textColor == statusColor(model.dspStatusEmphasis),
                  panel.dspStatusIcon.contentTintColor == panel.statusLabel.textColor,
                  panel.routingStatusLabel.textColor == statusColor(model.routingStatusEmphasis),
                  panel.routingStatusIcon.contentTintColor == panel.routingStatusLabel.textColor,
                  panel.measureNaturalSize().height == naturalHeight else { return false }
        }
        return panel.outputLabel.stringValue == model.systemOutputLine
            && panel.dspOutputLabel.stringValue == model.dspOutputLine
            && panel.outputLabel.toolTip == model.systemOutputLine
            && panel.dspOutputLabel.toolTip == model.dspOutputLine
            && panel.outputLabel.accessibilityLabel() == model.systemOutputLine
            && panel.dspOutputLabel.accessibilityLabel() == model.dspOutputLine
            && panel.guiStatusLabel.textColor == expected
            && panel.guiStatusLabel.font == NSFont.systemFont(ofSize: 12, weight: weight)
            && panel.guiStatusIcon.contentTintColor == expected
            && !panel.guiStatusIcon.isAccessibilityElement()
            && panel.guiStatusLabel.accessibilityLabel() == model.guiStatusText
            && panel.statusLabel.textColor == statusColor(model.dspStatusEmphasis)
            && panel.dspStatusIcon.contentTintColor == panel.statusLabel.textColor
            && panel.routingStatusLabel.textColor == statusColor(model.routingStatusEmphasis)
            && panel.routingStatusIcon.contentTintColor == panel.routingStatusLabel.textColor
            && panel.dspControl.focusRingType == .exterior
            && panel.routingControl.focusRingType == .exterior
    }

    private static func raster(_ view: NSView, appearance: NSAppearance, active: Bool = true) -> NSBitmapImageRep? {
        // Hosting and cacheDisplay exercise AppKit's complete view/cell renderer.
        // Direct view.draw misses native cell contents on recent macOS releases.
        let window = OwnedRasterWindow(contentRect: NSRect(origin: .zero, size: view.bounds.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.focusedForVerification = active
        window.appearance = appearance
        let host = NSView(frame: NSRect(origin: .zero, size: view.bounds.size))
        host.appearance = appearance
        window.contentView = host
        view.appearance = appearance
        view.removeFromSuperview()
        host.addSubview(view)
        if let control = view as? NSSegmentedControl { AudioControlStyle.refreshSelectionAppearance(control) }
        view.setFrameOrigin(.zero)
        host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        defer { view.removeFromSuperview(); window.close() }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        return bitmap
    }

    private static func pixels(_ bitmap: NSBitmapImageRep, matching predicate: (NSColor) -> Bool) -> Int {
        var count = 0
        for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) { count += 1 }
        } }
        return count
    }

    private static func whiteTextPixels(_ bitmap: NSBitmapImageRep, segment: Int? = nil, segmentCount: Int = 3) -> Int {
        let scale = CGFloat(bitmap.pixelsHigh) / 24
        let inset = max(3, Int(5 * scale))
        let left = segment == nil ? inset : bitmap.pixelsWide * (segment ?? 0) / segmentCount + inset
        let right = segment == nil ? bitmap.pixelsWide - inset : bitmap.pixelsWide * ((segment ?? 0) + 1) / segmentCount - inset
        let bottom = inset
        let top = bitmap.pixelsHigh - inset
        guard right > left, top > bottom else { return 0 }
        var count = 0
        for x in left..<right { for y in bottom..<top {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.alphaComponent > 0.8 && color.redComponent > 0.85 && color.greenComponent > 0.85 && color.blueComponent > 0.85 {
                count += 1
            }
        } }
        return count
    }

    /// Rasterizes the actual native controls in owned, unshown surfaces.
    public static func verifyNormalSelectionActiveColors(renderDirectory: URL? = nil) throws -> Bool {
        _ = NSApplication.shared
        let originalPreference = AudioControlStyle.keepActiveColors
        defer { AudioControlStyle.keepActiveColors = originalPreference }
        if let renderDirectory { try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true) }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else { return false }
            var accentRGB: [CGFloat] = []
            appearance.performAsCurrentDrawingAppearance {
                if let color = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) {
                    accentRGB = [color.redComponent, color.greenComponent, color.blueComponent]
                }
            }
            for (name, labels, selected) in [
                ("auto", ["Auto", "On", "Off"], 0),
                ("on", ["Auto", "On", "Off"], 1),
                ("processed", ["Processed", "Bypassed"], 0)
            ] {
                let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
                for index in labels.indices { control.setWidth(labels.count == 2 ? 76 : 51, forSegment: index) }
                control.font = .systemFont(ofSize: 12)
                AudioControlStyle.configureSegments(control)
                control.sizeToFit(); control.selectedSegment = selected
                let frame = control.frame
                var nativeAccentCount = 0
                for (stage, keepColors) in [false, true, false].enumerated() {
                    AudioControlStyle.keepActiveColors = keepColors
                    guard let image = raster(control, appearance: appearance, active: false) else { return false }
                    let left = image.pixelsWide * selected / labels.count
                    let right = image.pixelsWide * (selected + 1) / labels.count
                    var accentCount = 0
                    for x in left..<right { for y in 0..<image.pixelsHigh {
                        if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.alphaComponent > 0.8 {
                            let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
                            // Native inactive selection and labels are neutral.
                            // Test a substantial chromatic fill inside the selected
                            // segment without matching device-dependent RGB values.
                            if (rgb.max() ?? 0) - (rgb.min() ?? 0) > 0.25 { accentCount += 1 }
                        }
                    } }
                    if let renderDirectory, let png = image.representation(using: .png, properties: [:]) {
                        try png.write(to: renderDirectory.appendingPathComponent("segment-\(name)-\(appearanceName.rawValue)-keep-colors-\(stage).png"))
                        let sample = image.colorAt(x: left + 8, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
                        try "resolved system accent RGB=\(accentRGB); drawn sample RGB=\(String(describing: sample)); chromatic pixels=\(accentCount)\n".write(
                            to: renderDirectory.appendingPathComponent("segment-\(name)-\(appearanceName.rawValue)-keep-colors-\(stage).txt"),
                            atomically: true, encoding: .utf8)
                    }
                    guard control.selectedSegment == selected, control.isEnabled,
                          control.isEnabled(forSegment: selected), control.frame == frame,
                          control.trackingMode == .selectOne, control.focusRingType == .exterior,
                          control.selectedSegmentBezelColor == nil else { return false }
                    if stage == 0 { nativeAccentCount = accentCount }
                    else if keepColors {
                        guard accentCount > nativeAccentCount + 200,
                              whiteTextPixels(image, segment: selected, segmentCount: labels.count) > 10 else {
                            print("Inactive \(name) accent raster failed for \(appearanceName.rawValue): native=\(nativeAccentCount), preserved=\(accentCount), resolved accent RGB=\(accentRGB)")
                            return false
                        }
                    } else {
                        guard abs(accentCount - nativeAccentCount) <= 2 else { return false }
                    }
                }
                // Native disabled rendering remains responsible for availability.
                AudioControlStyle.keepActiveColors = true
                control.setEnabled(false, forSegment: selected)
                guard let _ = raster(control, appearance: appearance, active: false),
                      AudioControlStyle.usesNativeSelectionAppearance(control),
                      !control.isEnabled(forSegment: selected), control.selectedSegment == selected else { return false }
                control.setEnabled(true, forSegment: selected)
                let focusedWindow = OwnedRasterWindow(contentRect: NSRect(origin: .zero, size: control.bounds.size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                focusedWindow.isReleasedWhenClosed = false
                focusedWindow.focusedForVerification = true
                focusedWindow.contentView?.addSubview(control)
                let focusedUsesNative = AudioControlStyle.usesNativeSelectionAppearance(control)
                control.removeFromSuperview(); focusedWindow.close()
                guard focusedUsesNative else { return false }
            }
        }
        return true
    }

    /// Rasterizes the actual native controls in owned, unshown surfaces.
    public static func verifySegmentRasterization(renderDirectory: URL? = nil) throws -> Bool {
        _ = NSApplication.shared
        if let renderDirectory { try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true) }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else { return false }
            for name in ["dsp", "gui", "routing", "fallback", "fallback-manual"] {
                let warning = name == "routing" || name == "fallback-manual"
                let persistentOff = name == "fallback"
                let labels = name == "routing" ? ["Processed", "Bypassed"]
                    : name.hasPrefix("fallback") ? ["Auto", "Force", "Off"] : ["Auto", "On", "Off"]
                let selected = warning ? 1 : labels.count - 1
                let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
                control.segmentStyle = .rounded; control.controlSize = .regular
                for index in 0..<labels.count { control.setWidth(name == "routing" ? 76 : 51, forSegment: index) }
                control.sizeToFit(); control.selectedSegment = selected
                control.selectedSegmentBezelColor = AudioMuteButton.activeFill
                if let renderDirectory, let baseline = raster(control, appearance: appearance) {
                    let baselineRed = pixels(baseline) { $0.alphaComponent > 0.8 && $0.redComponent > 0.5 && $0.redComponent > $0.greenComponent * 2 && $0.redComponent > $0.blueComponent * 2 }
                    let baselineWhite = pixels(baseline) { $0.alphaComponent > 0.8 && $0.redComponent > 0.85 && $0.greenComponent > 0.85 && $0.blueComponent > 0.85 }
                    if let data = baseline.representation(using: .png, properties: [:]) {
                        try data.write(to: renderDirectory.appendingPathComponent("segment-native-baseline-\(name)-\(appearanceName.rawValue).png"))
                    }
                    try "red=\(baselineRed), white=\(baselineWhite), selected=\(control.selectedSegment), size=\(baseline.pixelsWide)x\(baseline.pixelsHigh)\n".write(to: renderDirectory.appendingPathComponent("segment-native-baseline-\(name)-\(appearanceName.rawValue).txt"), atomically: true, encoding: .utf8)
                }
                if warning { AudioControlStyle.setDirectSelected(control, selected: true) }
                else { AudioControlStyle.setOffSelected(control, selected: true, retainInactiveColor: persistentOff) }
                guard let bitmap = raster(control, appearance: appearance) else { return false }
                let red = pixels(bitmap) { $0.alphaComponent > 0.8 && $0.redComponent > 0.5 && $0.redComponent > $0.greenComponent * 2 && $0.redComponent > $0.blueComponent * 2 }
                let white = whiteTextPixels(bitmap, segment: selected, segmentCount: labels.count)
                if let renderDirectory, let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: renderDirectory.appendingPathComponent("segment-\(name)-off-\(appearanceName.rawValue).png"))
                }
                if let renderDirectory {
                    try "red=\(red), white=\(white), size=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), cell=\(type(of: control.cell!))\n".write(to: renderDirectory.appendingPathComponent("segment-\(name)-off-\(appearanceName.rawValue).txt"), atomically: true, encoding: .utf8)
                }
                // ColorSync may move the blue component past an absolute cutoff.
                // Orange requires a strong red component plus distinct green/blue
                // separation; grayscale, red Off and blue selection cannot match.
                let orange = pixels(bitmap) { $0.alphaComponent > 0.8 && $0.redComponent > 0.7 && $0.greenComponent > 0.25 && $0.redComponent > $0.greenComponent * 1.2 && $0.greenComponent > $0.blueComponent * 1.5 }
                guard (warning ? orange > 200 && red == 0 : red > 200), white > 10 else { return false }
                guard let inactive = raster(control, appearance: appearance, active: false) else { return false }
                let inactiveRed = pixels(inactive) { $0.alphaComponent > 0.8 && $0.redComponent > 0.5 && $0.redComponent > $0.greenComponent * 2 && $0.redComponent > $0.blueComponent * 2 }
                let inactiveBlue = pixels(inactive) { $0.alphaComponent > 0.8 && $0.blueComponent > 0.5 && $0.blueComponent > $0.redComponent * 1.4 && $0.blueComponent > $0.greenComponent * 1.2 }
                let inactiveOrange = pixels(inactive) { $0.alphaComponent > 0.8 && $0.redComponent > 0.7 && $0.greenComponent > 0.25 && $0.redComponent > $0.greenComponent * 1.2 && $0.greenComponent > $0.blueComponent * 1.5 }
                if let renderDirectory {
                    if let png = inactive.representation(using: .png, properties: [:]) {
                        try png.write(to: renderDirectory.appendingPathComponent("segment-\(name)-inactive-\(appearanceName.rawValue).png"))
                    }
                    try "red=\(inactiveRed), blue=\(inactiveBlue), orange=\(inactiveOrange), white=\(whiteTextPixels(inactive, segment: selected, segmentCount: labels.count)), bezel=\(String(describing: control.selectedSegmentBezelColor)), native=\(AudioControlStyle.usesNativeSelectionAppearance(control))\n".write(to: renderDirectory.appendingPathComponent("segment-\(name)-inactive-\(appearanceName.rawValue).txt"), atomically: true, encoding: .utf8)
                }
                guard (persistentOff ? inactiveRed > 200 : inactiveRed == 0), inactiveBlue == 0,
                      control.selectedSegmentBezelColor == (warning ? NSColor.systemOrange : (persistentOff ? AudioMuteButton.activeFill : nil)),
                      !persistentOff || whiteTextPixels(inactive, segment: selected, segmentCount: labels.count) > 10,
                      !warning || (inactiveOrange > 200 && whiteTextPixels(inactive, segment: selected, segmentCount: labels.count) > 10),
                      !AudioControlStyle.usesNativeSelectionAppearance(control) else { return false }
                // Compare the unaffected track with native Auto/On drawing. The
                // selected Off/Direct fill must not recolor the entire control.
                if warning { AudioControlStyle.setDirectSelected(control, selected: false) }
                else { AudioControlStyle.setOffSelected(control, selected: false) }
                control.selectedSegment = -1
                guard let nativeTrack = raster(control, appearance: appearance, active: false),
                      nativeTrack.pixelsWide == inactive.pixelsWide,
                      nativeTrack.pixelsHigh == inactive.pixelsHigh else { return false }
                if let renderDirectory, let png = nativeTrack.representation(using: .png, properties: [:]) {
                    try png.write(to: renderDirectory.appendingPathComponent("segment-\(name)-native-track-\(appearanceName.rawValue).png"))
                }
                let unselectedEnd = inactive.pixelsWide * selected / labels.count - 5
                for x in 0..<max(0, unselectedEnd) { for y in 0..<inactive.pixelsHigh {
                    guard let actual = inactive.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let expected = nativeTrack.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          abs(actual.alphaComponent - expected.alphaComponent) < 0.02,
                          abs(actual.redComponent - expected.redComponent) < 0.02,
                          abs(actual.greenComponent - expected.greenComponent) < 0.02,
                          abs(actual.blueComponent - expected.blueComponent) < 0.02 else { return false }
                } }

            }
        }
        return true
    }

    /// Check native selection configuration and enabled state. Unshown AppKit
    /// native bezels can rasterize transparently, so matching empty bitmaps is
    /// deliberately not treated as evidence of live menu appearance.
    public static func routingSelectedStyleMatchesNative(_ model: MenuBarPresentation) -> Bool {
        let panel = AudioControlPanel()
        panel.render(model, error: nil)
        let control = panel.routingControl
        let selected = control.selectedSegment
        return selected >= 0 && control.isEnabled && control.isEnabled(forSegment: selected)
            && control.label(forSegment: 0) == "Processed" && control.label(forSegment: 1) == "Bypassed"
            && control.image(forSegment: 0) == nil && control.image(forSegment: 1) == nil
            && control.segmentStyle == .rounded && control.controlSize == .regular
            && control.selectedSegmentBezelColor == (selected == 1 ? NSColor.systemOrange : nil)
            && AudioControlStyle.usesNativeSelectionAppearance(control) == (selected == 0)
    }

    public static func routingReselectionIsInert(_ model: MenuBarPresentation) -> Bool {
        let panel = AudioControlPanel()
        panel.render(model, error: nil)
        let selected = panel.routingControl.selectedSegment
        guard selected >= 0, panel.routingControl.isEnabled(forSegment: selected) else { return false }
        var calls = 0
        panel.onRouting = { _ in calls += 1 }
        panel.routingControl.sendAction(panel.routingControl.action, to: panel.routingControl.target)
        guard calls == 0, panel.routingControl.selectedSegment == selected else { return false }
        let alternative = 1 - selected
        panel.routingControl.selectedSegment = alternative
        panel.routingControl.sendAction(panel.routingControl.action, to: panel.routingControl.target)
        let available = alternative == 0 ? model.routingProcessed.enabled : model.routingDirect.enabled
        return calls == (available ? 1 : 0) && panel.routingControl.selectedSegment == selected
    }

    /// Compare the actual shared neutral button pixels, then verify active fill/text.
    public static func verifyMuteRasterization(renderDirectory: URL? = nil) throws -> Bool {
        _ = NSApplication.shared
        if let renderDirectory { try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true) }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else { return false }
            // Pin must retain its visible selected state in both focus states.
            for focused in [true, false] {
                let pin = AudioPinButton(frame: NSRect(x: 0, y: 0, width: 54, height: 24))
                pin.title = "Pin"; pin.setButtonType(.pushOnPushOff)
                AudioControlStyle.configureRounded(pin)
                pin.state = .on
                guard let selected = raster(pin, appearance: appearance, active: focused) else { return false }
                let blue = pixels(selected) { $0.alphaComponent > 0.8 && $0.blueComponent > 0.6
                    && $0.blueComponent > $0.redComponent * 1.4 && $0.blueComponent > $0.greenComponent * 1.2 }
                guard blue > 200, whiteTextPixels(selected) > 10, pin.state == .on else { return false }
                if let renderDirectory, let png = selected.representation(using: .png, properties: [:]) {
                    try png.write(to: renderDirectory.appendingPathComponent("pin-\(appearanceName.rawValue)-focused-\(focused).png"))
                }
                pin.state = .off
                guard let unselected = raster(pin, appearance: appearance, active: focused),
                      pixels(unselected, matching: { $0.alphaComponent > 0.8 && $0.blueComponent > 0.6
                          && $0.blueComponent > $0.redComponent * 1.4 && $0.blueComponent > $0.greenComponent * 1.2 }) == 0,
                      selected.pixelsWide == unselected.pixelsWide,
                      selected.pixelsHigh == unselected.pixelsHigh else { return false }
            }
            for enabled in [true, false] { for highlighted in [false, true] {
                let neutral = AudioRoundedButton(frame: NSRect(x: 0, y: 0, width: 54, height: 24))
                neutral.title = "0 dB"; AudioControlStyle.configureRounded(neutral)
                neutral.isEnabled = enabled; neutral.highlight(highlighted)
                guard let reference = raster(neutral, appearance: appearance) else { return false }
                for (name, state) in [("off", NSControl.StateValue.off), ("on", .on), ("mixed", .mixed)] {
                    let button = AudioMuteButton(frame: neutral.frame)
                    button.channelMuted = state != .off
                    button.title = "Mute"; button.setButtonType(.pushOnPushOff); button.allowsMixedState = true
                    AudioControlStyle.configureRounded(button)
                    button.isEnabled = enabled; button.highlight(highlighted)
                    AudioControlStyle.setMuteState(button, state: state)
                    guard let bitmap = raster(button, appearance: appearance) else { return false }
                    let red = pixels(bitmap) { $0.alphaComponent > 0.8 && $0.redComponent > 0.5 && $0.redComponent > $0.greenComponent * 2 && $0.redComponent > $0.blueComponent * 2 }
                    if let renderDirectory, let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: renderDirectory.appendingPathComponent("mute-\(appearanceName.rawValue)-\(name)-\(enabled)-\(highlighted).png"))
                        try "red=\(red), size=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)\n".write(to: renderDirectory.appendingPathComponent("mute-\(appearanceName.rawValue)-\(name)-\(enabled)-\(highlighted).txt"), atomically: true, encoding: .utf8)
                    }
                    if enabled && !highlighted && state == .on {
                        let white = whiteTextPixels(bitmap)
                        guard red > 200, white > 10 else { return false }
                    }
                    if enabled && !highlighted && state == .mixed { guard red > 10, red < bitmap.pixelsWide * bitmap.pixelsHigh / 2 else { return false } }
                    if state == .off {
                        if enabled && !highlighted && appearanceName == .darkAqua {
                            let gray = pixels(bitmap) { $0.alphaComponent > 0.8 && (0.15...0.4).contains($0.redComponent)
                                && abs($0.redComponent - $0.greenComponent) < 0.03 && abs($0.redComponent - $0.blueComponent) < 0.03 }
                            guard gray > 200, whiteTextPixels(bitmap) > 10 else { return false }
                        }
                        // Outer columns include the native bezel edges and corners,
                        // avoiding the different labels in the middle.
                        for x in [0, 1, 3, 5, bitmap.pixelsWide - 6, bitmap.pixelsWide - 4, bitmap.pixelsWide - 2, bitmap.pixelsWide - 1] { for y in 0..<bitmap.pixelsHigh {
                            guard let lhs = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                                  let rhs = reference.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                                  abs(lhs.alphaComponent - rhs.alphaComponent) < 0.02,
                                  abs(lhs.redComponent - rhs.redComponent) < 0.02,
                                  abs(lhs.greenComponent - rhs.greenComponent) < 0.02,
                                  abs(lhs.blueComponent - rhs.blueComponent) < 0.02 else { return false }
                        } }
                    }
                    if let renderDirectory, let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: renderDirectory.appendingPathComponent("mute-\(appearanceName.rawValue)-\(name)-\(enabled)-\(highlighted).png"))
                    }
                }
            } }
        }
        return true
    }

    public static func samples(renderDirectory: URL? = nil) throws -> [NativePanelLayoutSample] {
        _ = NSApplication.shared
        let panel = AudioControlPanel()
        let scroll = NSScrollView()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = panel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let profile = ControllerProfile(id: "studio", name: "Studio", available: true, guiUnavailableReason: "GUI not configured", gui: nil)
        let active = MenuBarPresentation(mode: .forceOn, state: .active("studio"), preferredProfileID: "studio", outputName: "System interface with a very long descriptive audio device name", suspended: false, released: false, recovering: false, profiles: [profile], dspPlaybackUID: "studio-output", dspPlaybackName: "Verified playback interface with a very long descriptive audio device name")
        var aux = AuxFaderSnapshot(profileID: "studio", faders: (1...4).map {
            AuxFader(id: $0, name: "Aux \($0)", volumeDB: -12, muted: false, maximumDB: 0)
        }, preferences: AuxPreferences(visibleIDs: [1, 2, 3, 4]), ready: true)
        var result: [NativePanelLayoutSample] = []
        if let renderDirectory { try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true) }
        func sample(_ name: String, screenHeight: CGFloat = 1200, error: String? = nil) throws {
            panel.render(active, error: error)
            panel.auxPanel.render(aux)
            let layout = PanelViewportLayout(naturalSize: panel.measureNaturalSize(), screenHeight: screenHeight)
            scroll.hasVerticalScroller = layout.requiresScrolling
            window.setContentSize(layout.viewportSize)
            panel.setFrameSize(layout.documentSize)
            scroll.layoutSubtreeIfNeeded()
            panel.layoutSubtreeIfNeeded()
            let fits = visibleViewsFit(panel, in: panel)
            result.append(NativePanelLayoutSample(name: name, documentHeight: panel.frame.height,
                                                  viewportHeight: scroll.contentSize.height,
                                                  hasScroller: scroll.hasVerticalScroller, contentFits: fits))
            if let renderDirectory, let image = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                panel.cacheDisplay(in: panel.bounds, to: image)
                if let data = image.representation(using: .png, properties: [:]) {
                    try data.write(to: renderDirectory.appendingPathComponent(name + ".png"))
                }
            }
        }
        panel.auxPanel.render(aux)
        panel.auxPanel.collapse()
        try sample("collapsed")
        // Repeated snapshots must not touch controls or invalidate geometry.
        guard !panel.render(active, error: nil), !panel.auxPanel.render(aux) else {
            throw NSError(domain: "NativePanelLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: "An unchanged snapshot invalidated native panel geometry"])
        }
        panel.auxPanel.expand()
        try sample("expanded")
        var repeatedExpansionLayouts = 0
        var repeatedExpansionReads = 0
        panel.auxPanel.onLayout = { repeatedExpansionLayouts += 1 }
        panel.auxPanel.onExpand = { repeatedExpansionReads += 1 }
        panel.auxPanel.expand()
        guard panel.auxPanel.isExpanded, repeatedExpansionLayouts == 0, repeatedExpansionReads == 0 else {
            throw NSError(domain: "NativePanelLayout", code: 2, userInfo: [NSLocalizedDescriptionKey: "Repeated Levels expansion requested redundant layout or refresh"])
        }
        for index in 0..<4 {
            aux.busy = true
            try sample("busy-\(index)")
            aux.busy = false
            aux.faders[0].muted.toggle()
            try sample("muted-\(index)")
        }
        try sample("error", error: "An example command failed. Review the current output and try again.")
        try sample("small-screen", screenHeight: 500)
        window.close()
        return result
    }

    private static func visibleViewsFit(_ view: NSView, in document: NSView) -> Bool {
        let children: [NSView]
        if let stack = view as? NSStackView {
            children = stack.arrangedSubviews
        } else if view === document || view is AuxFaderPanel {
            children = view.subviews
        } else {
            // Check the owned control's full frame, without entering private
            // AppKit subviews that can intentionally extend its alignment bounds.
            return true
        }
        for child in children where !child.isHidden {
            let frame = child.convert(child.bounds, to: document)
            // Controls may extend outside their immediate stack's alignment rect.
            // What matters for clipping is their complete document-space frame.
            guard frame.minX >= -1, frame.maxX <= document.bounds.width + 1,
                  frame.minY >= -1, frame.maxY <= document.bounds.height + 1,
                  visibleViewsFit(child, in: document) else { return false }
        }
        return true
    }
}

extension NativePanelLayoutVerification {
    /// Inspect only owned background drawing. This does not reproduce the live
    /// popover compositor or establish text contrast over every desktop backdrop.
    public static func continuousGlassCoversPanel(renderDirectory: URL? = nil) throws -> Bool {
        let panel = AudioControlPanel(frame: NSRect(x: 0, y: 0, width: 388, height: 120))
        let frame = panel.frame
        let children = panel.subviews.map(ObjectIdentifier.init)
        let reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if let renderDirectory { try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { return false }
            let dark = name == .darkAqua
            panel.appearance = appearance
            let fallback = AudioControlPanel.continuousGlassTint(dark: dark, reduceTransparency: true)
            guard let opaque = fallback.usingColorSpace(.sRGB), opaque.alphaComponent > 0.99,
                  abs(opaque.redComponent - opaque.greenComponent) < 0.001,
                  abs(opaque.redComponent - opaque.blueComponent) < 0.001,
                  dark ? opaque.redComponent < 0.2 : opaque.redComponent > 0.9 else { return false }
            for (backdrop, gray) in [("clear", nil), ("white", CGFloat(1)), ("gray", CGFloat(0.5)), ("black", CGFloat(0))] as [(String, CGFloat?)] {
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 388, pixelsHigh: 120,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                appearance.performAsCurrentDrawingAppearance {
                    if let gray { NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1).setFill(); panel.bounds.fill() }
                    panel.draw(panel.bounds)
                }
                NSGraphicsContext.restoreGraphicsState()
                guard let center = bitmap.colorAt(x: 194, y: 60)?.usingColorSpace(.sRGB),
                      abs(center.redComponent - center.greenComponent) < 0.01,
                      abs(center.redComponent - center.blueComponent) < 0.01 else { return false }
                // Include all document corners and both outer padding regions.
                for point in [(0, 0), (387, 0), (0, 119), (387, 119), (8, 60), (379, 60), (194, 8), (194, 112)] {
                    guard let color = bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB),
                          abs(color.alphaComponent - center.alphaComponent) < 0.01,
                          abs(color.redComponent - center.redComponent) < 0.01,
                          abs(color.greenComponent - center.greenComponent) < 0.01,
                          abs(color.blueComponent - center.blueComponent) < 0.01 else { return false }
                }
                if gray == nil {
                    let alpha: CGFloat = reducedTransparency ? 1 : (dark ? 0.18 : 0.07)
                    guard abs(center.alphaComponent - alpha) < 0.015 else { return false }
                } else {
                    guard center.alphaComponent > 0.99 else { return false }
                    if !reducedTransparency, let gray, gray > 0 {
                        guard center.redComponent < gray - (dark ? 0.04 : 0.015) else { return false }
                    }
                }
                if let renderDirectory, let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: renderDirectory.appendingPathComponent("panel-wash-\(dark ? "dark" : "light")-\(backdrop).png"))
                }
            }
        }
        return panel.frame == frame && panel.subviews.map(ObjectIdentifier.init) == children
    }

    /// Appearance overrides do not grant focus, change selection or enable actions.
    public static func activeColorsPreserveFocusAndPolicy() -> Bool {
        _ = NSApplication.shared
        let previous = AudioControlStyle.keepActiveColors
        defer { AudioControlStyle.keepActiveColors = previous }
        let window = OwnedRasterWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 70),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.focusedForVerification = false
        defer { window.close() }
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content
        let control = NSSegmentedControl(labels: ["Auto", "On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 2
        content.addSubview(control)
        let restart = AudioRestartButton(title: "Restart DSP", target: nil, action: nil)
        content.addSubview(restart)
        for keepColors in [false, true, false] {
            AudioControlStyle.keepActiveColors = keepColors
            AudioControlStyle.setOffSelected(control, selected: true)
            restart.refreshAppearance()
            guard !AudioControlStyle.windowIsActive(window), !window.isKeyWindow,
                  control.selectedSegment == 2, control.isEnabled,
                  AudioControlStyle.selectionIsActive(control) == keepColors,
                  control.selectedSegmentBezelColor == (keepColors ? AudioMuteButton.activeFill : nil),
                  restart.foregroundColor == (keepColors ? NSColor.systemRed : .labelColor) else { return false }
        }
        return true
    }
}
