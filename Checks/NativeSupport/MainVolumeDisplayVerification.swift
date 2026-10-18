import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor enum MainVolumeDisplayVerification {
    static func checks() -> [String: Bool] {
        _ = NSApplication.shared
        let main = AuxFaderPanel(frame: .zero, mainOnly: true)
        let aux = AuxFaderPanel(frame: .zero)
        var state = AuxFaderSnapshot(profileID: "test", preferences: AuxPreferences(visibleIDs: []), ready: true,
            main: AuxFader(id: 0, name: "Main Volume", volumeDB: 0, muted: false, maximumDB: 0))
        main.render(state); aux.render(state)
        let before = main.sliderPositions[0]
        var result = ["Main visible independently of hidden Aux": !main.isHidden && aux.isHidden]
        state.main?.volumeDB = -12; state.main?.muted = true
        main.render(state)
        result["refresh updates Main knob number and mute"] = main.sliderPositions[0] != before && main.displayedVolumes[0] == -12 && main.displayedMuteStates[0] == NSControl.StateValue.on.rawValue
        var typed: Double?
        main.onPreciseVolume = { id, db, _ in if id == 0 { typed = db } }
        result["Main exact field dispatches id zero"] = main.submitPreciseValue(id: 0, text: "-27") && typed == -27
        state.ready = false; main.render(state)
        result["DSP loss disables Main controls"] = main.enabledControls[0] == [false, false, false]
        state.ready = true; state.main?.maximumDB = 20; state.main?.volumeDB = -10
        main.render(state)
        result["Main independent default listening midpoint"] = main.sliderPositions[0] == 0.5
        let writesBeforeRange = typed
        main.setMainSliderRange(minimumDB: -80, maximumDB: 4)
        result["Main range edit has no gain write"] = typed == writesBeforeRange && main.displayedVolumes[0] == -10
        state.preferences.sliderMinimumDB = -20
        main.render(state)
        result["Aux minimum does not alter Main scale"] = main.sliderPositions[0] == 0.5
        main.setMainSliderRange(minimumDB: -50, maximumDB: 6)
        state.main?.volumeDB = 12
        main.render(state)
        result["above-travel Main retains actual value"] = main.displayedVolumes[0] == 12 && main.sliderPositions[0] == 1 && main.displayedNames[0]?.contains("Above slider range") == true
        result["above-travel exact value remains available"] = main.submitPreciseValue(id: 0, text: "18") && typed == 18
        main.setMainSliderRange(minimumDB: -5, maximumDB: 6)
        state.main?.maximumDB = -10; state.main?.volumeDB = -20
        main.render(state)
        result["empty Main interval disables slider only"] = main.enabledControls[0] == [false, true, false] && main.submitPreciseValue(id: 0, text: "-30") && typed == -30
        main.setMainSliderRange(minimumDB: -50, maximumDB: 6)
        state.main?.maximumDB = 3; state.main?.volumeDB = 3
        main.render(state)
        result["Main ceiling intersects true DSP maximum"] = main.sliderPositions[0] == 1 && main.displayedNames[0]?.contains("Above slider range") == false
        result.merge(mainGestureChecks(), uniquingKeysWith: { _, newest in newest })
        result.merge(retainedMainGeometryChecks(), uniquingKeysWith: { _, newest in newest })
        let meters = SignalLevelsPanel(frame: .zero)
        var levels = SignalLevelsSnapshot()
        meters.render(levels)
        result["meters hidden when Off"] = !meters.metersVisible
        levels.enabled = true
        levels.levels = SignalLevels(input: [SignalChannelLevel(label: "Left", rmsDB: -24, peakDB: -6)], output: [SignalChannelLevel(label: "Sub", rmsDB: -40, peakDB: -12)])
        meters.render(levels)
        result["meters show both labeled sides"] = meters.metersVisible && meters.channelLabels == ["IN: Left", "OUT: Sub"]
        levels.levels?.input[0].rmsDB = -12
        result["meter samples do not reflow panel"] = !meters.render(levels)
        levels.enabled = false; levels.levels = nil; meters.render(levels)
        result["toggle Off hides meter rows"] = !meters.metersVisible && meters.channelLabels.isEmpty
        let groupPanel = AuxFaderPanel(frame: .zero)
        state = AuxFaderSnapshot(profileID: "groups", faders: (1...4).map { AuxFader(id: $0, name: "Aux\($0)", volumeDB: 0, muted: false, maximumDB: 0) }, preferences: AuxPreferences(visibleIDs: [1,2,3,4], linkGroups: [[1,2],[3,4]]), ready: true)
        groupPanel.render(state)
        result["linked rows identify both groups"] = groupPanel.displayedNames[1] == "Aux1 · Group 1" && groupPanel.displayedNames[3] == "Aux3 · Group 2"
        return result
    }
    private static func retainedMainGeometryChecks() -> [String: Bool] {
        let panel = AuxFaderPanel(frame: .zero, mainOnly: true)
        panel.presentsStatusFeedbackLocally = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = host; host.addSubview(panel)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                                     panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                     panel.topAnchor.constraint(equalTo: host.topAnchor)])
        var state = AuxFaderSnapshot(profileID: "retained-main", ready: true,
            main: AuxFader(id: 0, name: "Main Volume", volumeDB: -12, muted: true, maximumDB: 6))
        var commands = 0
        panel.onVolume = { _, _, _, _ in commands += 1 }
        panel.onMute = { _, _, _, _ in commands += 1 }
        panel.onPreciseVolume = { _, _, _ in commands += 1 }
        panel.render(state); host.layoutSubtreeIfNeeded()
        let readySize = panel.fittingSize
        let divider = panel.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.first as? NSBox
        let readyDivider = divider?.frame
        state.ready = false
        let changed = panel.render(state); host.layoutSubtreeIfNeeded()
        var result = ["retained Main and separator do not reflow on authority loss": !changed && !panel.isHidden && panel.fittingSize == readySize && divider?.frame == readyDivider,
                      "retained Main controls are disabled": panel.enabledControls[0] == [false, false, false]]
        panel.commitVolume(id: 0, db: -30, profileID: state.profileID)
        panel.simulateMuteActivation(id: 0)
        let accepted = panel.submitPreciseValue(id: 0, text: "-30")
        result["retained Main rejects all input without commands"] = !accepted && commands == 0 && panel.displayedVolumes[0] == -12
        panel.restorePreciseValue(id: 0)
        state.error = "Synthetic restart failure"; panel.render(state); host.layoutSubtreeIfNeeded()
        result["failed refresh retains disabled Main geometry"] = !panel.isHidden && panel.fittingSize == readySize && divider?.frame == readyDivider && panel.enabledControls[0] == [false, false, false]
        state.ready = true; state.error = nil; state.main?.volumeDB = -18
        panel.render(state); host.layoutSubtreeIfNeeded()
        result["fresh recovery updates Main without moving separator"] = panel.displayedVolumes[0] == -18 && panel.enabledControls[0] == [true, true, true] && panel.fittingSize == readySize && divider?.frame == readyDivider
        state.main = nil; panel.render(state)
        result["authoritative absent Main hides row and its divider"] = panel.isHidden
        window.contentView = nil; window.close()
        return result
    }
    private static func mainGestureChecks() -> [String: Bool] {
        let panel = AuxFaderPanel(frame: .zero, mainOnly: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = host; host.addSubview(panel)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                                     panel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
                                     panel.topAnchor.constraint(equalTo: host.topAnchor, constant: 12)])
        var state = AuxFaderSnapshot(profileID: "travel", preferences: AuxPreferences(), ready: true,
                                    main: AuxFader(id: 0, name: "Main", volumeDB: 12, muted: false, maximumDB: 20))
        var updates = 0
        var gestureIntent: AuxVolumeIntent?
        panel.onVolumeDragBegin = { _, _, intent in gestureIntent = intent; return true }
        panel.onVolumeDragUpdate = { _, _, _ in updates += 1 }
        panel.onVolumeDragCancel = {}
        panel.render(state); host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        panel.simulateVolumePointer(id: 0, type: .leftMouseDown, db: 12, modifiers: .shift)
        panel.simulateVolumePointer(id: 0, type: .leftMouseUp, db: 12)
        var result = ["above-travel grab release sends no gain": updates == 0 && panel.displayedVolumes[0] == 12,
                      "Main Shift keeps its ordinary gesture scope": gestureIntent == .group]
        panel.simulateVolumePointer(id: 0, type: .leftMouseDown, db: 12)
        panel.simulateVolumePointer(id: 0, type: .leftMouseDragged, db: 11.8)
        result["above-travel tiny movement stays continuous"] = abs((panel.displayedVolumes[0] ?? 0) - 11.8) < 1e-7 && updates == 1
        panel.cancelVolumeDrag()
        state.main?.volumeDB = -70; panel.render(state)
        panel.simulateVolumePointer(id: 0, type: .leftMouseDown, db: -70)
        let before = updates
        panel.simulateVolumePointer(id: 0, type: .leftMouseUp, db: -70)
        result["below-travel Main grab release sends no gain"] = before == updates && panel.displayedVolumes[0] == -70
        panel.simulateVolumePointer(id: 0, type: .leftMouseDown, db: -70)
        panel.simulateVolumePointer(id: 0, type: .leftMouseDragged, db: -69.8)
        result["below-travel Main tiny movement stays continuous"] = abs((panel.displayedVolumes[0] ?? 0) + 69.8) < 1e-7
        panel.setMainSliderRange(minimumDB: -80, maximumDB: 4)
        result["Main range edit cancels gesture without new gain"] = updates == before + 1 && panel.displayedVolumes[0] == -70
        window.contentView = nil; window.close()
        return result
    }

    static func render(to directory: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let panel = AudioControlPanel()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            window.contentView = panel
            let profile = ControllerProfile(id: "bedroom", name: "Bedroom EQ", available: true, guiUnavailableReason: "Not configured", gui: nil, captureUID: "blackhole")
            let model = MenuBarPresentation(mode: .automatic, state: .active("bedroom"), preferredProfileID: "bedroom", outputName: "BlackHole 2ch", suspended: false, released: false, recovering: false, profiles: [profile], outputUID: "blackhole")
            panel.render(model, error: nil)
            let faders = [AuxFader(id: 1, name: "Left", volumeDB: -3, muted: false, maximumDB: 0), AuxFader(id: 2, name: "Right", volumeDB: -3, muted: false, maximumDB: 0), AuxFader(id: 3, name: "Sub", volumeDB: -6, muted: true, maximumDB: 0)]
            let state = AuxFaderSnapshot(profileID: "bedroom", faders: faders, preferences: AuxPreferences(visibleIDs: [1,2,3], linkGroups: [[1,2]], sliderMinimumDB: -50), ready: true, main: AuxFader(id: 0, name: "Main Volume", volumeDB: -10, muted: false, maximumDB: 0))
            panel.mainPanel.render(state); panel.auxPanel.render(state)
            var meters = SignalLevelsSnapshot(); meters.enabled = true; meters.reading = true
            meters.levels = SignalLevels(input: [SignalChannelLevel(label: "Left", rmsDB: -32, peakDB: -12), SignalChannelLevel(label: "Right", rmsDB: -28, peakDB: -8)], output: [SignalChannelLevel(label: "Left", rmsDB: -42, peakDB: -22), SignalChannelLevel(label: "Right", rmsDB: -40, peakDB: -20), SignalChannelLevel(label: "Sub Left", rmsDB: -48, peakDB: -24), SignalChannelLevel(label: "Sub Right", rmsDB: -48, peakDB: -24)])
            panel.metersPanel.render(meters)
            let size = panel.measureNaturalSize()
            window.setContentSize(size); panel.setFrameSize(size); panel.layoutSubtreeIfNeeded()
            guard let image = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { throw SwitcherError.message("Unable to render Main Volume panel") }
            panel.cacheDisplay(in: panel.bounds, to: image)
            if let data = image.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("main-live-levels-" + appearance.rawValue + ".png")) }
            window.close()
        }
    }

}
