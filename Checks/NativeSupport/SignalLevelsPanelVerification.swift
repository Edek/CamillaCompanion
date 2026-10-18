#if canImport(AppKit)
import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class SignalMeterVerificationWindow: NSWindow, AudioFocusVerificationWindow {
    var focusedForVerification = true
}

/// Finite fixture for the grouped native meter layout, without reading any DSP.
@MainActor enum SignalLevelsPanelVerification {
    static func emptyOfflineSectionsStayCompact() -> Bool {
        _ = NSApplication.shared
        let meters = SignalLevelsPanel(frame: .zero)
        let aux = AuxFaderPanel(frame: .zero)
        aux.presentsStatusFeedbackLocally = false
        let sections = NSStackView(views: [meters, aux])
        sections.orientation = .vertical; sections.alignment = .leading; sections.spacing = 8
        sections.widthAnchor.constraint(equalToConstant: 356).isActive = true
        for section in [meters as NSView, aux] { section.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 300), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sections
        defer { window.contentView = nil; window.close() }
        func measure() -> (CGFloat, CGFloat) {
            sections.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 356, height: max(1, sections.fittingSize.height)))
            sections.layoutSubtreeIfNeeded()
            return (meters.fittingSize.height, aux.fittingSize.height)
        }
        guard let meterStack = meters.subviews.compactMap({ $0 as? NSStackView }).first,
              let meterHeader = meterStack.arrangedSubviews.first as? NSStackView,
              let retry = meterHeader.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Retry" }),
              let auxStack = aux.subviews.compactMap({ $0 as? NSStackView }).first,
              let auxBody = auxStack.arrangedSubviews.last as? NSStackView else { return false }
        var meter = SignalLevelsSnapshot(); meter.enabled = true; meter.error = "DSP offline"
        var faders = AuxFaderSnapshot(profileID: "cold", preferences: AuxPreferences(visibleIDs: [1]), error: "DSP offline")
        meters.setReadingContext(profileID: "cold", ready: false)
        guard meters.render(meter), aux.render(faders) else { return false }
        let cold = measure()
        guard meters.body.isHidden, auxBody.isHidden, aux.isExpanded,
              meters.disclosureForVerification.accessibilityValue() as? String == "Expanded",
              aux.disclosureForVerification.accessibilityValue() as? String == "Expanded",
              meterStack.arrangedSubviews.filter({ !$0.isHidden }).count == 1,
              !retry.isHidden, abs(cold.0 - AudioControlStyle.disclosureHeight) < 1,
              abs(meterHeader.frame.height - AudioControlStyle.disclosureHeight) < 1,
              abs(aux.disclosureForVerification.frame.height - AudioControlStyle.disclosureHeight) < 1 else { return false }
        var retryCount = 0
        meters.onRetry = { retryCount += 1 }
        retry.performClick(nil)
        guard retryCount == 1, !meters.render(meter), !aux.render(faders) else { return false }
        meter.error = nil
        guard meters.render(meter) else { return false }
        let waiting = measure()
        guard meters.body.isHidden, retry.isHidden, waiting.0 > cold.0, waiting.0 < cold.0 + 30 else { return false }
        meter.error = "Retry failed"
        guard meters.render(meter) else { return false }
        let afterRetry = measure()
        guard afterRetry.0 == cold.0, afterRetry.1 == cold.1 else { return false }

        // Previously observed rows retain their native fitting geometry on loss.
        meters.setReadingContext(profileID: "cold", ready: true)
        meter.error = nil
        meter.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -24, peakDB: -6)],
            output: [.init(label: "Output", rmsDB: -18, peakDB: -3)])
        faders.ready = true; faders.error = nil
        faders.faders = [.init(id: 1, name: "Known Aux", volumeDB: -12, muted: false, maximumDB: 0)]
        guard meters.render(meter), aux.render(faders) else { return false }
        let known = measure()
        let meterRows = meters.rowIdentities
        let auxRows = auxBody.arrangedSubviews.filter { $0 is NSStackView }.map(ObjectIdentifier.init)
        let volumes = aux.displayedVolumes
        guard known.0 > cold.0, known.1 > cold.1 else { return false }
        meters.setReadingContext(profileID: "cold", ready: false)
        meter.levels = nil; meter.error = "Interface disconnected"
        faders.ready = false; faders.error = "Interface disconnected"
        guard !meters.render(meter), !aux.render(faders) else { return false }
        let disconnected = measure()
        guard disconnected.0 == known.0, disconnected.1 == known.1,
              meters.rowIdentities == meterRows, meters.body.alphaValue < 1,
              meters.numericAvailability.allSatisfy({ !$0 }),
              auxBody.arrangedSubviews.filter({ $0 is NSStackView }).map(ObjectIdentifier.init) == auxRows,
              auxBody.arrangedSubviews.filter({ $0 is NSStackView }).allSatisfy({ $0.alphaValue < 1 }),
              aux.displayedVolumes == volumes, aux.enabledControls.values.allSatisfy({ $0.allSatisfy({ !$0 }) }) else { return false }

        var auxLayoutChanges = 0
        aux.onLayout = { auxLayoutChanges += 1 }
        meters.onToggle = { enabled in meter.enabled = enabled; meters.render(meter) }
        aux.disclosureForVerification.performClick(nil)
        let auxCollapsed = measure()
        guard auxLayoutChanges == 1, !aux.isExpanded, auxCollapsed.0 == known.0, auxCollapsed.1 == cold.1 else { return false }
        meters.disclosureForVerification.performClick(nil)
        let bothCollapsed = measure()
        guard bothCollapsed.0 == cold.0, bothCollapsed.1 == cold.1 else { return false }
        meters.disclosureForVerification.performClick(nil)
        let metersExpanded = measure()
        guard metersExpanded.0 == known.0, metersExpanded.1 == cold.1, !aux.isExpanded else { return false }
        aux.disclosureForVerification.performClick(nil)
        let bothExpanded = measure()
        guard auxLayoutChanges == 2, bothExpanded.0 == known.0, bothExpanded.1 == known.1 else { return false }

        // A new offline profile has no remembered rows. Expanding it never
        // exposes a stretchable empty stack or a blank status label.
        meters.setReadingContext(profileID: "new-offline", ready: false)
        faders.profileID = "new-offline"; faders.faders = []
        guard meters.render(meter), aux.render(faders) else { return false }
        let newOffline = measure()
        guard newOffline.0 == cold.0, newOffline.1 == cold.1, meters.body.isHidden, auxBody.isHidden else { return false }
        aux.collapse(); aux.expand()
        meters.disclosureForVerification.performClick(nil); meters.disclosureForVerification.performClick(nil)
        let emptyReopened = measure()
        return emptyReopened.0 == cold.0 && emptyReopened.1 == cold.1 && aux.isExpanded
            && meters.body.isHidden && auxBody.isHidden && !window.isVisible
    }

    static func savedModeChangesResetHistoryWithoutCallbacks() -> Bool {
        let panel = SignalLevelsPanel(frame: .zero)
        var requests: [SignalMeterNumericMode] = []
        panel.onNumericModeChange = { requests.append($0) }
        var snapshot = SignalLevelsSnapshot(); snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -20, peakDB: -3)], output: [])
        panel.render(snapshot)
        let rows = panel.rowIdentities
        panel.clickNumericHeading()
        guard requests == [.peakHold], panel.numericModeCaption == "Realtime" else { return false }
        panel.setNumericMode(.peakHold)
        snapshot.levels?.input[0].peakDB = -30
        panel.render(snapshot)
        panel.clickNumericReading(at: 0)
        guard requests == [.peakHold, .realtime], panel.numericModeCaption == "Peak Hold",
              panel.numericPeaks == ["-3.0"] else { return false }
        panel.setNumericMode(.realtime)
        guard panel.numericPeaks == ["-30.0"], panel.rowIdentities == rows else { return false }
        panel.setNumericMode(.peakHold)
        panel.setNumericMode(.peakHold)
        snapshot.levels?.input[0].peakDB = -40
        panel.render(snapshot)
        guard panel.numericPeaks == ["-30.0"], requests == [.peakHold, .realtime] else { return false }
        snapshot.enabled = false; panel.render(snapshot)
        snapshot.enabled = true; snapshot.levels?.input[0].peakDB = -60; panel.render(snapshot)
        return panel.numericModeCaption == "Peak Hold" && panel.numericPeaks == ["-60.0"]
            && requests == [.peakHold, .realtime]
    }

    static func disclosureControlsReadingPreference() -> Bool {
        _ = NSApplication.shared
        let previous = AudioControlStyle.keepActiveColors
        defer { AudioControlStyle.keepActiveColors = previous }
        let panel = SignalLevelsPanel(frame: NSRect(x: 0, y: 0, width: 356, height: 300))
        let window = SignalMeterVerificationWindow(contentRect: panel.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.contentView = nil; window.close() }
        var snapshot = SignalLevelsSnapshot()
        snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Left", rmsDB: -24, peakDB: -6)], output: [])
        var changes: [Bool] = []
        panel.onToggle = { enabled in
            changes.append(enabled); snapshot.enabled = enabled; panel.render(snapshot)
        }
        panel.render(snapshot)
        for focused in [true, false] {
            window.focusedForVerification = focused
            for keepColors in [false, true] {
                AudioControlStyle.keepActiveColors = keepColors
                panel.refreshFocusAppearance()
                guard panel.disclosureForVerification.contentTintColor == (focused || keepColors ? NSColor.labelColor : NSColor.secondaryLabelColor),
                      panel.disclosureForVerification.accessibilityValue() as? String == "Expanded",
                      panel.metersVisible else { return false }
                panel.disclosureForVerification.performClick(nil)
                guard changes.last == false, !panel.metersVisible,
                      panel.disclosureForVerification.accessibilityValue() as? String == "Collapsed" else { return false }
                panel.disclosureForVerification.performClick(nil)
                guard changes.last == true, panel.metersVisible else { return false }
            }
        }
        return changes == [false, true, false, true, false, true, false, true] && !window.isVisible
    }

    static func warningCaptionsAndBelowRangeNumbers() -> Bool {
        let savedKeepActiveColors = AudioControlStyle.keepActiveColors
        AudioControlStyle.keepActiveColors = false
        defer { AudioControlStyle.keepActiveColors = savedKeepActiveColors }
        _ = NSApplication.shared
        let panel = SignalLevelsPanel(frame: NSRect(x: 0, y: 0, width: 388, height: 320))
        let window = SignalMeterVerificationWindow(contentRect: panel.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.contentView = nil; window.close() }
        var snapshot = SignalLevelsSnapshot(); snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Floor", rmsDB: -1000, peakDB: -1000)],
                                      output: [.init(label: "Clipped", rmsDB: -6, peakDB: 2)])
        panel.render(snapshot)
        let measurements = panel.displayedMeterValues
        guard panel.numericPeaks == ["<−96", "2.0"], panel.clippedNumericPeaks == [false, true] else { return false }
        let ids = panel.rowIdentities
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: name)
            for focused in [true, false] {
                window.focusedForVerification = focused
                for keepActive in [false, true, false] {
                    AudioControlStyle.keepActiveColors = keepActive
                    let mode = panel.numericModeCaption, values = panel.displayedMeterValues
                    panel.refreshFocusAppearance()
                    guard AudioControlStyle.windowIsActive(window) == focused,
                          panel.numericModeCaption == mode, panel.displayedMeterValues == values,
                          panel.numericModeCaption == "Realtime",
                          panel.numericCaptionMatches(active: focused || keepActive) else { return false }
                    panel.clickNumericHeading()
                    guard panel.numericModeCaption == "Peak Hold",
                          panel.numericCaptionMatches(active: focused || keepActive),
                          panel.numericPeaks == ["<−96", "2.0"], panel.clippedNumericPeaks == [false, true] else { return false }
                    panel.clickNumericHeading()
                }
            }
        }
        panel.setDisplayRange(minimumDB: -120, maximumDB: 6)
        guard panel.numericPeaks == ["<−120", "2.0"], panel.displayedMeterValues == measurements,
              panel.rowIdentities == ids else { return false }
        snapshot.levels?.input[0].peakDB = -120
        panel.render(snapshot)
        return panel.numericPeaks == ["-120.0", "2.0"] && panel.displayedMeterValues[0][0] == -1000
    }

    static func completeDisplayActivatesOnce() -> Bool {
        _ = NSApplication.shared
        let panel = SignalLevelsPanel(frame: NSRect(x: 0, y: 0, width: 352, height: 160))
        let window = NSWindow(contentRect: panel.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.contentView = nil; window.close() }
        var snapshot = SignalLevelsSnapshot()
        snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Left", rmsDB: -24, peakDB: -6)],
                                      output: [.init(label: "Main", rmsDB: -18, peakDB: -3)])
        var toggleCallbacks = 0
        panel.onToggle = { _ in toggleCallbacks += 1 }
        panel.render(snapshot)
        panel.layoutSubtreeIfNeeded()
        let body = panel.body
        let identities = panel.rowIdentities
        let height = panel.fittingSize.height
        guard body.bounds.width > 300, body.arrangedSubviews.count == 3 else { return false }
        var clicks = 0
        func click(_ point: NSPoint, dragged: Bool = false) -> Bool {
            let before = panel.numericModeCaption
            guard let hit = body.hitTest(body.convert(point, to: body.superview)) else { return false }
            if let button = hit as? NSButton { button.performClick(nil) }
            else {
                guard hit === body else { return false }
                let location = body.convert(point, to: nil)
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0.1,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { return false }
                body.mouseDown(with: down)
                if dragged { body.mouseDragged(with: down) }
                body.mouseUp(with: up)
            }
            if dragged { return panel.numericModeCaption == before }
            clicks += 1
            return panel.numericModeCaption != before && panel.rowIdentities == identities && panel.fittingSize.height == height
        }
        // Axis caption/scale, channel label/bar/number, right edge and IN/OUT gap.
        for (index, xs) in [(0, [1.0, 160.0]), (1, [1.0, 160.0, Double(body.bounds.width - 2)]), (2, [1.0, 160.0])] {
            let row = body.arrangedSubviews[index]
            let center = row.convert(NSPoint(x: 0, y: row.bounds.midY), to: body)
            for x in xs { guard click(NSPoint(x: x, y: center.y)) else { return false } }
        }
        let first = body.arrangedSubviews[1].frame, second = body.arrangedSubviews[2].frame
        let gapY = body.isFlipped ? (first.maxY + second.minY) / 2 : (second.maxY + first.minY) / 2
        guard click(NSPoint(x: 160, y: gapY)), click(NSPoint(x: 160, y: body.bounds.midY), dragged: true),
              clicks == 8, toggleCallbacks == 0 else { return false }
        guard body.hitTest(body.convert(NSPoint(x: 10, y: body.bounds.maxY + 10), to: body.superview)) !== body else { return false }
        panel.setReadingContext(profileID: "fixture", ready: false)
        let before = panel.numericModeCaption
        panel.clickNumericHeading(); panel.clickNumericReading(at: 0)
        guard body.interactive, body.alphaValue < 1, panel.numericModeCaption == before else { return false }
        panel.setReadingContext(profileID: "fixture", ready: true)
        snapshot.error = "Meter unavailable"; panel.render(snapshot)
        guard body.interactive, body.alphaValue < 1 else { return false }
        panel.clickNumericHeading()
        guard panel.numericModeCaption != before, panel.numericAvailability.allSatisfy({ !$0 }) else { return false }
        snapshot.error = nil; snapshot.levels = nil; panel.render(snapshot)
        guard body.interactive, body.alphaValue < 1, panel.numericPeaks.allSatisfy({ $0 == "…" }) else { return false }
        panel.clickNumericReading(at: 0)
        guard panel.numericModeCaption == before else { return false }
        snapshot.enabled = false; panel.render(snapshot)
        return !body.interactive && toggleCallbacks == 0
    }

    /// Native columns remain aligned at narrow and wide menu content widths.
    /// Reopening reserves confirmed channel topology, but never shows cached samples as fresh.
    static func rememberedTopologyStaysStable() -> Bool {
        _ = NSApplication.shared
        let panel = SignalLevelsPanel(frame: NSRect(x: 0, y: 0, width: 388, height: 320))
        let window = SignalMeterVerificationWindow(contentRect: panel.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.contentView = nil; window.close() }
        var waiting = SignalLevelsSnapshot(); waiting.enabled = true
        func controlsEnabled(_ enabled: Bool) -> Bool {
            panel.body.arrangedSubviews.allSatisfy { view in
                guard let row = view as? NSStackView, let button = row.arrangedSubviews.last as? NSButton else { return false }
                return button.isEnabled == enabled
            }
        }
        for count in [1, 2, 6, 8] {
            let profile = "channels-\(count)"
            panel.setReadingContext(profileID: profile, ready: true)
            panel.render(waiting)
            guard panel.channelLabels.isEmpty, !panel.body.interactive else { return false }
            var fresh = waiting
            fresh.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -24, peakDB: -3)],
                output: (0..<count).map { .init(label: "Output \($0 + 1)", rmsDB: -20, peakDB: -6) })
            guard panel.render(fresh) else { return false }
            panel.layoutSubtreeIfNeeded()
            let labels = panel.channelLabels, identities = panel.rowIdentities, height = panel.fittingSize.height
            if panel.numericModeCaption == "Realtime" { panel.clickNumericHeading() }
            guard panel.numericModeCaption == "Peak Hold" else { return false }
            // The closed read session and the reopened waiting state contain no audio.
            guard !panel.render(waiting), !panel.render(waiting) else { return false }
            panel.layoutSubtreeIfNeeded()
            let mode = panel.numericModeCaption
            panel.clickNumericHeading(); panel.clickNumericReading(at: 0)
            guard panel.channelLabels == labels, panel.rowIdentities == identities,
                  panel.fittingSize.height == height, panel.groupGap == 8,
                  panel.numericAvailability.allSatisfy({ !$0 }), panel.numericPeaks.allSatisfy({ $0 == "…" }),
                  panel.displayedMeterValues.allSatisfy(\.isEmpty), controlsEnabled(true),
                  panel.body.interactive, panel.body.alphaValue < 1, panel.numericModeCaption == mode,
                  panel.statusMessage.isEmpty else { return false }
            fresh.levels?.input[0].peakDB = -20
            guard !panel.render(fresh), panel.numericPeaks.first == "-20.0", controlsEnabled(true), panel.body.alphaValue == 1 else { return false }
            panel.layoutSubtreeIfNeeded()
            guard panel.fittingSize.height == height, panel.rowIdentities == identities else { return false }
            // A real channel count change reflows once, then settles.
            fresh.levels?.output.append(.init(label: "Extra", rmsDB: -30, peakDB: -12))
            guard panel.render(fresh), !panel.render(fresh) else { return false }
            panel.setReadingContext(profileID: "unknown-\(count)", ready: true)
            panel.render(waiting)
            guard panel.channelLabels.isEmpty, panel.numericPeaks.isEmpty else { return false }
            panel.setReadingContext(profileID: profile, ready: true)
            panel.render(waiting)
            guard panel.channelLabels.count == count + 2, panel.numericPeaks.allSatisfy({ $0 == "…" }),
                  panel.body.interactive, controlsEnabled(true) else { return false }
            var off = waiting; off.enabled = false
            panel.render(off)
            guard !panel.metersVisible, panel.rowIdentities.isEmpty, panel.channelLabels.isEmpty else { return false }
            panel.render(waiting)
            guard panel.channelLabels.count == count + 2, panel.body.interactive, controlsEnabled(true) else { return false }
        }
        return true
    }

    /// Reopening independent interval histories must not shrink remembered rows
    /// or clear the held maxima while one side is still missing initial data.
    static func partialInitialIntervalsPreserveTopology() -> Bool {
        for outputFirst in [true, false] {
            let panel = SignalLevelsPanel(frame: .zero)
            panel.setReadingContext(profileID: "same-profile", ready: true)
            var snapshot = SignalLevelsSnapshot(); snapshot.enabled = true
            snapshot.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -20, peakDB: -3)],
                                          output: [.init(label: "Output", rmsDB: -30, peakDB: -6)])
            panel.render(snapshot); panel.clickNumericHeading(); panel.layoutSubtreeIfNeeded()
            let rows = panel.rowIdentities, labels = panel.channelLabels, height = panel.fittingSize.height
            snapshot.levels = nil
            panel.render(snapshot)
            var decoder = SignalLevelsIntervalDecoder(inputLabels: ["Input"], outputLabels: ["Output"])
            func decode(_ values: [String: [Double]]) -> SignalLevels? {
                guard let data = try? JSONSerialization.data(withJSONObject: ["GetSignalLevelsSinceLast": ["result": "Ok", "value": values]]) else { return nil }
                return try? decoder.decode(data)
            }
            var first: [String: [Double]] = ["capture_rms": [], "capture_peak": [], "playback_rms": [], "playback_peak": []]
            first[outputFirst ? "playback_rms" : "capture_rms"] = [-40]
            first[outputFirst ? "playback_peak" : "capture_peak"] = [-20]
            guard let partial = decode(first), partial.input.isEmpty, partial.output.isEmpty else { return false }
            // The controller publishes no measured snapshot for an empty arrival.
            guard !panel.render(snapshot) else { return false }
            panel.layoutSubtreeIfNeeded()
            guard panel.rowIdentities == rows, panel.channelLabels == labels, panel.fittingSize.height == height,
                  panel.numericPeaks == ["…", "…"], panel.numericAvailability == [false, false],
                  panel.displayedMeterValues.allSatisfy(\.isEmpty), panel.numericModeCaption == "Peak Hold",
                  panel.body.interactive else { return false }
            var last: [String: [Double]] = ["capture_rms": [], "capture_peak": [], "playback_rms": [], "playback_peak": []]
            last[outputFirst ? "capture_rms" : "playback_rms"] = [-50]
            last[outputFirst ? "capture_peak" : "playback_peak"] = [-30]
            guard let complete = decode(last) else { return false }
            snapshot.levels = complete
            guard !panel.render(snapshot), panel.rowIdentities == rows, panel.channelLabels == labels,
                  panel.numericPeaks == ["-3.0", "-6.0"],
                  panel.displayedMeterValues.map({ $0[1] }) == [-3, -6] else { return false }
            // A genuinely changed, confirmed topology is allowed to replace rows.
            snapshot.levels = SignalLevels(input: [.init(label: "Replacement", rmsDB: -40, peakDB: -30)], output: [])
            guard panel.render(snapshot), panel.channelLabels == ["IN: Replacement"],
                  panel.numericPeaks == ["-30.0"], panel.displayedMeterValues == [[-40, -30]] else { return false }
        }
        return true
    }

    static func numericTrailingEdgesAlign() -> Bool {
        _ = NSApplication.shared
        let panel = SignalLevelsPanel(frame: NSRect(x: 0, y: 0, width: 352, height: 180))
        let window = SignalMeterVerificationWindow(contentRect: panel.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.contentView = nil; window.close() }
        var snapshot = SignalLevelsSnapshot(); snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Long input channel label", rmsDB: -150, peakDB: -150)],
                                       output: [.init(label: "Main", rmsDB: -18, peakDB: 2)])
        panel.render(snapshot)
        let identities = panel.rowIdentities
        for width in [300.0, 352.0, 388.0, 512.0] {
            window.setContentSize(NSSize(width: width, height: 180))
            panel.layoutSubtreeIfNeeded()
            let card = panel.body.convert(panel.body.bounds, to: panel)
            guard abs(card.minX - panel.bounds.minX) < 0.5,
                  abs(card.maxX - panel.bounds.maxX) < 0.5 else { return false }
            var meterEdges: [NSRect] = []
            for view in panel.body.arrangedSubviews {
                guard let row = view as? NSStackView, row.arrangedSubviews.count == 3,
                      let button = row.arrangedSubviews.last as? NSButton,
                      button.alignment == .right else { return false }
                let rect = button.convert(button.bounds, to: panel)
                let content = row.convert(row.bounds, to: panel)
                guard abs(rect.maxX - (card.maxX - panel.body.edgeInsets.right)) < 0.5,
                      abs(content.minX - (card.minX + panel.body.edgeInsets.left)) < 0.5,
                      abs(content.maxX - rect.maxX) < 0.5,
                      button.attributedTitle.size().width <= button.bounds.width - 4 else { return false }
                meterEdges.append(row.arrangedSubviews[1].convert(row.arrangedSubviews[1].bounds, to: panel))
            }
            guard let axis = meterEdges.first, axis.width > 100,
                  meterEdges.allSatisfy({ abs($0.minX - axis.minX) < 0.5 && abs($0.maxX - axis.maxX) < 0.5 }),
                  panel.rowIdentities == identities, panel.groupGap == 8 else { return false }
        }
        return true
    }

    static func unavailableReadingsStayStable() -> Bool {
        let panel = SignalLevelsPanel(frame: .zero)
        var snapshot = SignalLevelsSnapshot(); snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -24, peakDB: -6)],
                                       output: [.init(label: "Output", rmsDB: -20, peakDB: -3)])
        snapshot.numericPeakLevels = SignalLevels(input: [.init(label: "Input", rmsDB: -24, peakDB: -2)],
                                                  output: [.init(label: "Output", rmsDB: -20, peakDB: -1)])
        snapshot.inputFreshness = [.init(rmsAvailable: true, peakAvailable: true)]
        snapshot.outputFreshness = [.init(rmsAvailable: true, peakAvailable: true)]
        panel.render(snapshot)
        panel.layoutSubtreeIfNeeded()
        let height = panel.fittingSize.height
        let identities = panel.rowIdentities, numbers = panel.numericPeaks
        snapshot.inputFreshness = [.init(rmsAvailable: true, peakAvailable: false)]
        panel.render(snapshot)
        guard panel.statusMessage.isEmpty, panel.numericAvailability == [false, true],
              panel.rowIdentities == identities, panel.numericPeaks == numbers else { return false }
        snapshot.error = "Disconnected"
        snapshot.inputFreshness = [.init(rmsAvailable: false, peakAvailable: false)]
        snapshot.outputFreshness = [.init(rmsAvailable: false, peakAvailable: false)]
        panel.render(snapshot)
        panel.layoutSubtreeIfNeeded()
        guard panel.numericAvailability == [false, false], panel.numericPeaks == numbers,
              panel.body.alphaValue < 1, panel.fittingSize.height == height else { return false }
        snapshot.error = nil
        snapshot.inputFreshness = [.init(rmsAvailable: true, peakAvailable: true)]
        snapshot.outputFreshness = [.init(rmsAvailable: true, peakAvailable: true)]
        panel.render(snapshot)
        guard panel.statusMessage.isEmpty && panel.numericAvailability == [true, true],
              panel.body.alphaValue == 1, panel.rowIdentities == identities else { return false }
        panel.setReadingContext(profileID: "original", ready: true)
        panel.clickNumericHeading()
        snapshot.levels?.input[0].peakDB = -30
        snapshot.levels?.output[0].peakDB = -40
        panel.render(snapshot)
        guard panel.numericPeaks == ["-6.0", "-3.0"],
              panel.displayedMeterValues.map({ $0[1] }) == [-6, -3] else { return false }
        panel.setReadingContext(profileID: "original", ready: false)
        snapshot.error = "DSP stopped"
        panel.render(snapshot)
        panel.render(snapshot)
        guard panel.numericPeaks == ["-6.0", "-3.0"],
              panel.displayedMeterValues.map({ $0[1] }) == [-6, -3] else { return false }
        panel.setReadingContext(profileID: "replacement", ready: false)
        snapshot.levels?.input[0].peakDB = -50
        snapshot.levels?.output[0].peakDB = -60
        snapshot.numericPeakLevels = snapshot.levels
        panel.render(snapshot)
        guard panel.numericPeaks == ["-50.0", "-60.0"],
              panel.displayedMeterValues.map({ $0[1] }) == [-50, -60] else { return false }
        snapshot.error = nil
        panel.setReadingContext(profileID: "replacement", ready: true)
        panel.render(snapshot)
        return panel.numericPeaks == ["-50.0", "-60.0"] &&
            panel.displayedMeterValues.map({ $0[1] }) == [-50, -60]
    }

    static func offlineModeNeverSeedsStaleMaxima() -> Bool {
        let panel = SignalLevelsPanel(frame: .zero)
        panel.setReadingContext(profileID: "fixture", ready: true)
        var callbacks = 0
        panel.onToggle = { _ in callbacks += 1 }; panel.onRetry = { callbacks += 1 }
        var snapshot = SignalLevelsSnapshot(); snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -24, peakDB: -3)],
                                      output: [.init(label: "Output", rmsDB: -24, peakDB: -4)])
        snapshot.inputFreshness = [.init(rmsAvailable: true, peakAvailable: false)]
        snapshot.outputFreshness = [.init(rmsAvailable: true, peakAvailable: true)]
        panel.render(snapshot); panel.clickNumericHeading()
        snapshot.levels?.input[0].peakDB = -20; snapshot.levels?.output[0].peakDB = -10
        snapshot.inputFreshness = [.init(rmsAvailable: true, peakAvailable: true)]
        panel.render(snapshot)
        guard panel.numericPeaks == ["-20.0", "-4.0"] else { return false }
        let rows = panel.rowIdentities
        panel.setReadingContext(profileID: "fixture", ready: false)
        snapshot.error = "Interface disconnected"; snapshot.levels = nil
        panel.render(snapshot); panel.clickNumericHeading()
        guard panel.numericModeCaption == "Realtime", panel.body.interactive,
              panel.numericAvailability == [false, false], panel.numericPeaks == ["…", "…"],
              panel.statusMessage.isEmpty, panel.body.alphaValue < 1 else { return false }
        panel.clickNumericReading(at: 0)
        guard panel.numericModeCaption == "Peak Hold", panel.rowIdentities == rows else { return false }
        snapshot.error = nil
        snapshot.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -44, peakDB: -40)],
                                      output: [.init(label: "Output", rmsDB: -34, peakDB: -30)])
        panel.setReadingContext(profileID: "fixture", ready: true); panel.render(snapshot)
        return panel.numericPeaks == ["-40.0", "-30.0"] && panel.numericAvailability == [true, true]
            && panel.rowIdentities == rows && panel.body.alphaValue == 1 && callbacks == 0
    }

    static func numericModesStayStable() -> Bool {
        let panel = SignalLevelsPanel(frame: NSRect(x: 0, y: 0, width: 388, height: 180))
        var toggleCallbacks = 0
        panel.onToggle = { _ in toggleCallbacks += 1 }
        var snapshot = SignalLevelsSnapshot()
        snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Left", rmsDB: -30, peakDB: -12),
                                               .init(label: "Right", rmsDB: -24, peakDB: -6)],
                                       output: [.init(label: "Main", rmsDB: -18, peakDB: 2)])
        snapshot.displayLevels = SignalLevels(input: [.init(label: "Left", rmsDB: -26, peakDB: -4),
                                                      .init(label: "Right", rmsDB: -20, peakDB: -2)],
                                              output: [.init(label: "Main", rmsDB: -14, peakDB: 3)])
        // Timed numeric peaks supply Realtime; unlimited mode uses actual fresh samples.
        snapshot.numericPeakLevels = SignalLevels(input: [.init(label: "Left", rmsDB: -1, peakDB: -12),
                                                          .init(label: "Right", rmsDB: -1, peakDB: -6)],
                                                  output: [.init(label: "Main", rmsDB: -1, peakDB: 2)])
        panel.render(snapshot); panel.layoutSubtreeIfNeeded()
        let rows = panel.rowIdentities, controls = panel.numericControlIdentities
        let height = panel.fittingSize.height, realtimeBars = panel.displayedMeterValues
        func stable(_ peaks: [Double]? = nil) -> Bool {
            panel.layoutSubtreeIfNeeded()
            return panel.rowIdentities == rows && panel.numericControlIdentities == controls
                && panel.fittingSize.height == height
                && panel.displayedMeterValues == (peaks.map { zip(realtimeBars, $0).map { [$0.0[0], $0.1] } } ?? realtimeBars)
                && toggleCallbacks == 0
        }
        guard panel.numericModeCaption == "Realtime", panel.numericPeaks == ["-12.0", "-6.0", "2.0"] else { return false }
        snapshot.numericPeakLevels = nil
        panel.clickNumericHeading()
        guard panel.numericModeCaption == "Peak Hold", stable([-12, -6, 2]) else { return false }
        snapshot.levels?.input[0].peakDB = -20
        snapshot.levels?.input[1].peakDB = -3
        snapshot.levels?.output[0].peakDB = -9
        guard !panel.render(snapshot), panel.numericPeaks == ["-12.0", "-3.0", "2.0"],
              panel.clippedNumericPeaks == [false, false, true], stable([-12, -3, 2]),
              panel.numericPeakHelp.allSatisfy({ $0.contains("until returning to Realtime") }) else { return false }
        panel.clickNumericReading(at: 0)
        guard panel.numericModeCaption == "Realtime", panel.numericPeaks == ["-20.0", "-3.0", "-9.0"],
              panel.clippedNumericPeaks == [false, false, false], stable() else { return false }
        panel.clickNumericReading(at: 1)
        guard panel.numericModeCaption == "Peak Hold", panel.numericPeaks == ["-20.0", "-3.0", "-9.0"], stable([-20, -3, -9]) else { return false }
        panel.clickNumericReading(at: 2)
        guard panel.numericModeCaption == "Realtime", stable() else { return false }
        panel.clickNumericHeading()
        // Clearing a read session preserves the selected mode but starts fresh maxima.
        snapshot.enabled = false
        panel.render(snapshot)
        snapshot.enabled = true
        snapshot.levels?.input[0].peakDB = -35
        snapshot.levels?.input[1].peakDB = -30
        snapshot.levels?.output[0].peakDB = -25
        panel.render(snapshot)
        guard panel.numericModeCaption == "Peak Hold", panel.numericPeaks == ["-35.0", "-30.0", "-25.0"],
              panel.displayedMeterValues.map({ $0[1] }) == [-35, -30, -25] else { return false }
        snapshot.error = "Read failed"
        panel.render(snapshot)
        snapshot.error = nil
        snapshot.levels?.output[0].peakDB = -40
        panel.render(snapshot)
        guard panel.numericPeaks == ["-35.0", "-30.0", "-40.0"],
              panel.displayedMeterValues.map({ $0[1] }) == [-35, -30, -40] else { return false }
        snapshot.levels?.input[0].label = "Replacement"
        snapshot.levels?.input[1].peakDB = -50
        panel.render(snapshot)
        guard panel.numericPeaks == ["-35.0", "-50.0", "-40.0"],
              panel.displayedMeterValues.map({ $0[1] }) == [-35, -50, -40] else { return false }
        let valid = snapshot.levels
        snapshot.levels = nil
        panel.render(snapshot)
        snapshot.levels = valid
        snapshot.levels?.input[0].peakDB = -60
        panel.render(snapshot)
        guard panel.numericPeaks == ["-35.0", "-50.0", "-40.0"],
              panel.displayedMeterValues.map({ $0[1] }) == [-35, -50, -40] else { return false }
        panel.setReadingContext(profileID: "New profile", ready: true)
        panel.render(snapshot)
        guard panel.numericPeaks == ["-60.0", "-50.0", "-40.0"],
              panel.displayedMeterValues.map({ $0[1] }) == [-60, -50, -40] else { return false }
        panel.setReadingContext(profileID: "New profile", ready: false)
        snapshot.levels?.input[0].peakDB = -70
        panel.render(snapshot)
        panel.setReadingContext(profileID: "New profile", ready: true)
        snapshot.levels?.input[0].peakDB = -80
        panel.render(snapshot)
        return panel.numericPeaks == ["-80.0", "-50.0", "-40.0"] &&
            panel.displayedMeterValues.map({ $0[1] }) == [-80, -50, -40] && toggleCallbacks == 0
    }

    /// Passes real timed ballistics through the panel without a clock, timer or DSP.
    static func peakHoldMarkersIgnoreTimedExpiry() -> Bool {
        for hold in [0.0, 5000.0] {
            let panel = SignalLevelsPanel(frame: .zero)
            var meter = SignalMeterBallistics()
            let options = SignalMeterOptions(peakHoldMilliseconds: hold, numberHoldMilliseconds: hold)
            var snapshot = SignalLevelsSnapshot(); snapshot.enabled = true
            func render(_ inputPeak: Double, _ outputPeak: Double, at time: Double, peakUpdated: Bool = true) {
                let levels = SignalLevels(input: [.init(label: "Input", rmsDB: time == 0 ? -20 : -40, peakDB: inputPeak, peakUpdated: peakUpdated)],
                                          output: [.init(label: "Output", rmsDB: time == 0 ? -10 : -30, peakDB: outputPeak, peakUpdated: peakUpdated)])
                snapshot.levels = levels
                snapshot.displayLevels = meter.consume(levels, at: time, options: options)
                snapshot.numericPeakLevels = meter.numericPeakLevels
                panel.render(snapshot)
            }
            render(-6, -3, at: 0)
            panel.clickNumericHeading()
            render(-40, -50, at: 60)
            guard panel.numericPeaks == ["-6.0", "-3.0"],
                  panel.displayedMeterValues == [[-40, -6], [-30, -3]],
                  snapshot.displayLevels?.input[0].peakDB == -40,
                  snapshot.numericPeakLevels?.output[0].peakDB == -50 else { return false }
            render(-2, -60, at: 61)
            guard panel.numericPeaks == ["-2.0", "-3.0"],
                  panel.displayedMeterValues == [[-40, -2], [-30, -3]] else { return false }
            // Cached, nonfresh peak components cannot raise the captured maximum.
            render(4, 5, at: 62, peakUpdated: false)
            guard panel.numericPeaks == ["-2.0", "-3.0"],
                  panel.displayedMeterValues == [[-40, -2], [-30, -3]] else { return false }
            panel.clickNumericHeading()
            guard panel.numericModeCaption == "Realtime",
                  panel.displayedMeterValues == (snapshot.displayLevels!.input + snapshot.displayLevels!.output).map({ [$0.rmsDB, $0.peakDB] }) else { return false }
            render(-20, -25, at: 120)
            panel.clickNumericHeading()
            guard panel.numericPeaks == ["-20.0", "-25.0"],
                  panel.displayedMeterValues == [[-40, -20], [-30, -25]] else { return false }
        }
        return true
    }

    static func displayRangeIsStable() -> Bool {
        let panel = SignalLevelsPanel(frame: NSRect(x: 0, y: 0, width: 388, height: 180))
        var snapshot = SignalLevelsSnapshot()
        snapshot.enabled = true
        snapshot.levels = SignalLevels(input: [.init(label: "Quiet", rmsDB: -110, peakDB: -105)],
                                       output: [.init(label: "Clipped", rmsDB: -18, peakDB: 2)])
        panel.render(snapshot)
        panel.clickNumericHeading()
        snapshot.levels?.output[0].peakDB = -3
        panel.render(snapshot)
        panel.layoutSubtreeIfNeeded()
        let identities = panel.rowIdentities
        let height = panel.fittingSize.height
        let numeric = panel.numericPeaks
        guard panel.numericPeakHelp.allSatisfy({ $0.contains("until returning to Realtime") }) else { return false }
        guard numeric == ["<−96", "2.0"], panel.clippedNumericPeaks == [false, true] else { return false }
        for (minimum, maximum) in [(-60.0, 0.0), (-120, -12), (-30, 10), (-150, 20), (-4, -1), (2, 10)] {
            panel.setDisplayRange(minimumDB: minimum, maximumDB: maximum)
            panel.layoutSubtreeIfNeeded()
            guard panel.rowIdentities == identities, panel.fittingSize.height == height,
                  panel.numericPeaks == [minimum > -105 ? "<" + SignalMeterDisplayRange(minimumDB: minimum, maximumDB: maximum).label(minimum) : "-105.0", "2.0"],
                  panel.displayedMeterValues == [[-110, -105], [-18, 2]], panel.clippedNumericPeaks == [false, true],
                  !panel.render(snapshot) else { return false }
        }
        // Invalid direct callers cannot introduce zero-width or nonfinite mapping.
        panel.setDisplayRange(minimumDB: .nan, maximumDB: 0)
        panel.setDisplayRange(minimumDB: 3, maximumDB: 3)
        return panel.rowIdentities == identities && panel.fittingSize.height == height
    }

    /// Actual owned bar/axis rasters, independent of the DSP reader and desktop.
    static func verifyDisplayRangeRasterization(renderDirectory: URL? = nil) -> Bool {
        let savedKeepActiveColors = AudioControlStyle.keepActiveColors
        AudioControlStyle.keepActiveColors = false
        defer { AudioControlStyle.keepActiveColors = savedKeepActiveColors }
        _ = NSApplication.shared
        let window = SignalMeterVerificationWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 18), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        func raster(_ view: NSView, appearance: NSAppearance) -> NSBitmapImageRep? {
            let frame = view.frame
            window.contentView = view
            view.frame = frame
            view.appearance = appearance
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
                pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            appearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
            NSGraphicsContext.restoreGraphicsState(); return bitmap
        }
        func rgb(_ image: NSBitmapImageRep, db: Double, range: SignalMeterDisplayRange) -> NSColor? {
            let x = min(image.pixelsWide - 1, max(0, Int(range.unitPosition(db) * CGFloat(image.pixelsWide))))
            return image.colorAt(x: x, y: 5)?.usingColorSpace(.deviceRGB)
        }
        func green(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return color.greenComponent > color.redComponent * 1.5 && color.greenComponent > color.blueComponent
        }
        func yellow(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return color.redComponent > 0.7 && color.greenComponent > 0.5 && color.blueComponent < 0.35
        }
        func red(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return color.redComponent > color.greenComponent * 1.5 && color.redComponent > color.blueComponent * 1.5
        }
        func close(_ first: NSColor?, _ second: NSColor?) -> Bool {
            guard let first, let second else { return false }
            return abs(first.redComponent - second.redComponent) < 0.02
                && abs(first.greenComponent - second.greenComponent) < 0.02
                && abs(first.blueComponent - second.blueComponent) < 0.02
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { return false }
            let bar = SignalMeterBar(frame: NSRect(x: 0, y: 0, width: 240, height: 10))
            let base = SignalMeterDisplayRange(minimumDB: -72, maximumDB: 6)
            bar.setDisplayRange(base); bar.update(rms: 5, peak: 5)
            guard let filled = raster(bar, appearance: appearance),
                  let cyan = rgb(filled, db: -68, range: base), let middle = rgb(filled, db: -42, range: base),
                  let upper = rgb(filled, db: -10, range: base),
                  cyan.blueComponent > cyan.greenComponent, middle.blueComponent < cyan.blueComponent,
                  middle.blueComponent > upper.blueComponent, green(upper),
                  green(rgb(filled, db: -7, range: base)), yellow(rgb(filled, db: -5, range: base)),
                  yellow(rgb(filled, db: -1, range: base)), red(rgb(filled, db: 1, range: base)) else { return false }
            // Absolute anchors survive arbitrary cropping, including a crop wholly
            // inside the gradient, yellow zone or above the clipping threshold.
            let cropped = SignalMeterDisplayRange(minimumDB: -48, maximumDB: -18)
            bar.setDisplayRange(cropped)
            guard let crop = raster(bar, appearance: appearance),
                  close(middle, rgb(crop, db: -42, range: cropped)) else { return false }
            for (minimum, maximum, probe, test) in [(-60.0, -12.0, -30.0, green), (-4, -1, -2.5, yellow), (2, 10, 4, red)] {
                let range = SignalMeterDisplayRange(minimumDB: minimum, maximumDB: maximum)
                bar.setDisplayRange(range); bar.update(rms: maximum + 1, peak: maximum + 2)
                guard let image = raster(bar, appearance: appearance), test(rgb(image, db: probe, range: range)) else { return false }
            }
            let negative = SignalMeterDisplayRange(minimumDB: -60, maximumDB: -12)
            bar.setDisplayRange(negative); bar.update(rms: -30, peak: 2)
            guard let clipped = raster(bar, appearance: appearance), red(clipped.colorAt(x: 238, y: 5)?.usingColorSpace(.deviceRGB)),
                  !negative.prioritizedTicks.contains(0) else { return false }
            // RMS ends independently of the peak. Raising the peak cannot recolor
            // an existing quiet span or fill the empty track beyond RMS.
            let range = SignalMeterDisplayRange(minimumDB: -60, maximumDB: 0)
            bar.setDisplayRange(range); bar.update(rms: -30, peak: -12)
            guard let first = raster(bar, appearance: appearance),
                  green(first.colorAt(x: 119, y: 5)?.usingColorSpace(.deviceRGB)),
                  let track = rgb(first, db: -20, range: range),
                  abs(track.redComponent - track.greenComponent) < 0.02,
                  abs(track.greenComponent - track.blueComponent) < 0.02 else { return false }
            bar.update(rms: -30, peak: 2)
            guard let second = raster(bar, appearance: appearance),
                  close(rgb(first, db: -42, range: range), rgb(second, db: -42, range: range)),
                  close(track, rgb(second, db: -20, range: range)),
                  red(second.colorAt(x: 238, y: 5)?.usingColorSpace(.deviceRGB)) else { return false }
            // Focus changes recolor owned rasters without changing any samples.
            bar.setDisplayRange(base); bar.update(rms: 5, peak: -3)
            let values = bar.displayedValues
            window.focusedForVerification = false
            guard let inactive = raster(bar, appearance: appearance) else { return false }
            for db in [-68.0, -42, -10, -5, -3] {
                guard let color = rgb(inactive, db: db, range: base),
                      abs(color.redComponent - color.greenComponent) < 0.02,
                      abs(color.greenComponent - color.blueComponent) < 0.02 else { return false }
            }
            guard red(rgb(inactive, db: 1, range: base)), bar.displayedValues == values else { return false }
            AudioControlStyle.keepActiveColors = true
            guard !AudioControlStyle.windowIsActive(window),
                  let keptColors = raster(bar, appearance: appearance),
                  green(rgb(keptColors, db: -10, range: base)), yellow(rgb(keptColors, db: -5, range: base)),
                  red(rgb(keptColors, db: 1, range: base)), bar.displayedValues == values else { return false }
            AudioControlStyle.keepActiveColors = false
            guard let restored = raster(bar, appearance: appearance),
                  close(rgb(restored, db: -10, range: base), rgb(inactive, db: -10, range: base)),
                  bar.displayedValues == values else { return false }
            bar.update(rms: -30, peak: 2)
            guard let inactiveClipped = raster(bar, appearance: appearance),
                  red(inactiveClipped.colorAt(x: Int(base.unitPosition(2) * CGFloat(inactiveClipped.pixelsWide)) + 1, y: 5)?.usingColorSpace(.deviceRGB)) else { return false }
            window.focusedForVerification = true
            bar.update(rms: 5, peak: -3)
            guard let refocused = raster(bar, appearance: appearance),
                  green(rgb(refocused, db: -10, range: base)), yellow(rgb(refocused, db: -5, range: base)),
                  red(rgb(refocused, db: 1, range: base)), bar.displayedValues == values else { return false }
            let axis = SignalMeterScale(frame: NSRect(x: 0, y: 0, width: 240, height: 18))
            axis.setDisplayRange(negative)
            guard let scale = raster(axis, appearance: appearance), [1, scale.pixelsHigh - 2].contains(where: { y in
                (scale.colorAt(x: 120, y: y)?.alphaComponent ?? 0) > 0.4
                    && (scale.colorAt(x: 119, y: y)?.alphaComponent ?? 0) < 0.05
            }) else { return false }
            if let renderDirectory {
                do {
                    try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
                    for before in [true, false] {
                        guard let strip = styleStrip(appearance: appearance, legacy: before),
                              let png = strip.representation(using: .png, properties: [:]) else { return false }
                        try png.write(to: renderDirectory.appendingPathComponent("meter-\(before ? "before" : "after")-\(name == .aqua ? "light" : "dark").png"))
                    }
                } catch { return false }
            }
        }
        return true
    }

    /// Owned before/after strips contain no native controls or live app content.
    private static func styleStrip(appearance: NSAppearance, legacy: Bool) -> NSBitmapImageRep? {
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 116,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: image) else { return nil }
        let window = SignalMeterVerificationWindow(contentRect: NSRect(x: 0, y: 0, width: 352, height: 10), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: 480, height: 116).fill()
            let range = SignalMeterDisplayRange(minimumDB: -72, maximumDB: 6)
            let axis = SignalMeterScale(frame: NSRect(x: 0, y: 0, width: 352, height: 18)); axis.appearance = appearance
            axis.setDisplayRange(range)
            NSGraphicsContext.saveGraphicsState()
            let axisTransform = NSAffineTransform(); axisTransform.translateX(by: 112, yBy: 94); axisTransform.concat()
            axis.draw(axis.bounds); NSGraphicsContext.restoreGraphicsState()
            for (label, rms, peak, y) in [("Quiet", -42.0, -24.0, 71.0), ("Near zero", -3, -1, 43), ("Over zero", 2, 4, 15)] {
                NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
                    .draw(at: NSPoint(x: 12, y: y - 2))
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform(); transform.translateX(by: 112, yBy: y); transform.concat()
                let bar = SignalMeterBar(frame: NSRect(x: 0, y: 0, width: 352, height: 10)); bar.appearance = appearance
                window.contentView = bar
                bar.setDisplayRange(range); bar.update(rms: rms, peak: peak)
                if legacy {
                    NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect: bar.bounds, xRadius: 2, yRadius: 2).fill()
                    func x(_ db: Double) -> CGFloat { range.unitPosition(db) * 352 }
                    for (low, high, color) in [(range.minimumDB, -6.0, NSColor.systemGreen), (-6.0, 0.0, .systemYellow), (0.0, range.maximumDB, .systemRed)] {
                        let start = x(low), end = min(x(rms), x(high))
                        if end > start { color.setFill(); NSRect(x: start, y: 0, width: end - start, height: 10).fill() }
                    }
                    for db in range.prioritizedTicks {
                        NSColor.labelColor.withAlphaComponent(0.2).setFill(); NSRect(x: x(db), y: 0, width: 1, height: 10).fill()
                    }
                    (peak >= 0 ? NSColor.systemRed : NSColor.labelColor).setFill()
                    NSRect(x: min(350, x(peak)), y: 0, width: 2, height: 10).fill()
                } else { bar.draw(bar.bounds) }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return image
    }

    static func groupedRowsStayStable() -> Bool {
        let panel = SignalLevelsPanel(frame: .zero)
        let inputs = [SignalChannelLevel(label: "Left", rmsDB: -24, peakDB: -6)]
        let outputs = [SignalChannelLevel(label: "Main", rmsDB: -18, peakDB: -3)]
        var snapshot = SignalLevelsSnapshot()
        snapshot.enabled = true
        snapshot.levels = SignalLevels(input: inputs, output: outputs)
        guard panel.render(snapshot), panel.groupGap == 8 else { return false }
        let identities = panel.rowIdentities
        snapshot.levels?.input[0].rmsDB = -30
        snapshot.displayLevels = SignalLevels(input: [.init(label: "Left", rmsDB: -25, peakDB: -6)], output: outputs)
        guard !panel.render(snapshot), panel.rowIdentities == identities, panel.groupGap == 8 else { return false }
        snapshot.levels = SignalLevels(input: inputs, output: [])
        snapshot.displayLevels = nil
        guard panel.render(snapshot), panel.groupGap == nil else { return false }
        snapshot.levels = SignalLevels(input: [], output: outputs)
        return panel.render(snapshot) && panel.groupGap == nil
    }
}

@MainActor private extension SignalLevelsPanel {
    func numericCaptionMatches(active: Bool) -> Bool {
        guard let caption = numericCaption else { return false }
        let mode = numericModeCaption
        return caption.string == "RMS / Peak\n" + mode
            && caption.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == .systemFont(ofSize: 10)
            && caption.attribute(.font, at: "RMS / Peak\n".utf16.count, effectiveRange: nil) as? NSFont == .systemFont(ofSize: 8)
            && caption.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor
            && caption.attribute(.foregroundColor, at: "RMS / Peak\n".utf16.count, effectiveRange: nil) as? NSColor == (active ? (mode == "Realtime" ? .systemGreen : .systemOrange) : .labelColor)
            && numericCaptionAccessibilityValue == mode
    }
}
#endif
