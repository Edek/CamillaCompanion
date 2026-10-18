import AppKit
import AutoAudioCore
import AutoAudioPlatform

/// Synthetic native-view regression scenarios. These never connect to DSP.
@MainActor enum AuxFaderDisplayVerification {
    static func samples() -> [String: [Int: Double]] {
        _ = NSApplication.shared
        let panel = AuxFaderPanel(frame: .zero)
        var state = AuxFaderSnapshot(profileID: "fixture", faders: [
            AuxFader(id: 1, name: "Left", volumeDB: 0, muted: false, maximumDB: 0),
            AuxFader(id: 2, name: "Right", volumeDB: -3, muted: false, maximumDB: 0)
        ], preferences: AuxPreferences(visibleIDs: [1, 2], linkGroups: [[1, 2]]), ready: true)
        panel.render(state)
        panel.commitVolume(id: 1, db: -18, profileID: "fixture")
        var result = ["pending": panel.displayedVolumes]
        state.busy = true
        panel.render(state)
        result["old-busy"] = panel.displayedVolumes
        state.busy = false
        state.faders[0].volumeDB = -17.8; state.faders[1].volumeDB = -20.8
        panel.render(state)
        result["confirmed"] = panel.displayedVolumes
        panel.commitVolume(id: 1, db: -24, profileID: "fixture")
        state.ready = false
        panel.render(state)
        result["readiness-lost"] = panel.displayedVolumes
        state.ready = true
        panel.render(state)
        panel.commitVolume(id: 1, db: -24, profileID: "fixture")
        state.busy = true
        panel.render(state)
        state.busy = false; state.error = "A member failed"
        state.faders[0].volumeDB = -24
        panel.render(state)
        result["partial-failure"] = panel.displayedVolumes
        panel.commitVolume(id: 1, db: -30, profileID: "fixture")
        state.profileID = "different"
        state.faders[0].volumeDB = 0; state.faders[1].volumeDB = 0
        panel.render(state)
        result["profile-changed"] = panel.displayedVolumes
        return result
    }
    static func interactionChecks() -> [String: Bool] {
        _ = NSApplication.shared
        let panel = AuxFaderPanel(frame: .zero)
        var state = AuxFaderSnapshot(profileID: "fixture", faders: [
            AuxFader(id: 1, name: "Left", volumeDB: 0, muted: false, maximumDB: 0),
            AuxFader(id: 2, name: "Right", volumeDB: -3, muted: false, maximumDB: 0)
        ], preferences: AuxPreferences(visibleIDs: [1, 2], linkGroups: [[1, 2]]), ready: true)
        var volumeWrites = 0
        var muteWrites = 0
        panel.onVolume = { _, _, _, _ in volumeWrites += 1 }
        panel.onMute = { _, _, _, _ in muteWrites += 1 }
        panel.render(state)
        panel.expand()
        let idleEnabled = panel.enabledControls
        var result = AuxSliderAppearanceVerification.checks()
        result["rounded-red-mute"] = panel.muteButtonStyles.values.allSatisfy { $0 }
        result["expanded-by-default"] = panel.isExpanded
        // Dispatch the native header action, then publish a value-only update.
        if let disclosure = panel.subviews.compactMap({ $0 as? NSStackView }).first?.arrangedSubviews.compactMap({ $0 as? NSButton }).first {
            disclosure.performClick(nil)
            state.faders[0].volumeDB = -1
            panel.render(state)
            result["collapsed-session-update"] = !panel.isExpanded
            state.faders[0].volumeDB = 0
            panel.render(state)
            panel.expand()
        } else { result["collapsed-session-update"] = false }
        panel.commitVolume(id: 1, db: -7, profileID: "fixture")
        panel.commandRejected()
        result["explicit-rejection-clears-pending"] = panel.displayedVolumes == [1: 0, 2: -3]
        volumeWrites = 0
        panel.commitVolume(id: 1, db: -18, profileID: "fixture")
        result["pending-enabled"] = panel.enabledControls == idleEnabled
        panel.commitVolume(id: 1, db: -30, profileID: "fixture")
        result["pending-input-rejected"] = volumeWrites == 1 && panel.displayedVolumes[1] == -18
        state.busy = true
        result["busy-no-reflow"] = !panel.render(state)
        result["busy-enabled"] = panel.enabledControls == idleEnabled
        panel.commitVolume(id: 1, db: -36, profileID: "fixture")
        panel.commitMute(id: 1, profileID: "fixture")
        result["busy-input-rejected"] = volumeWrites == 1 && muteWrites == 0 && panel.displayedVolumes[1] == -18
        state.busy = false
        state.faders[0].volumeDB = -18; state.faders[1].volumeDB = -21
        panel.render(state)
        result["confirmed-enabled"] = panel.enabledControls == idleEnabled
        panel.commitMute(id: 1, profileID: "fixture")
        result["active-red-mute"] = panel.muteButtonStyles.values.allSatisfy { $0 }
        result["pending-mute"] = panel.displayedMuteStates == [1: 1, 2: 1] && muteWrites == 1
        state.busy = true
        panel.render(state)
        result["busy-mute"] = panel.displayedMuteStates == [1: 1, 2: 1] && panel.enabledControls == idleEnabled
        state.busy = false
        state.error = "Synthetic partial mute failure"
        state.faders[0].muted = true
        panel.render(state)
        result["mixed-mute-confirmation"] = panel.displayedMuteStates == [1: -1, 2: -1]
        result["mixed identifies muted channel only"] = panel.muteTextColors[1] == AudioMuteButton.activeFill && panel.muteTextColors[2] == .labelColor
        result["mixed accessibility identifies each channel"] = panel.muteAccessibilityValues[1]?.hasPrefix("Muted;") == true && panel.muteAccessibilityValues[2]?.hasPrefix("Unmuted;") == true
        state.faders[0].muted = false; state.faders[1].muted = true
        panel.render(state)
        result["mixed color follows opposite channel readback"] = panel.displayedMuteStates == [1: -1, 2: -1] && panel.muteTextColors[1] == .labelColor && panel.muteTextColors[2] == AudioMuteButton.activeFill
        state.faders[1].muted = false
        state.preferences.linkMutes = false
        state.faders[0].muted = false
        state.error = nil
        panel.render(state)
        panel.commitMute(id: 1, profileID: "fixture")
        result["independent-mute"] = panel.displayedMuteStates == [1: 1, 2: 0] && muteWrites == 2
        state.ready = false
        panel.render(state)
        result["lifecycle-disabled"] = panel.enabledControls.values.allSatisfy { $0.allSatisfy { !$0 } }
        state.ready = true
        state.preferences.linkGroups = [[1, 3]]
        panel.render(state)
        result["missing-volume-member-independent-mute"] = panel.enabledControls[1] == [false, true, false]
        result.merge(mixedMuteRasterChecks(), uniquingKeysWith: { _, newest in newest })
        return result
    }

    private static func mixedMuteRasterChecks() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var redCounts: [Bool: Int] = [:]
            for muted in [false, true] {
                let button = AudioMuteButton(frame: NSRect(x: 0, y: 0, width: 54, height: 24))
                button.appearance = NSAppearance(named: appearance)
                AudioControlStyle.configureRounded(button)
                button.setButtonType(.pushOnPushOff); button.allowsMixedState = true
                button.state = .mixed; button.channelMuted = muted
                result["Mixed raster preserves native tri-state " + appearance.rawValue + " muted " + String(muted)] = button.state == .mixed && button.displayedTitle == "Mixed"
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 54, pixelsHigh: 24,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                context.cgContext.clear(button.bounds)
                button.effectiveAppearance.performAsCurrentDrawingAppearance { button.draw(button.bounds) }
                NSGraphicsContext.restoreGraphicsState()
                var count = 0
                for y in 0..<24 { for x in 0..<54 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.5 && color.redComponent > 0.3 && color.redComponent > color.greenComponent * 1.8 && color.redComponent > color.blueComponent * 1.4 { count += 1 }
                } }
                redCounts[muted] = count
            }
            result["Mixed raster red only on muted channel " + appearance.rawValue] = (redCounts[true] ?? 0) > 10 && redCounts[false] == 0
        }
        return result
    }

    static func trimScaleChecks() async -> [String: Bool] {
        _ = NSApplication.shared
        let panel = AuxFaderPanel(frame: .zero)
        let transport = NativeDragTransport()
        transport.faders = [AuxFader(id: 1, name: "Left", volumeDB: 0, muted: false, maximumDB: 0),
                            AuxFader(id: 2, name: "Right", volumeDB: 0, muted: false, maximumDB: 0),
                            AuxFader(id: 3, name: "Hidden", volumeDB: -12, muted: false, maximumDB: -8)]
        let controller = AuxController(transport: transport, loadPreferences: { _ in
            AuxPreferences(visibleIDs: [1, 2], linkGroups: [[1, 2, 3]])
        }, savePreferences: { _, _ in })
        let profile = Profile(id: "fixture", name: "Fixture", triggerUID: "trigger", captureUID: "capture",
                              playbackUID: "playback", launchAgentLabel: "fixture", launchAgentPath: "/unused",
                              websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
        controller.onChange = { panel.render($0) }
        controller.activate(profile: profile)
        await controller.refresh()
        let leftField = panel.preciseField(id: 1)
        var result: [String: Bool] = [:]
        do {
            let trim = try await controller.prepareVolumeChange(id: 1, db: -6)
            _ = try await controller.applyVolumeChange(proposal: trim, intent: .individual)
            result["typed-trim-number-and-knob"] = panel.displayedVolumes == [1: -6, 2: 0] &&
                abs((panel.sliderPositions[1] ?? 0) - AuxFaderScale().position(for: -6)) < 1e-10 && panel.sliderPositions[2] == 1
            result["trim-keeps-links-hidden-member-and-row"] = controller.snapshot.preferences.linkGroups == [[1, 2, 3]] &&
                transport.faders[2].volumeDB == -12 && leftField === panel.preciseField(id: 1)
            let group = try await controller.prepareVolumeChange(id: 1, db: -12)
            _ = try await controller.applyVolumeChange(proposal: group, intent: .group)
            result["group-retains-trimmed-offsets"] = transport.faders.map(\.volumeDB) == [-12, -6, -18] &&
                abs((panel.sliderPositions[1] ?? 0) - AuxFaderScale().position(for: -12)) < 1e-10
            transport.faders[2].volumeDB = -8
            try await controller.refreshForUser()
            panel.onVolume = { id, db, _, intent in Task { await controller.changeVolume(id: id, db: db, intent: intent) } }
            panel.commitVolume(id: 1, db: -1, profileID: "fixture")
            for _ in 0..<100 { await Task.yield() }
            result["hidden-bound-clamps-command-with-stable-knob"] = transport.faders.map(\.volumeDB) == [-12, -6, -8] &&
                abs((panel.sliderPositions[1] ?? 0) - AuxFaderScale().position(for: -12)) < 1e-10
            let writes = transport.writes
            transport.faders[0].volumeDB = -24
            try await controller.refreshForUser()
            result["external-trim-refresh-no-rescale-or-write"] = transport.writes == writes &&
                panel.displayedVolumes == [1: -24, 2: -6] &&
                abs((panel.sliderPositions[1] ?? 0) - AuxFaderScale().position(for: -24)) < 1e-10 && leftField === panel.preciseField(id: 1)
        } catch { result["trim-workflow-completed"] = false }
        controller.onChange = nil
        return result
    }

    static func liveDragChecks() async -> [String: Bool] {
        _ = NSApplication.shared
        let panel = AuxFaderPanel(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = host
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            panel.topAnchor.constraint(equalTo: host.topAnchor, constant: 12)
        ])
        let transport = NativeDragTransport()
        let controller = AuxController(transport: transport, loadPreferences: { _ in
            AuxPreferences(visibleIDs: [1, 2], linkGroups: [[1, 2, 3]])
        }, savePreferences: { _, _ in })
        let profile = Profile(id: "fixture", name: "Fixture", triggerUID: "trigger", captureUID: "capture",
                              playbackUID: "playback", launchAgentLabel: "fixture", launchAgentPath: "/unused",
                              websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
        controller.onChange = { state in panel.render(state) }
        panel.onVolume = { id, db, _, intent in Task { await controller.changeVolume(id: id, db: db, intent: intent) } }
        panel.onPreciseVolume = { id, db, _ in Task {
            do {
                let proposal = try await controller.prepareVolumeChange(id: id, db: db)
                _ = try await controller.applyVolumeChange(proposal: proposal, intent: .group)
            } catch { panel.commandRejected() }
        } }
        panel.onVolumeDragBegin = { id, _, intent in controller.beginVolumeDrag(id: id, intent: intent) }
        panel.onVolumeDragUpdate = { id, db, _ in controller.updateVolumeDrag(id: id, db: db) }
        var finalRequested: Double?
        panel.onVolumeDragEnd = { id, db, _ in
            finalRequested = db
            controller.endVolumeDrag(id: id, db: db)
        }
        panel.onVolumeDragCancel = { controller.cancelVolumeDrag() }
        controller.activate(profile: profile)
        await controller.refresh()
        panel.expand(); host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        panel.simulateVolumePointer(id: 1, type: .leftMouseDown, db: -20)
        var result = ["knob-grab-preserves-gain": panel.displayedVolumes == [1: -20, 2: -25] && transport.writes == 0]
        panel.simulateVolumePointer(id: 1, type: .leftMouseDragged, db: -30)
        result["linked-preview"] = abs((panel.displayedVolumes[1] ?? 0) + 30) < 1e-8 && abs((panel.displayedVolumes[2] ?? 0) + 35) < 1e-8
        for _ in 0..<100 where transport.writes == 0 { await Task.yield() }
        result["native-audio-before-release"] = transport.writes > 0 && controller.snapshot.busy
        panel.simulateVolumePointer(id: 1, type: .leftMouseDragged, db: -38)
        let latest = panel.displayedVolumes
        var older = controller.snapshot
        older.faders[0].volumeDB = -30; older.faders[1].volumeDB = -35
        panel.render(older)
        result["older-readback-retains-latest"] = panel.displayedVolumes == latest
        panel.simulateVolumePointer(id: 1, type: .leftMouseUp, db: -37.125)
        while controller.snapshot.busy { await Task.yield() }
        result["exact-final-flush"] = abs(transport.faders[0].volumeDB + 37.125) < 1e-8 && abs(transport.faders[2].volumeDB + 27.125) < 1e-8
        if result["exact-final-flush"] == false {
            print("Aux final-flush diagnostic: requested=\(String(describing: finalRequested)), actual=\(transport.faders.map(\.volumeDB)), displayed=\(panel.displayedVolumes), error=\(String(describing: controller.snapshot.error))")
        }
        result["precise-invalid-rejected"] = !panel.submitPreciseValue(id: 1, text: "NaN") && !(panel.preciseEntryErrors[1] ?? "").isEmpty
        let writesBeforeEscape = transport.writes
        panel.restorePreciseValue(id: 1)
        result["precise-escape-restores"] = panel.preciseEntryErrors[1] == "" && transport.writes == writesBeforeEscape
        result["precise-value-accepted"] = panel.submitPreciseValue(id: 1, text: "-28.75")
        for _ in 0..<100 { await Task.yield() }
        result["precise-linked-exact"] = transport.faders.map(\.volumeDB) == [-28.75, -33.75, -18.75]
        let writesBeforeRefresh = transport.writes
        transport.faders[0].volumeDB = -19; transport.faders[1].volumeDB = -27
        transport.faders[2].volumeDB = -15; transport.faders[0].muted = true
        transport.faders[2].maximumDB = -10
        try? await controller.refreshForUser()
        let expectedPositions: [Int: Double] = [
            1: AuxFaderScale(minimumDB: -150, maximumDB: 0).position(for: -19),
            2: AuxFaderScale(minimumDB: -150, maximumDB: 0).position(for: -27)
        ]
        result["external-refresh-actual-slider"] = panel.sliderPositions.allSatisfy { id, position in abs(position - (expectedPositions[id] ?? -1)) < 1e-10 }
        result["external-refresh-no-writes"] = transport.writes == writesBeforeRefresh && panel.displayedVolumes == [1: -19, 2: -27]
        var floorPreferences = controller.snapshot.preferences
        floorPreferences.sliderMinimumDB = -60
        try? controller.setPreferences(floorPreferences)
        transport.faders[0].volumeDB = -100; transport.faders[1].volumeDB = -108; transport.faders[2].volumeDB = -96
        try? await controller.refreshForUser()
        result["below-floor-true-value-pinned"] = panel.displayedVolumes == [1: -100, 2: -108] && panel.sliderPositions == [1: 0, 2: 0]
        let floorWrites = transport.writes
        host.layoutSubtreeIfNeeded()
        panel.simulateVolumePointer(id: 1, type: .leftMouseDown, db: -100)
        panel.simulateVolumePointer(id: 1, type: .leftMouseUp, db: -100)
        while controller.snapshot.busy { await Task.yield() }
        result["below-floor-grab-release-no-write"] = transport.writes == floorWrites && panel.displayedVolumes[1] == -100
        panel.simulateVolumePointer(id: 1, type: .leftMouseDown, db: -100)
        panel.simulateVolumePointer(id: 1, type: .leftMouseDragged, db: -99.8)
        result["below-floor-tiny-drag-continuous"] = abs((panel.displayedVolumes[1] ?? 0) + 99.8) < 1e-7
        panel.simulateVolumePointer(id: 1, type: .leftMouseUp, db: -99.8)
        while controller.snapshot.busy { await Task.yield() }
        result["below-floor-drag-readback"] = abs(transport.faders[0].volumeDB + 99.8) < 1e-7 && panel.sliderPositions[1] == 0
        // Exercise the owned AppKit field editor, including replacement and native
        // Return/Escape delegate dispatch. No global shortcut is installed.
        if let field = panel.preciseField(id: 1), window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView {
            editor.breakUndoCoalescing()
            editor.undoManager?.removeAllActions()
            let writesBeforeSelection = transport.writes
            if let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) {
                let handled = field.performKeyEquivalent(with: selectAll)
                result["native-command-a-select-all"] = handled && editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count) && transport.writes == writesBeforeSelection
                editor.insertText("-87.25", replacementRange: editor.selectedRange())
                result["native-selection-replacement"] = editor.string == "-87.25"
                editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                result["native-escape-no-write"] = transport.writes == writesBeforeSelection && abs((panel.displayedVolumes[1] ?? 0) + 99.8) < 1e-7
            }
        } else { result["native-command-a-select-all"] = false }
        if let field = panel.preciseField(id: 1), window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView {
            editor.breakUndoCoalescing()
            editor.undoManager?.removeAllActions()
            editor.selectAll(nil)
            editor.insertText("-88.5", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            for _ in 0..<100 { await Task.yield() }
            result["native-return-precise-commit"] = abs(transport.faders[0].volumeDB + 88.5) < 1e-7
        } else { result["native-return-precise-commit"] = false }
        let reads = transport.reads
        for _ in 0..<100 { await Task.yield() }
        result["native-idle-no-polling"] = transport.reads == reads
        controller.onChange = nil
        window.contentView = nil
        result.merge(await shiftGestureChecks(), uniquingKeysWith: { _, newest in newest })
        return result
    }

    private static func shiftGestureChecks() async -> [String: Bool] {
        let panel = AuxFaderPanel(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = host; host.addSubview(panel)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                                     panel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
                                     panel.topAnchor.constraint(equalTo: host.topAnchor, constant: 12)])
        let transport = NativeDragTransport()
        let preferences = AuxPreferences(visibleIDs: [1, 2], linkGroups: [[1, 2, 3]])
        let controller = AuxController(transport: transport, loadPreferences: { _ in preferences }, savePreferences: { _, _ in })
        let profile = Profile(id: "fixture", name: "Fixture", triggerUID: "trigger", captureUID: "capture",
                              playbackUID: "playback", launchAgentLabel: "fixture", launchAgentPath: "/unused",
                              websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
        controller.onChange = { panel.render($0) }
        panel.onVolume = { id, db, _, intent in Task { await controller.changeVolume(id: id, db: db, intent: intent) } }
        panel.onMute = { id, muted, _, intent in Task { await controller.setMute(id: id, muted: muted, intent: intent) } }
        var beginIntent: AuxVolumeIntent?
        panel.onVolumeDragBegin = { id, _, intent in beginIntent = intent; return controller.beginVolumeDrag(id: id, intent: intent) }
        panel.onVolumeDragUpdate = { id, db, _ in controller.updateVolumeDrag(id: id, db: db) }
        panel.onVolumeDragEnd = { id, db, _ in controller.endVolumeDrag(id: id, db: db) }
        panel.onVolumeDragCancel = { controller.cancelVolumeDrag() }
        controller.activate(profile: profile); await controller.refresh()
        func matchesVolumes(_ expected: [Double]) -> Bool {
            transport.faders.count == expected.count && zip(transport.faders.map(\.volumeDB), expected).allSatisfy { abs($0.0 - $0.1) < 1e-7 }
        }
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let names = panel.displayedNames, fitting = panel.fittingSize
        panel.simulateVolumePointer(id: 1, type: .leftMouseDown, db: -20, modifiers: .shift)
        panel.simulateVolumePointer(id: 1, type: .leftMouseDragged, db: -30)
        var result = ["Shift native preview trims only grabbed Aux": beginIntent == .individual &&
            abs((panel.displayedVolumes[1] ?? 0) + 30) < 1e-8 && panel.displayedVolumes[2] == -25,
            "Shift trim keeps row names and layout": panel.displayedNames == names && panel.fittingSize == fitting]
        // Releasing Shift during a gesture cannot start moving other members.
        panel.simulateVolumePointer(id: 1, type: .leftMouseUp, db: -32.5)
        while controller.snapshot.busy { await Task.yield() }
        result["Shift gesture scope remains latched after modifier release"] = matchesVolumes([-32.5, -25, -10])
            && controller.snapshot.preferences == preferences
        panel.simulateVolumePointer(id: 1, type: .leftMouseDown, db: -32.5)
        panel.simulateVolumePointer(id: 1, type: .leftMouseDragged, db: -42.5, modifiers: .shift)
        panel.simulateVolumePointer(id: 1, type: .leftMouseUp, db: -42.5, modifiers: .shift)
        while controller.snapshot.busy { await Task.yield() }
        result["Normal drag retains group scope and newly trimmed offsets"] = beginIntent == .group &&
            matchesVolumes([-42.5, -35, -20])
        let beforeTrackClick = transport.faders.map(\.volumeDB)
        panel.simulateVolumePointer(id: 1, type: .leftMouseDown, db: -20, modifiers: .shift)
        panel.simulateVolumePointer(id: 1, type: .leftMouseUp, db: -20, modifiers: .shift)
        while controller.snapshot.busy { await Task.yield() }
        result["Shift track click affects one Aux"] = abs(transport.faders[0].volumeDB + 20) < 1e-8 &&
            transport.faders[1].volumeDB == beforeTrackClick[1] && transport.faders[2].volumeDB == beforeTrackClick[2]
        let beforeKeyboard = transport.faders.map(\.volumeDB)
        panel.simulateVolumeKey(id: 1, modifiers: .shift)
        for _ in 0..<100 { await Task.yield() }
        while controller.snapshot.busy { await Task.yield() }
        result["Shift native arrow action trims only focused Aux"] = transport.faders[0].volumeDB != beforeKeyboard[0] &&
            transport.faders[1].volumeDB == beforeKeyboard[1] && transport.faders[2].volumeDB == beforeKeyboard[2]
        let beforeNormalKeyboard = transport.faders.map(\.volumeDB)
        panel.simulateVolumeKey(id: 1)
        for _ in 0..<100 { await Task.yield() }
        while controller.snapshot.busy { await Task.yield() }
        let keyboardDelta = transport.faders[0].volumeDB - beforeNormalKeyboard[0]
        result["Normal native arrow action keeps linked movement"] = keyboardDelta > 0 &&
            zip(transport.faders.map(\.volumeDB), beforeNormalKeyboard).allSatisfy {
                abs(($0.0 - $0.1) - keyboardDelta) < 1e-7
            }
        if result["Shift native arrow action trims only focused Aux"] != true ||
            result["Normal native arrow action keeps linked movement"] != true {
            print("Aux arrow fixture levels: before Shift \(beforeKeyboard), before ordinary \(beforeNormalKeyboard), after \(transport.faders.map(\.volumeDB)); ready \(controller.snapshot.ready), busy \(controller.snapshot.busy), error \(controller.snapshot.error ?? "none")")
        }
        transport.faders[0].muted = true; transport.faders[1].muted = false; transport.faders[2].muted = false
        await controller.refresh()
        panel.simulateMuteActivation(id: 1, modifiers: .shift)
        for _ in 0..<100 { await Task.yield() }
        while controller.snapshot.busy { await Task.yield() }
        result["Shift mute uses clicked raw state instead of mixed group"] = transport.faders.allSatisfy { !$0.muted } &&
            controller.snapshot.preferences == preferences
        panel.simulateMuteActivation(id: 2, modifiers: .shift)
        for _ in 0..<100 { await Task.yield() }
        while controller.snapshot.busy { await Task.yield() }
        result["Shift mute preserves other and hidden members"] = transport.faders.map(\.muted) == [false, true, false]
            && panel.displayedMuteStates == [1: -1, 2: -1]
        result["Shift mute red text identifies only clicked muted channel"] = panel.muteTextColors[1] == .labelColor && panel.muteTextColors[2] == AudioMuteButton.activeFill
        panel.simulateMuteActivation(id: 1)
        for _ in 0..<100 { await Task.yield() }
        while controller.snapshot.busy { await Task.yield() }
        result["Normal mute retains linked behavior after Shift mute"] = transport.faders.allSatisfy(\.muted)
        result["Normal group mute retains white active labels"] = panel.muteTextColors[1] == .white && panel.muteTextColors[2] == .white
        controller.onChange = nil; window.contentView = nil; window.close()
        return result
    }

}

@MainActor private final class NativeDragTransport: AuxDSPTransport {
    var faders = [AuxFader(id: 1, name: "Left", volumeDB: -20, muted: false, maximumDB: 0),
                  AuxFader(id: 2, name: "Right", volumeDB: -25, muted: false, maximumDB: 0),
                  AuxFader(id: 3, name: "Hidden", volumeDB: -10, muted: false, maximumDB: -8)]
    var writes = 0
    var reads = 0
    func read(profile: Profile) async throws -> AuxDSPState { reads += 1; return AuxDSPState(faders: faders) }
    func setVolume(id: Int, db: Double) async throws {
        writes += 1
        if let index = faders.firstIndex(where: { $0.id == id }) { faders[index].volumeDB = db }
    }
    func setMute(id: Int, muted: Bool) async throws {
        writes += 1
        if let index = faders.firstIndex(where: { $0.id == id }) { faders[index].muted = muted }
    }
    func cancel() {}
}
