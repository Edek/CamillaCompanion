import AppKit
import AutoAudioCore

@MainActor private final class AboutContentView: NSView {
    override var isFlipped: Bool { true }
}

/// On-demand application information. Diagnostics use snapshots and local metadata;
/// opening this window never requests DSP commands or starts a polling loop.
@MainActor package final class AboutDiagnosticsWindow: NSWindowController {
    private let stack = NSStackView()
    package let artwork = NSImageView()
    package private(set) var metadataLabels: [NSTextField] = []
    package let descriptionLabel = NSTextField(labelWithString: ApplicationMetadata.description)
    package let disclosure = NSButton(title: "Show Logs", target: nil, action: nil)
    package let diagnostics = NSTextView()
    package let diagnosticsScroll = NSScrollView()
    private var provider: () -> String
    private let openExternalURL: (URL) -> Void
    private let licensesURL: URL?
    package let donateButton = NSButton(title: "Support Development", target: nil, action: nil)
    package let githubButton = NSButton(title: "GitHub", target: nil, action: nil)
    package let licensesButton = NSButton(title: "Licenses", target: nil, action: nil)

    package init(provider: @escaping () -> String,
                 licensesURL: URL? = Bundle.main.url(forResource: "Licenses", withExtension: "txt"),
                 openExternalURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.provider = provider
        self.licensesURL = licensesURL
        self.openExternalURL = openExternalURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About & Diagnostics"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = AboutContentView()
        window.contentView = root
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        let icon = artwork
        icon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: ApplicationMetadata.name)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 54).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 54).isActive = true
        stack.addArrangedSubview(icon)
        let title = NSTextField(labelWithString: ApplicationMetadata.name)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        stack.addArrangedSubview(title)
        let version = NSTextField(labelWithString: "Version \(ApplicationMetadata.version) · \(ApplicationMetadata.buildIdentifier)")
        version.font = .systemFont(ofSize: 11); version.textColor = .secondaryLabelColor
        stack.addArrangedSubview(version)
        let credit = NSTextField(labelWithString: ApplicationMetadata.copyright)
        credit.font = .systemFont(ofSize: 11); credit.textColor = .secondaryLabelColor
        stack.addArrangedSubview(credit)
        metadataLabels = [title, version, credit]
        stack.addArrangedSubview(descriptionLabel)
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        stack.setCustomSpacing(13, after: descriptionLabel)
        for button in [donateButton, githubButton, licensesButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        donateButton.isEnabled = true
        donateButton.action = #selector(openSupport)
        donateButton.toolTip = "Support CamillaCompanion on Ko-fi."
        donateButton.setAccessibilityHelp(donateButton.toolTip)
        githubButton.isEnabled = true
        githubButton.action = #selector(openGitHub)
        githubButton.toolTip = "Open CamillaCompanion on GitHub."
        githubButton.setAccessibilityHelp(githubButton.toolTip)
        licensesButton.isEnabled = licensesURL != nil
        licensesButton.action = #selector(openLicenses)
        licensesButton.toolTip = licensesURL == nil ? "License files are not bundled in this build." : "Read the app and third-party licenses."
        licensesButton.setAccessibilityHelp(licensesButton.toolTip)
        let links = NSStackView(views: [donateButton, githubButton, licensesButton])
        links.orientation = .horizontal; links.spacing = 10
        stack.addArrangedSubview(links)
        stack.setCustomSpacing(13, after: links)
        let separator = NSBox(); separator.boxType = .separator
        addFullWidth(separator)
        disclosure.bezelStyle = .rounded; disclosure.setButtonType(.pushOnPushOff)
        disclosure.focusRingType = .exterior
        disclosure.target = self; disclosure.action = #selector(toggleDiagnostics)
        disclosure.toolTip = "Show or hide the on-demand diagnostic snapshot. This view does not stream live logs."
        disclosure.setAccessibilityLabel("Show Logs")
        disclosure.setAccessibilityHelp(disclosure.toolTip)
        addFullWidth(disclosure)
        diagnostics.setFrameSize(NSSize(width: 362, height: 220))
        diagnostics.isEditable = false; diagnostics.isSelectable = true; diagnostics.isRichText = false
        diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnostics.textContainerInset = NSSize(width: 7, height: 7)
        diagnostics.textContainer?.widthTracksTextView = true
        diagnostics.isHorizontallyResizable = false; diagnostics.isVerticallyResizable = true
        diagnostics.autoresizingMask = [.width]
        diagnostics.setAccessibilityLabel("Diagnostic report")
        diagnosticsScroll.hasVerticalScroller = true; diagnosticsScroll.scrollerStyle = .overlay
        diagnosticsScroll.autohidesScrollers = true
        diagnosticsScroll.borderType = .bezelBorder
        diagnosticsScroll.documentView = diagnostics
        diagnosticsScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        diagnosticsScroll.isHidden = true
        addFullWidth(diagnosticsScroll)
        let copy = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        copy.bezelStyle = .rounded; close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        let actions = NSStackView(views: [copy, close])
        actions.orientation = .horizontal; actions.spacing = 10
        stack.addArrangedSubview(actions)
        resizeToContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func show() {
        readDiagnostics()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    package func readDiagnostics() {
        let text = provider()
        if diagnostics.string != text { diagnostics.string = text }
    }

    @objc package func toggleDiagnostics() {
        let expanded = disclosure.state == .on
        if expanded { readDiagnostics() }
        diagnosticsScroll.isHidden = !expanded
        disclosure.title = expanded ? "Hide Logs" : "Show Logs"
        disclosure.setAccessibilityLabel(disclosure.title)
        resizeToContent()
    }

    package func diagnosticTextForCopy() -> String {
        let text = provider()
        if diagnostics.string != text { diagnostics.string = text }
        return text
    }

    @objc private func copyDiagnostics() {
        let text = diagnosticTextForCopy()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func closeWindow() { close() }

    @objc private func openSupport() { openExternalURL(ApplicationMetadata.supportURL) }

    @objc private func openGitHub() { openExternalURL(ApplicationMetadata.githubURL) }

    @objc private func openLicenses() {
        if let licensesURL { openExternalURL(licensesURL) }
    }

    private func resizeToContent() {
        guard let root = window?.contentView else { return }
        for _ in 0..<2 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            let size = NSSize(width: 410, height: ceil(stack.fittingSize.height + 40))
            if root.frame.size != size { window?.setContentSize(size) }
        }
        root.layoutSubtreeIfNeeded()
    }
}
