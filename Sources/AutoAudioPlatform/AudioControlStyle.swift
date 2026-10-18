import AppKit
import AutoAudioCore

@MainActor package protocol AudioFocusVerificationWindow { var focusedForVerification: Bool { get } }

/// Shared native button styling, without replacing keyboard or accessibility behavior.
@MainActor package enum AudioControlStyle {
    // Rendering policy only. Never changes actual window focus or read eligibility.
    package static var keepActiveColors = false
    static func windowUsesActiveAppearance(_ window: NSWindow?) -> Bool {
        keepActiveColors || windowIsActive(window)
    }

    package static let disclosureHeight: CGFloat = 28
    static func configureDisclosure(_ button: NSButton) {
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.heightAnchor.constraint(equalToConstant: disclosureHeight).isActive = true
    }

    static func refreshDisclosure(_ button: NSButton, expanded: Bool) {
        button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        button.setAccessibilityLabel((expanded ? "Collapse " : "Expand ") + button.title)
        button.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
        button.contentTintColor = expanded && windowUsesActiveAppearance(button.window) ? .labelColor : .secondaryLabelColor
        button.needsDisplay = true
    }

    package static func configureRounded(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.focusRingType = .exterior
    }

    // Reserve the widest known state and extra text padding once. Callers can
    // supply localized titles as they become available without resizing on state.
    package static let compactTitles = ["Pin", "More", "Retry", "Retry DSP", "Retry GUI", "Resume Routing", "Dismiss"]
    package static let compactHorizontalPadding: CGFloat = 24
    package static let compactControlHeight: CGFloat = 24
    static let compactBezelVerticalInset: CGFloat = 2.5
    static var compactBezelHeight: CGFloat { compactControlHeight - 2 * compactBezelVerticalInset }
    package static var compactWidth: CGFloat { compactWidth(for: compactTitles) }
    package static var pinWidth: CGFloat { compactWidth(for: ["Pin"], minimumTextWidth: 30) }
    package static func compactWidth(for titles: [String], minimumTextWidth: CGFloat = 54) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        return ceil(max(minimumTextWidth, titles.map { NSAttributedString(string: $0, attributes: attributes).size().width }.max() ?? 0) + compactHorizontalPadding)
    }
    static func configureCompact(_ button: AudioRoundedButton, width: CGFloat? = nil) {
        configureRounded(button)
        button.widthAnchor.constraint(equalToConstant: width ?? compactWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: compactControlHeight).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    static func setRedText(_ button: NSButton, active: Bool) {
        let color: NSColor? = active ? .systemRed : nil
        let current = button.attributedTitle.length > 0
            ? button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        guard current != color else { return }
        var attributes: [NSAttributedString.Key: Any] = [.font: button.font ?? NSFont.systemFont(ofSize: 12)]
        if let color { attributes[.foregroundColor] = color }
        button.attributedTitle = NSAttributedString(string: button.title, attributes: attributes)
    }

    package static func configureSegments(_ control: NSSegmentedControl) {
        guard !(control.cell is AudioSegmentedCell) else { return }
        let labels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        let widths = (0..<control.segmentCount).map { control.width(forSegment: $0) }
        let enabled = (0..<control.segmentCount).map { control.isEnabled(forSegment: $0) }
        let selected = control.selectedSegment
        let tracking = control.trackingMode
        let size = control.controlSize
        let globallyEnabled = control.isEnabled
        let font = control.font
        let target = control.target
        let action = control.action
        let cell = AudioSegmentedCell(textCell: "")
        cell.segmentCount = labels.count
        cell.trackingMode = tracking
        control.cell = cell
        for (index, label) in labels.enumerated() {
            control.setLabel(label, forSegment: index)
            control.setWidth(widths[index], forSegment: index)
            control.setEnabled(enabled[index], forSegment: index)
        }
        control.selectedSegment = selected
        control.target = target; control.action = action
        control.segmentStyle = .rounded
        control.controlSize = size
        control.font = font
        control.isEnabled = globallyEnabled
        control.focusRingType = .exterior
    }

    package static func usesNativeSelectionAppearance(_ control: NSSegmentedControl) -> Bool {
        guard let cell = control.cell as? AudioSegmentedCell else { return true }
        return cell.emphasizedSelectedSegment == nil && !cell.normalSelectionNeedsActiveColors(in: control)
    }

    /// Selection coloring retains native labels, focus, and accessibility.
    package static func setOffSelected(_ control: NSSegmentedControl, selected: Bool, segment: Int = 2, retainInactiveColor: Bool = false) {
        configureSegments(control)
        (control.cell as? AudioSegmentedCell)?.emphasizedSelectedSegment = selected ? segment : nil
        (control.cell as? AudioSegmentedCell)?.selectionIsWarning = false
        (control.cell as? AudioSegmentedCell)?.retainsOffColor = selected && retainInactiveColor
        refreshSelectionAppearance(control)
    }

    package static func setDirectSelected(_ control: NSSegmentedControl, selected: Bool) {
        configureSegments(control)
        (control.cell as? AudioSegmentedCell)?.emphasizedSelectedSegment = selected ? 1 : nil
        (control.cell as? AudioSegmentedCell)?.selectionIsWarning = selected
        (control.cell as? AudioSegmentedCell)?.retainsOffColor = false
        refreshSelectionAppearance(control)
    }

    package static func selectionIsActive(_ control: NSSegmentedControl) -> Bool {
        windowUsesActiveAppearance(control.window)
    }

    package static func windowIsActive(_ window: NSWindow?) -> Bool {
        if let fixture = window as? AudioFocusVerificationWindow { return fixture.focusedForVerification }
        return NSApp.isActive && (window?.isKeyWindow == true || window?.isMainWindow == true)
    }

    package static func refreshSelectionAppearance(_ control: NSSegmentedControl) {
        let cell = control.cell as? AudioSegmentedCell
        let selected = cell?.emphasizedSelectedSegment != nil
        let color: NSColor? = cell?.selectionIsWarning == true ? .systemOrange
            : (selected && (selectionIsActive(control) || cell?.retainsOffColor == true) ? AudioMuteButton.activeFill : nil)
        if control.selectedSegmentBezelColor != color { control.selectedSegmentBezelColor = color }
        control.needsDisplay = true
    }

}

/// Native drawing supplies the shared base. Selected segment overlays preserve
/// policy emphasis or explicitly requested inactive colors; tracking stays native.
@MainActor private final class AudioSegmentedCell: NSSegmentedCell {
    var emphasizedSelectedSegment: Int?
    var selectionIsWarning = false
    var retainsOffColor = false
    func normalSelectionNeedsActiveColors(in controlView: NSView) -> Bool {
        emphasizedSelectedSegment == nil && AudioControlStyle.keepActiveColors
            && !AudioControlStyle.windowIsActive(controlView.window)
            && selectedSegment >= 0 && isEnabled && isEnabled(forSegment: selectedSegment)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let restoresNormalSelection = normalSelectionNeedsActiveColors(in: controlView)
        guard let overlaySegment = emphasizedSelectedSegment ?? (restoresNormalSelection ? selectedSegment : nil) else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        let active = AudioControlStyle.windowUsesActiveAppearance(controlView.window)
        // Render the same unselected base used by Auto and On, then color only
        // the selected segment. Never replace the entire control's background.
        let wasSelected = isSelected(forSegment: overlaySegment)
        setSelected(false, forSegment: overlaySegment)
        super.draw(withFrame: cellFrame, in: controlView)
        setSelected(wasSelected, forSegment: overlaySegment)
        let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let dark = controlView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let widths = (0..<segmentCount).map { width(forSegment: $0) }
        let total = widths.reduce(0, +)
        var x = rect.minX
        for segment in 0..<segmentCount {
            let fraction = total > 0 ? widths[segment] / total : 1 / CGFloat(segmentCount)
            let segmentRect = NSRect(x: x, y: rect.minY, width: rect.width * fraction, height: rect.height)
            x = segmentRect.maxX
            let enabled = isEnabled && isEnabled(forSegment: segment)
            let selected = segment == overlaySegment && isSelected(forSegment: segment)
            guard selected else { continue }
            let fill = restoresNormalSelection ? NSColor.controlAccentColor : selectionIsWarning ? NSColor.systemOrange
                : (active || retainsOffColor ? AudioMuteButton.activeFill : NSColor(white: dark ? 0.34 : 0.80, alpha: 1))
            fill.withAlphaComponent(enabled ? 1 : 0.5).setFill()
            NSBezierPath(roundedRect: segmentRect, xRadius: 4, yRadius: 4).fill()
            let color: NSColor = selectionIsWarning || active || retainsOffColor ? .white : .labelColor
            let text = NSAttributedString(string: label(forSegment: segment) ?? "", attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: color.withAlphaComponent(enabled ? 1 : 0.65)])
            let size = text.size()
            text.draw(in: NSRect(x: segmentRect.midX - size.width / 2, y: segmentRect.midY - size.height / 2,
                                width: size.width, height: size.height))
        }
        // Keyboard focus is separate from policy selection. Pointer opening does
        // not choose a first responder; keyboard navigation retains this ring.
        if showsFirstResponder, controlView.window?.firstResponder === controlView {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            outline.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// NSButton supplies native action tracking, keyboard activation and focus.
/// The shared bezel makes neutral 0 dB and Mute identical in every appearance.
@MainActor package class AudioRoundedButton: NSButton {
    package var displayedTitle: String { title }
    var isDarkAppearance: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    package var neutralFill: NSColor { NSColor(white: isDarkAppearance ? 0.24 : 0.92, alpha: 1) }
    package var fillColor: NSColor { neutralFill }
    package var foregroundColor: NSColor { .labelColor }
    var borderColor: NSColor { .separatorColor }
    var borderWidth: CGFloat { 0.5 }
    package var bezelRect: NSRect { bounds.insetBy(dx: 0.5, dy: AudioControlStyle.compactBezelVerticalInset) }
    package override var focusRingMaskBounds: NSRect { bezelRect }
    package override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bezelRect, xRadius: 5, yRadius: 5).fill()
    }
    package override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bezelRect, xRadius: 5, yRadius: 5)
        var fill = fillColor
        if !isEnabled { fill = fill.blended(withFraction: 0.5, of: neutralFill) ?? fill }
        if isHighlighted { fill = fill.blended(withFraction: 0.14, of: .black) ?? fill }
        fill.setFill(); path.fill()
        borderColor.withAlphaComponent(isEnabled ? 1 : 0.45).setStroke()
        path.lineWidth = borderWidth; path.stroke()
        let text = NSAttributedString(string: displayedTitle, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: isEnabled ? foregroundColor : foregroundColor.withAlphaComponent(0.5)])
        let size = text.size()
        text.draw(at: NSPoint(x: bezelRect.midX - size.width / 2, y: bezelRect.midY - size.height / 2))
    }
}

/// Pin is an ongoing panel policy, so its blue state remains visible on blur.
@MainActor package final class AudioPinButton: AudioRoundedButton {
    package override var fillColor: NSColor { state == .on ? .systemBlue : neutralFill }
    package override var foregroundColor: NSColor { state == .on ? .white : .labelColor }
}

/// Native tri-state state and accessibility remain authoritative.
@MainActor package final class AudioMuteButton: AudioRoundedButton {
    package static let activeFill = NSColor(srgbRed: 0.75, green: 0.08, blue: 0.12, alpha: 1)
    package var channelMuted = false {
        didSet { if channelMuted != oldValue { needsDisplay = true } }
    }
    package override var displayedTitle: String { state == .mixed ? "Mixed" : "Mute" }
    package override var fillColor: NSColor { state == .on ? Self.activeFill : neutralFill }
    package override var foregroundColor: NSColor { state == .on ? .white : (state == .mixed && channelMuted ? Self.activeFill : .labelColor) }
    override var borderColor: NSColor { state == .mixed && channelMuted ? Self.activeFill : .separatorColor }
    override var borderWidth: CGFloat { state == .mixed && channelMuted ? 1.5 : 0.5 }
}

extension AudioControlStyle {
    package static func setMuteState(_ button: AudioMuteButton, state: NSControl.StateValue) {
        guard button.state != state else { return }
        button.state = state
        button.needsDisplay = true
    }
}

/// Restart shares the action bezel while its text follows panel focus.
@MainActor package final class AudioRestartButton: AudioRoundedButton {
    package override var foregroundColor: NSColor {
        AudioControlStyle.windowUsesActiveAppearance(window) ? .systemRed : .labelColor
    }
    package func refreshAppearance() {
        AudioControlStyle.setRedText(self, active: AudioControlStyle.windowUsesActiveAppearance(window))
        needsDisplay = true
    }
    package override func draw(_ dirtyRect: NSRect) {
        AudioControlStyle.setRedText(self, active: AudioControlStyle.windowUsesActiveAppearance(window))
        super.draw(dirtyRect)
    }
}
