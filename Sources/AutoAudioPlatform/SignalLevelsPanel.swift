import AppKit
import AutoAudioCore

/// No timer or animation. Received samples update the meters and numeric readings.
@MainActor package final class SignalLevelsPanel: NSView {
    package var onToggle: ((Bool) -> Void)?
    package var onNumericModeChange: ((SignalMeterNumericMode) -> Void)?
    package var onRetry: (() -> Void)?
    var onLayout: (() -> Void)?
    private let stack = NSStackView()
    private let toggle = NSButton(title: "Live Metering", target: nil, action: nil)
    private let retry = AudioRoundedButton(title: "Retry", target: nil, action: nil)
    private var disclosureWidth: NSLayoutConstraint!
    package let body = SignalMeterInteractionStack()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var rows: [SignalMeterRow] = []
    private var axis: SignalMeterAxis?
    private var displayRange = SignalMeterDisplayRange()
    private var numericMode = SignalMeterNumericMode.realtime
    private var latestSnapshot: SignalLevelsSnapshot?
    private var heldNumericPeaks: [Double?] = []
    private var unavailableNumericPeaks: [Double?] = []
    private var heldIdentity: [String] = []
    private var readingProfileID: String?
    private var readingReady = true
    private var identity: [String] = []
    // Session-only channel labels, never cached audio or persisted policy.
    private var topologyByProfile: [String?: [String]] = [:]
    private var wasEnabled = false
    private var message = ""
    package func refreshFocusAppearance() {
        refreshDisclosureAppearance()
        axis?.refreshFocusAppearance()
        for row in rows { row.refreshFocusAppearance() }
    }
    package var metersVisible: Bool { !body.isHidden }
    package var channelLabels: [String] { identity }
    package var groupGap: CGFloat? {
        let inputs = identity.filter { $0.hasPrefix("IN: ") }.count
        guard inputs > 0, inputs < rows.count else { return nil }
        return body.customSpacing(after: rows[inputs - 1])
    }
    package var rowIdentities: [ObjectIdentifier] { rows.map(ObjectIdentifier.init) }
    package var statusMessage: String { message }
    package var numericAvailability: [Bool] { rows.map(\.numericAvailable) }
    package var numericPeaks: [String] { rows.map(\.numericPeak) }
    package var clippedNumericPeaks: [Bool] { rows.map(\.numericClipped) }
    package var numericPeakHelp: [String] { rows.map(\.numericPeakHelp) }
    package var numericControlIdentities: [ObjectIdentifier] { (axis.map { [$0.numericControlIdentity] } ?? []) + rows.map(\.numericControlIdentity) }
    package var disclosureForVerification: NSButton { toggle }
    package var displayedMeterValues: [[Double]] { rows.map(\.displayedMeterValues) }
    package var numericModeCaption: String { numericMode.title }
    package var numericCaption: NSAttributedString? { axis?.numericCaption }
    package var numericCaptionAccessibilityValue: String? { axis?.numericCaptionAccessibilityValue }
    package func clickNumericHeading() { axis?.clickUnit() }
    package func clickNumericReading(at index: Int) { rows[index].clickNumber() }
    package func setReadingContext(profileID: String?, ready: Bool, refreshInteraction: Bool = true) {
        if readingProfileID != profileID {
            heldNumericPeaks = []; heldIdentity = []; unavailableNumericPeaks = []
        } else if !ready {
            if !heldNumericPeaks.isEmpty { unavailableNumericPeaks = heldNumericPeaks }
            heldNumericPeaks = []; heldIdentity = []
        }
        readingProfileID = profileID
        readingReady = ready
        if refreshInteraction { updateInteractionAvailability() }
    }
    private func updateInteractionAvailability() {
        // Selecting a display mode is local UI state, independent of DSP eligibility.
        body.interactive = latestSnapshot?.enabled == true && !rows.isEmpty
        axis?.setNumericInteractionEnabled(body.interactive)
        for row in rows { row.setNumericInteractionEnabled(body.interactive) }
        let freshness = (latestSnapshot?.inputFreshness ?? []) + (latestSnapshot?.outputFreshness ?? [])
        let available = readingReady && latestSnapshot?.error == nil && latestSnapshot?.levels != nil
            && (freshness.isEmpty || freshness.contains { $0.rmsAvailable || $0.peakAvailable })
        body.alphaValue = available ? 1 : 0.55
    }
    private func toggleNumericMode() {
        guard body.interactive else { return }
        let next: SignalMeterNumericMode = numericMode == .realtime ? .peakHold : .realtime
        if let onNumericModeChange { onNumericModeChange(next) }
        else { setNumericMode(next) }
    }
    /// Apply saved presentation state without issuing another preference change.
    package func setNumericMode(_ mode: SignalMeterNumericMode) {
        guard numericMode != mode else { return }
        numericMode = mode
        heldNumericPeaks = []; heldIdentity = []; unavailableNumericPeaks = []
        if let latestSnapshot { render(latestSnapshot) }
    }
    package override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        AudioControlStyle.configureDisclosure(toggle)
        toggle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toggle.target = self; toggle.action = #selector(toggleChanged)
        toggle.toolTip = "Expand to show input/output meters; collapse to stop reads."
        toggle.setAccessibilityHelp(toggle.toolTip)
        AudioControlStyle.configureCompact(retry)
        retry.target = self; retry.action = #selector(retryPressed); retry.isHidden = true
        let header = NSStackView(views: [toggle, retry])
        header.orientation = .horizontal; header.spacing = 8
        // Hidden Retry must not shorten the header between live and unavailable states.
        header.heightAnchor.constraint(equalToConstant: AudioControlStyle.disclosureHeight).isActive = true
        stack.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        disclosureWidth = toggle.widthAnchor.constraint(equalTo: header.widthAnchor)
        disclosureWidth.isActive = true
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 4
        body.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        body.onActivate = { [weak self] in self?.toggleNumericMode() }
        stack.addArrangedSubview(body); body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.maximumNumberOfLines = 1
        note.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        body.isHidden = true; note.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    package func setDisplayRange(minimumDB: Double, maximumDB: Double) {
        guard minimumDB.isFinite, maximumDB.isFinite, minimumDB < maximumDB,
              (-150...20).contains(minimumDB), (-150...20).contains(maximumDB) else { return }
        let range = SignalMeterDisplayRange(minimumDB: minimumDB, maximumDB: maximumDB)
        guard range != displayRange else { return }
        displayRange = range
        axis?.setDisplayRange(range)
        for row in rows { row.setDisplayRange(range) }
    }
    private func refreshDisclosureAppearance() {
        let expanded = latestSnapshot?.enabled == true
        AudioControlStyle.refreshDisclosure(toggle, expanded: expanded)
        toggle.setAccessibilityLabel(expanded ? "Collapse Live Metering" : "Expand Live Metering")
        toggle.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
    @objc private func toggleChanged() { onToggle?(latestSnapshot?.enabled != true) }
    @objc private func retryPressed() { onRetry?() }
    @discardableResult package func render(_ value: SignalLevelsSnapshot) -> Bool {
        let wasBodyHidden = body.isHidden
        let wasNoteHidden = note.isHidden
        latestSnapshot = value
        refreshDisclosureAppearance()
        retry.isHidden = !value.enabled || value.error == nil
        disclosureWidth.constant = retry.isHidden ? 0 : -(AudioControlStyle.compactWidth + 8)
        let inputs = value.levels?.input ?? []
        let outputs = value.levels?.output ?? []
        let displayed = value.displayLevels ?? value.levels
        let confirmedKeys = inputs.map { "IN: " + $0.label } + outputs.map { "OUT: " + $0.label }
        if value.levels != nil { topologyByProfile[readingProfileID] = confirmedKeys }
        let keys = !value.enabled ? [] : (value.levels != nil ? confirmedKeys : (topologyByProfile[readingProfileID] ?? []))
        let freshness = value.inputFreshness + value.outputFreshness
        let unavailable = value.error != nil || freshness.contains { !$0.rmsAvailable || !$0.peakAvailable }
        let nextMessage = value.enabled && keys.isEmpty && value.levels == nil && !unavailable ? "Waiting for DSP levels…" : ""
        let geometryChanged = wasEnabled != value.enabled || identity != keys
        wasEnabled = value.enabled; message = nextMessage
        if value.enabled, value.error != nil {
            if !heldNumericPeaks.isEmpty { unavailableNumericPeaks = heldNumericPeaks }
        } else { unavailableNumericPeaks = [] }
        if !value.enabled || value.error != nil || (value.levels != nil && heldIdentity != keys) {
            heldNumericPeaks = []; heldIdentity = []
        }
        if identity != keys {
            identity = keys
            for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
            rows = []; axis = nil
            if !keys.isEmpty {
                let axis = SignalMeterAxis(frame: .zero)
                self.axis = axis; axis.setDisplayRange(displayRange)
                axis.onNumericToggle = { [weak self] in self?.toggleNumericMode() }
                body.addArrangedSubview(axis)
                axis.widthAnchor.constraint(equalTo: body.widthAnchor,
                    constant: -(body.edgeInsets.left + body.edgeInsets.right)).isActive = true
            }
            for key in keys {
                let row = SignalMeterRow(label: key)
                row.setDisplayRange(displayRange)
                row.onNumericToggle = { [weak self] in self?.toggleNumericMode() }
                rows.append(row); body.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: body.widthAnchor,
                    constant: -(body.edgeInsets.left + body.edgeInsets.right)).isActive = true
            }
            let inputCount = keys.prefix { $0.hasPrefix("IN: ") }.count
            if inputCount > 0 && inputCount < keys.count {
                body.setCustomSpacing(8, after: rows[inputCount - 1])
            }
        }
        let displays = (displayed?.input ?? inputs) + (displayed?.output ?? outputs)
        let latestLevels = inputs + outputs
        if numericMode == .peakHold, readingReady, value.enabled, value.error == nil, value.levels != nil {
            heldIdentity = keys
            if heldNumericPeaks.count != latestLevels.count { heldNumericPeaks = Array(repeating: nil, count: latestLevels.count) }
            for (index, level) in latestLevels.enumerated() {
                let peakAvailable = index >= freshness.count || freshness[index].peakAvailable
                guard peakAvailable, heldNumericPeaks[index] == nil || level.peakUpdated else { continue }
                heldNumericPeaks[index] = max(heldNumericPeaks[index] ?? level.peakDB, level.peakDB)
            }
        }
        axis?.setNumericMode(numericMode)
        if value.levels == nil {
            for row in rows { row.showWaiting(mode: numericMode) }
        }
        let timedPeaks = (value.numericPeakLevels?.input ?? inputs) + (value.numericPeakLevels?.output ?? outputs)
        for (index, pair) in zip(rows, inputs + outputs).enumerated() {
            let retainedPeak = numericMode == .peakHold ?
                (index < unavailableNumericPeaks.count ? unavailableNumericPeaks[index] : nil) ??
                (index < heldNumericPeaks.count ? heldNumericPeaks[index] : nil) : nil
            pair.0.update(pair.1, displayed: index < displays.count ? displays[index] : pair.1,
                          numericPeak: retainedPeak ?? (index < timedPeaks.count ? timedPeaks[index].peakDB : pair.1.peakDB), mode: numericMode,
                          freshness: !readingReady || value.error != nil ? .init(rmsAvailable: false, peakAvailable: false) :
                            (index < freshness.count ? freshness[index] : .init(rmsAvailable: true, peakAvailable: true)))
        }
        if note.stringValue != nextMessage { note.stringValue = nextMessage }
        // Known channel rows retain their geometry without a blank status footer.
        // Empty stacks retain their edge insets in native fitting calculations,
        // so an expanded disclosure must not expose a body with no channel rows.
        body.isHidden = !value.enabled || keys.isEmpty
        note.isHidden = !value.enabled || nextMessage.isEmpty || !keys.isEmpty
        note.textColor = .secondaryLabelColor
        note.toolTip = value.error
        updateInteractionAvailability()
        body.toolTip = unavailable || !readingReady || value.levels == nil ? "Meter readings unavailable. " + numericMode.help : numericMode.help
        body.setAccessibilityHelp(body.toolTip)
        return geometryChanged || wasBodyHidden != body.isHidden || wasNoteHidden != note.isHidden
    }
}

/// Non-control meter surfaces share one click target. Native readout buttons
/// retain their own tracking/accessibility; scrolling stays in the responder chain.
@MainActor package final class SignalMeterInteractionStack: NSStackView {
    package var interactive = false { didSet { if !interactive { clickOrigin = nil } } }
    var onActivate: (() -> Void)?
    private var clickOrigin: NSPoint?
    package override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard interactive, !isHidden, bounds.contains(convert(point, from: superview)) else { return hit }
        var candidate = hit
        while let view = candidate, view !== self {
            if view is NSButton { return hit }
            candidate = view.superview
        }
        return self
    }
    package override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        clickOrigin = convert(event.locationInWindow, from: nil)
    }
    package override func mouseDragged(with event: NSEvent) { clickOrigin = nil }
    package override func mouseUp(with event: NSEvent) {
        defer { clickOrigin = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard interactive, let start = clickOrigin, bounds.contains(point),
              abs(start.x - point.x) <= 4, abs(start.y - point.y) <= 4 else { return }
        onActivate?()
    }
}

private extension SignalMeterNumericMode {
    var next: String { self == .realtime ? "Peak Hold" : "Realtime" }
    var help: String {
        let meaning = self == .realtime ? "Numbers hold fresh peaks for the configured Number hold time. Higher peaks appear immediately; lower peaks wait until expiry. Zero hold shows the latest fresh peak." : "Numbers and peak markers hold the maximum observed peak until returning to Realtime. Live Metering Off, a read error, or an audio profile or readiness change resets it. Closing the menu preserves captured peaks; no levels are read while closed."
        return "\(title). \(meaning) Activate to switch all channel numbers and peak markers to \(next). RMS bars retain their configured falloff; Realtime markers use the configured Peak hold time."
    }
}

package struct SignalMeterDisplayRange: Equatable {
    package var minimumDB: Double
    package var maximumDB: Double
    package init(minimumDB: Double = -96.0, maximumDB: Double = 6.0) {
        self.minimumDB = minimumDB; self.maximumDB = maximumDB
    }
    package func unitPosition(_ db: Double) -> CGFloat {
        CGFloat(min(1, max(0, (db - minimumDB) / (maximumDB - minimumDB))))
    }
    package var prioritizedTicks: [Double] {
        let canonical = [0.0, -144, -120, -96, -72, -60, -48, -36, -24, -18, -12, -6, 6, 12, 20]
        var result = [minimumDB, maximumDB]
        for db in canonical where db >= minimumDB && db <= maximumDB {
            if !result.contains(where: { abs($0 - db) < 1e-9 }) { result.append(db) }
        }
        return result
    }
    package func label(_ db: Double) -> String {
        let formatted = String(format: "%g", db)
        return db > 0 ? "+" + formatted : formatted.replacingOccurrences(of: "-", with: "−")
    }
}

/// Uses the same column widths and scale as the rows, so resizing keeps ticks aligned.
@MainActor private final class SignalMeterAxis: NSStackView {
    private let scale = SignalMeterScale()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let unit = NSButton(title: "dBFS", target: nil, action: nil)
    var onNumericToggle: (() -> Void)?
    private var mode = SignalMeterNumericMode.realtime
    private var modeColor: NSColor {
        AudioControlStyle.windowUsesActiveAppearance(window) ? (mode == .realtime ? .systemGreen : .systemOrange) : .labelColor
    }
    func refreshFocusAppearance() { setNumericMode(mode) }
    var numericControlIdentity: ObjectIdentifier { ObjectIdentifier(unit) }
    func clickUnit() { unit.performClick(nil) }
    var numericCaption: NSAttributedString { title.attributedStringValue }
    var numericCaptionAccessibilityValue: String? { unit.accessibilityValue() as? String }
    func setNumericInteractionEnabled(_ enabled: Bool) { unit.isEnabled = enabled }
    @objc private func numericPressed() { onNumericToggle?() }
    func setNumericMode(_ mode: SignalMeterNumericMode) {
        self.mode = mode
        let caption = NSMutableAttributedString(string: "RMS / Peak\n" + mode.title, attributes: [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.labelColor])
        caption.addAttribute(.font, value: NSFont.systemFont(ofSize: 10),
                             range: NSRange(location: 0, length: "RMS / Peak".utf16.count))
        caption.addAttribute(.foregroundColor, value: modeColor,
                             range: NSRange(location: "RMS / Peak\n".utf16.count, length: mode.title.utf16.count))
        title.attributedStringValue = caption
        unit.toolTip = mode.help
        unit.setAccessibilityLabel("Numeric meter mode, " + mode.title)
        unit.setAccessibilityHelp(mode.help)
        unit.setAccessibilityValue(mode.title)
    }
    func setDisplayRange(_ range: SignalMeterDisplayRange) { scale.setDisplayRange(range) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal; alignment = .centerY; spacing = 6
        title.font = .systemFont(ofSize: 8); title.textColor = .labelColor
        title.maximumNumberOfLines = 2
        title.heightAnchor.constraint(equalToConstant: 24).isActive = true
        title.widthAnchor.constraint(equalToConstant: 95).isActive = true
        scale.heightAnchor.constraint(equalToConstant: 18).isActive = true
        unit.isBordered = false; unit.setButtonType(.momentaryPushIn); unit.alignment = .right
        unit.font = .systemFont(ofSize: 9)
        unit.attributedTitle = NSAttributedString(string: "dBFS", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.labelColor])
        unit.target = self; unit.action = #selector(numericPressed)
        setNumericMode(.realtime)
        unit.widthAnchor.constraint(equalToConstant: 42).isActive = true
        unit.heightAnchor.constraint(equalToConstant: 14).isActive = true
        addArrangedSubview(title); addArrangedSubview(scale); addArrangedSubview(unit)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor package final class SignalMeterScale: NSView {
    private var range = SignalMeterDisplayRange()
    package func setDisplayRange(_ range: SignalMeterDisplayRange) {
        guard self.range != range else { return }
        self.range = range; needsDisplay = true; updateHelp()
    }
    private func updateHelp() {
        toolTip = "Linear dBFS scale from \(range.label(range.minimumDB)) to \(range.label(range.maximumDB)). Cyan at −60 progresses to green by −12; yellow begins at −6 and red at 0."
    }
    package override init(frame: NSRect) { super.init(frame: frame); updateHelp() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    package override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.labelColor]
        var occupied: [NSRect] = []
        // Endpoints remain meaningful for arbitrary configured scales. Hide
        // colliding labels, while retaining their correctly placed tick marks.
        for db in range.prioritizedTicks {
            let x = range.unitPosition(db) * bounds.width
            NSColor.labelColor.setFill()
            NSRect(x: min(bounds.width - 1, x), y: 0, width: 1, height: 3).fill()
            let label = range.label(db) as NSString
            let size = label.size(withAttributes: attributes)
            let rect = NSRect(x: max(0, min(bounds.width - size.width, x - size.width / 2)), y: 4, width: size.width, height: size.height)
            guard !occupied.contains(where: { $0.insetBy(dx: -3, dy: 0).intersects(rect) }) else { continue }
            label.draw(in: rect, withAttributes: attributes); occupied.append(rect)
        }
    }
}

@MainActor private final class SignalMeterRow: NSStackView {
    private let label: NSTextField
    private let bar = SignalMeterBar()
    private let peak = NSButton(title: "", target: nil, action: nil)
    var onNumericToggle: (() -> Void)?
    func clickNumber() { peak.performClick(nil) }
    func setNumericInteractionEnabled(_ enabled: Bool) { peak.isEnabled = enabled }
    func showWaiting(mode: SignalMeterNumericMode) {
        numericAvailable = false; clipped = false; latestNumericPeak = nil
        bar.showWaiting(); bar.alphaValue = 0.4; peak.alphaValue = 0.4
        peak.attributedTitle = NSAttributedString(string: "…", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        peak.toolTip = "Waiting for current DSP levels. " + mode.help
        peak.setAccessibilityValue("Waiting for current DSP levels")
        bar.setAccessibilityValue("Waiting for current DSP levels")
    }
    @objc private func numericPressed() { onNumericToggle?() }
    var numericPeakHelp: String { peak.toolTip ?? "" }
    var numericPeak: String { peak.title }
    private(set) var numericAvailable = true
    private var clipped = false
    private var range = SignalMeterDisplayRange()
    private var latestNumericPeak: Double?
    var numericClipped: Bool { clipped }
    var numericControlIdentity: ObjectIdentifier { ObjectIdentifier(peak) }
    var displayedMeterValues: [Double] { bar.displayedValues }
    func refreshFocusAppearance() { bar.needsDisplay = true }
    func setDisplayRange(_ range: SignalMeterDisplayRange) {
        self.range = range
        bar.setDisplayRange(range)
        if let latestNumericPeak { updateNumericText(latestNumericPeak) }
    }
    private func updateNumericText(_ value: Double) {
        let belowRange = value < range.minimumDB
        let text = belowRange ? "<" + range.label(range.minimumDB) : String(format: "%.1f", value)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: clipped ? NSColor.systemRed : NSColor.labelColor])
        if !peak.attributedTitle.isEqual(to: attributed) { peak.attributedTitle = attributed }
        let accessible = belowRange ? "Below " + range.label(range.minimumDB) : text
        peak.setAccessibilityValue(accessible + " dBFS" + (numericAvailable ? "" : ", unavailable"))
    }
    init(label: String) {
        self.label = NSTextField(labelWithString: label)
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 6
        self.label.font = .systemFont(ofSize: 10)
        self.label.lineBreakMode = .byTruncatingTail
        self.label.widthAnchor.constraint(equalToConstant: 95).isActive = true
        self.label.toolTip = label
        peak.isBordered = false; peak.setButtonType(.momentaryPushIn); peak.alignment = .right
        peak.target = self; peak.action = #selector(numericPressed)
        peak.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        peak.widthAnchor.constraint(equalToConstant: 42).isActive = true
        peak.heightAnchor.constraint(equalToConstant: 14).isActive = true
        addArrangedSubview(self.label); addArrangedSubview(bar); addArrangedSubview(peak)
        bar.heightAnchor.constraint(equalToConstant: 10).isActive = true
        bar.setAccessibilityLabel(label + " displayed RMS and held peak")
        bar.toolTip = "The bar shows RMS with configured falloff. Realtime markers use the configured Peak hold time; Peak Hold markers retain the same maximum as their numbers. Click anywhere in the meter display to switch all numbers and markers between Realtime and Peak Hold."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ level: SignalChannelLevel, displayed: SignalChannelLevel, numericPeak: Double, mode: SignalMeterNumericMode, freshness: SignalChannelFreshness) {
        numericAvailable = freshness.peakAvailable
        bar.alphaValue = freshness.rmsAvailable && freshness.peakAvailable ? 1 : 0.4
        peak.alphaValue = freshness.peakAvailable ? 1 : 0.4
        let markerPeak = mode == .peakHold ? numericPeak : displayed.peakDB
        bar.update(rms: displayed.rmsDB, peak: markerPeak)
        latestNumericPeak = numericPeak
        clipped = numericPeak >= 0
        updateNumericText(numericPeak)
        peak.toolTip = mode.help
        peak.setAccessibilityLabel(label.stringValue + " numeric peak, " + mode.title)
        peak.setAccessibilityHelp(mode.help)
        bar.setAccessibilityValue(String(format: "Latest RMS %.1f, latest peak %.1f; displayed RMS %.1f, held marker %.1f dBFS", level.rmsDB, level.peakDB, displayed.rmsDB, markerPeak) + (freshness.rmsAvailable && freshness.peakAvailable ? "" : "; unavailable components: " + (!freshness.rmsAvailable ? "RMS " : "") + (!freshness.peakAvailable ? "peak" : "")))
    }
}
@MainActor package final class SignalMeterBar: NSView {
    private var rms = -150.0
    private var peak = -150.0
    private var waiting = false
    private var range = SignalMeterDisplayRange()
    package var displayedValues: [Double] { waiting ? [] : [rms, peak] }
    package func setDisplayRange(_ range: SignalMeterDisplayRange) {
        guard self.range != range else { return }
        self.range = range; needsDisplay = true
    }
    func showWaiting() { waiting = true; needsDisplay = true }
    package func update(rms: Double, peak: Double) {
        guard waiting || self.rms != rms || self.peak != peak else { return }
        waiting = false
        self.rms = rms; self.peak = peak; needsDisplay = true
    }
    private func position(_ db: Double) -> CGFloat { range.unitPosition(db) * bounds.width }
    private static let cyan = NSColor(srgbRed: 0.13, green: 0.64, blue: 0.69, alpha: 1)
    private static let green = NSColor(srgbRed: 0.20, green: 0.72, blue: 0.30, alpha: 1)
    private static let yellow = NSColor(srgbRed: 0.95, green: 0.72, blue: 0.17, alpha: 1)
    private static let red = NSColor(srgbRed: 0.90, green: 0.21, blue: 0.21, alpha: 1)
    private static let lowGradient = NSGradient(starting: cyan, ending: green)
    private static func grayscale(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return NSColor(srgbRed: luminance, green: luminance, blue: luminance, alpha: 1)
    }
    private static let inactiveLowGradient = NSGradient(starting: grayscale(cyan), ending: grayscale(green))
    private static let inactiveYellow = grayscale(yellow)
    private func absolutePosition(_ db: Double) -> CGFloat {
        CGFloat((db - range.minimumDB) / (range.maximumDB - range.minimumDB)) * bounds.width
    }
    package override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let focused = AudioControlStyle.windowUsesActiveAppearance(window)
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor(white: dark ? 0.16 : 0.90, alpha: 1).setFill(); track.fill()
        guard !waiting else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        // Every span is intersected in absolute dBFS before mapping to pixels.
        // Cropping the display never stretches the gradient or changes a zone.
        let lowEnd = min(range.maximumDB, -6, rms)
        if lowEnd > range.minimumDB {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: position(lowEnd), height: bounds.height)).addClip()
            (focused ? Self.lowGradient : Self.inactiveLowGradient)?.draw(from: NSPoint(x: absolutePosition(-60), y: 0),
                to: NSPoint(x: absolutePosition(-12), y: 0),
                options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
            NSGraphicsContext.restoreGraphicsState()
        }
        for (low, high, color) in [(-6.0, 0.0, focused ? Self.yellow : Self.inactiveYellow), (0.0, Double.infinity, Self.red)] {
            let visibleLow = max(range.minimumDB, low)
            let visibleHigh = min(range.maximumDB, high, rms)
            guard visibleHigh > visibleLow else { continue }
            let start = position(visibleLow), finish = position(visibleHigh)
            color.setFill(); NSRect(x: start, y: 0, width: finish - start, height: bounds.height).fill()
        }
        for db in range.prioritizedTicks {
            NSColor.labelColor.withAlphaComponent(db == 0 ? 0.30 : 0.09).setFill()
            NSRect(x: min(bounds.width - 1, position(db)), y: 0, width: 1, height: bounds.height).fill()
        }
        if peak >= range.minimumDB {
            let x = min(bounds.width - 2, position(peak))
            // A narrow neutral halo separates the held peak from the RMS fill.
            NSColor.textBackgroundColor.withAlphaComponent(0.55).setFill()
            NSRect(x: x - 1, y: 0, width: 4, height: bounds.height).fill()
            (peak >= 0 ? Self.red : NSColor.labelColor.withAlphaComponent(0.90)).setFill()
            NSRect(x: x, y: 0, width: 2, height: bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
