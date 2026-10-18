import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class AudioDisclosureVerificationWindow: NSWindow, AudioFocusVerificationWindow {
    var focusedForVerification = true
}

/// Compare the actual disclosure controls without connecting to DSP or showing a window.
@MainActor enum AudioDisclosureStyleVerification {
    static func headingsMatch() -> Bool {
        _ = NSApplication.shared
        let previous = AudioControlStyle.keepActiveColors
        defer { AudioControlStyle.keepActiveColors = previous }
        let live = SignalLevelsPanel(frame: .zero)
        let aux = AuxFaderPanel(frame: .zero)
        let content = NSStackView(views: [live, aux])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        for panel in [live as NSView, aux] {
            panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let window = AudioDisclosureVerificationWindow(contentRect: NSRect(x: 0, y: 0, width: 352, height: 280),
            styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content
        defer { window.contentView = nil; window.close() }
        aux.render(AuxFaderSnapshot(profileID: "fixture", faders: [
            AuxFader(id: 1, name: "Aux", volumeDB: 0, muted: false, maximumDB: 0)
        ], preferences: AuxPreferences(visibleIDs: [1]), ready: true))
        var sample = SignalLevelsSnapshot(); sample.enabled = true
        sample.levels = SignalLevels(input: [.init(label: "Input", rmsDB: -24, peakDB: -6)], output: [])
        let expectedFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for focused in [true, false] {
                window.focusedForVerification = focused
                for keepColors in [false, true] {
                    AudioControlStyle.keepActiveColors = keepColors
                    for expanded in [true, false] {
                        let scenario = "\(appearance.rawValue), focused=\(focused), keepColors=\(keepColors), expanded=\(expanded)"
                        sample.enabled = expanded; live.render(sample)
                        if expanded { aux.expand() } else { aux.collapse() }
                        live.refreshFocusAppearance(); aux.refreshFocusAppearance()
                        let buttons = [live.disclosureForVerification, aux.disclosureForVerification]
                        let expectedTint: NSColor = expanded && (focused || keepColors) ? .labelColor : .secondaryLabelColor
                        for button in buttons {
                            guard button.font == expectedFont, !button.isBordered,
                                  button.alignment == .left, button.imagePosition == .imageLeading,
                                  button.contentTintColor == expectedTint,
                                  button.accessibilityValue() as? String == (expanded ? "Expanded" : "Collapsed"),
                                  button.accessibilityLabel() == (expanded ? "Collapse " : "Expand ") + button.title,
                                  button.target != nil, button.action != nil else {
                                print("Disclosure verification failed: \(button.title) style or accessibility, \(scenario)")
                                return false
                            }
                        }
                        guard buttons[0].image?.size == buttons[1].image?.size else {
                            print("Disclosure verification failed: chevron sizes differ, \(scenario)")
                            return false
                        }
                        for width in [300.0, 388.0] {
                            window.setContentSize(NSSize(width: width, height: 280))
                            content.layoutSubtreeIfNeeded()
                            for (button, panel) in zip(buttons, [live as NSView, aux]) {
                                let rect = button.convert(button.bounds, to: panel)
                                guard abs(rect.height - AudioControlStyle.disclosureHeight) < 0.5,
                                      abs(rect.minX - panel.bounds.minX) < 0.5,
                                      abs(rect.maxX - panel.bounds.maxX) < 0.5 else {
                                    print("Disclosure verification failed: \(button.title) frame \(rect) within \(panel.bounds), \(scenario), width=\(width)")
                                    return false
                                }
                            }
                        }
                    }
                }
            }
        }
        // Retry must reserve only its compact width; the disclosure keeps the
        // remaining header area and its native action stays independent.
        sample.enabled = true; sample.error = "Offline fixture"; live.render(sample)
        aux.expand(); live.refreshFocusAppearance(); aux.refreshFocusAppearance()
        let disclosure = live.disclosureForVerification
        guard let header = disclosure.superview as? NSStackView,
              let retry = header.arrangedSubviews.last as? NSButton,
              retry !== disclosure, !retry.isHidden, retry.title == "Retry",
              retry.target != nil, retry.action != nil, retry.action != disclosure.action else {
            print("Disclosure verification failed: separate Retry control or action")
            return false
        }
        for width in [300.0, 388.0] {
            window.setContentSize(NSSize(width: width, height: 280))
            content.layoutSubtreeIfNeeded()
            let headingRect = disclosure.convert(disclosure.bounds, to: live)
            let retryRect = retry.convert(retry.bounds, to: live)
            let headerRect = header.convert(header.bounds, to: live)
            let auxRect = aux.disclosureForVerification.convert(aux.disclosureForVerification.bounds, to: aux)
            guard abs(headerRect.height - AudioControlStyle.disclosureHeight) < 0.5,
                  abs(headingRect.height - auxRect.height) < 0.5,
                  abs(headingRect.minX - live.bounds.minX) < 0.5,
                  abs(retryRect.width - AudioControlStyle.compactWidth) < 0.5,
                  abs(retryRect.height - AudioControlStyle.compactControlHeight) < 0.5,
                  abs(retryRect.maxX - live.bounds.maxX) < 0.5,
                  abs(retryRect.minX - headingRect.maxX - 8) < 0.5 else {
                print("Disclosure verification failed: Retry layout, width=\(width), heading=\(headingRect), retry=\(retryRect), header=\(headerRect)")
                return false
            }
        }
        var disclosures: [Bool] = [], retries = 0
        live.onToggle = { disclosures.append($0) }; live.onRetry = { retries += 1 }
        retry.performClick(nil)
        guard retries == 1, disclosures.isEmpty else { return false }
        disclosure.performClick(nil)
        guard retries == 1, disclosures == [false] else { return false }
        return !window.isVisible
    }
}

