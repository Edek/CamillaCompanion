import AppKit
import AutoAudioCore

/// A nonactivating pill. Only event-triggered coalescing and dismissal deadlines exist.
@MainActor public final class FeedbackHUD {
    private var policy: FeedbackPolicy
    private let settings: FeedbackSettings
    package private(set) var panel: PillPanel?
    package var presentation = FeedbackPresentation()
    package private(set) var coalesce: Task<Void, Never>?
    package private(set) var dismissal: Task<Void, Never>?
    package private(set) var generation = 0
    public init(settings: FeedbackSettings) { self.settings = settings; policy = FeedbackPolicy(settings: settings) }
    public func setSilentMode(_ enabled: Bool) {
        guard policy.silentMode != enabled else { return }
        policy.setSilentMode(enabled)
        if enabled { stop() }
    }
    public func seedOutput(_ uid: String?) { policy.seedOutput(uid) }
    public func receive(_ event: FeedbackEvent) {
        guard let message = policy.message(for: event) else { return }
        // Preserve the complete error display deadline. Keep only the latest
        // success in each category while waiting, rather than a message queue.
        guard presentation.append(message) else { return }
        coalesce?.cancel()
        let token = generation
        coalesce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, self.generation == token, !self.policy.silentMode,
                  let message = self.presentation.takePending() else { return }
            self.coalesce = nil; self.show(message)
        }
    }
    public func preview(isError: Bool = false) {
        show(FeedbackMessage(text: isError ? "CamillaGUI failed" : "Output changed to BlackHole 2ch",
                             symbol: isError ? "exclamationmark.triangle.fill" : "speaker.wave.2.fill", isError: isError))
    }
    public func stop() {
        generation += 1; coalesce?.cancel(); dismissal?.cancel()
        coalesce = nil; dismissal = nil; presentation.reset()
        panel?.orderOut(nil); panel = nil
    }
    private func show(_ message: FeedbackMessage) {
        guard !policy.silentMode else { return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        generation += 1; let token = generation
        presentation.displayed(message)
        dismissal?.cancel()
        // Replacing the panel also isolates old fade completions from new feedback.
        panel?.orderOut(nil)
        let panel = PillPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = .statusBar; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = true
        let label = NSTextField(labelWithString: message.text)
        label.font = .systemFont(ofSize: 14, weight: .medium); label.textColor = .white
        label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        let width = min(max(260, label.intrinsicContentSize.width + 80), screen.visibleFrame.width - 40)
        let height: CGFloat = 52
        let frame = screen.visibleFrame
        let y = settings.position == .center ? frame.midY - height / 2 : frame.minY + max(32, frame.height * 0.18)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: y, width: width, height: height), display: false)
        let content: NSView
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        // The window and outer container stay transparent. NSVisualEffectView
        // requires its own mask image to clip the backdrop compositor reliably.
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        let mask = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            return true
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            content = NSView(frame: bounds)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
            effect.maskImage = mask
            content = effect
        }
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true; content.layer?.cornerRadius = height / 2; content.layer?.masksToBounds = true
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            content.layer?.borderWidth = 1; content.layer?.borderColor = NSColor.white.cgColor
        }
        // Fixed vertical centers and matching horizontal padding keep messages
        // aligned as output and GUI events replace one another.
        let icon = NSImageView(frame: NSRect(x: 20, y: 16, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: message.symbol, accessibilityDescription: nil)
        icon.contentTintColor = message.isError ? .systemYellow : .white
        let labelHeight: CGFloat = 22
        label.frame = NSRect(x: 52, y: (height - labelHeight) / 2, width: width - 72, height: labelHeight)
        content.addSubview(icon); content.addSubview(label)
        container.addSubview(content); panel.contentView = container
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAccessibility.post(element: content, notification: .announcementRequested, userInfo: [
            .announcement: message.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        let duration = message.isError ? settings.errorDurationSeconds : settings.durationSeconds
        dismissal = Task { [weak self, weak panel] in
            do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) } catch { return }
            guard let self, let panel, self.generation == token else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.orderOut(nil) }
            else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18; panel.animator().alphaValue = 0
                } completionHandler: { [weak self, weak panel] in
                    Task { @MainActor in
                        guard let self, self.generation == token, !self.policy.silentMode else { return }
                        panel?.orderOut(nil)
                    }
                }
            }
            self.dismissal = nil
            if let success = self.presentation.dismissed() { self.show(success) }
        }
    }
}
package final class PillPanel: NSPanel {
    package override var canBecomeKey: Bool { false }
    package override var canBecomeMain: Bool { false }
}
