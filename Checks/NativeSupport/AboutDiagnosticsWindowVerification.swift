import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor extension AboutDiagnosticsWindow {
    static func verifyOwnedWindow(renderDirectory: URL? = nil) throws -> Bool {
        _ = NSApplication.shared
        var reads = 0
        var openedURLs: [URL] = []
        let resourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("about-licenses-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resourceDirectory) }
        let licensesURL = resourceDirectory.appendingPathComponent("Licenses.txt")
        try Data("Synthetic app and third-party license text".utf8).write(to: licensesURL)
        let controller = AboutDiagnosticsWindow(provider: {
            reads += 1
            return ApplicationMetadata.name + " " + ApplicationMetadata.version + "\nSynthetic diagnostic report \(reads)"
        }, licensesURL: licensesURL, openExternalURL: { openedURLs.append($0) })
        guard let root = controller.window?.contentView else { return false }
        func fits(_ view: NSView) -> Bool {
            let children: [NSView]
            if let stack = view as? NSStackView { children = stack.arrangedSubviews }
            else if view === root { children = view.subviews }
            else { return true }
            return children.filter { !$0.isHidden }.allSatisfy { child in
                let frame = child.convert(child.bounds, to: root)
                return frame.minX >= -1 && frame.maxX <= root.bounds.width + 1
                    && frame.minY >= -1 && frame.maxY <= root.bounds.height + 1 && fits(child)
            }
        }
        func labels(_ view: NSView) -> [String] {
            let children = (view as? NSStackView)?.arrangedSubviews ?? view.subviews
            return ((view as? NSTextField).map { [$0.stringValue] } ?? [])
                + children.flatMap(labels)
        }
        let collapsedHeight = root.frame.height
        var valid = fits(root) && controller.disclosure.title == "Show Logs"
            && controller.disclosure.accessibilityLabel() == "Show Logs"
            && controller.disclosure.focusRingType == .exterior
            && controller.disclosure.bezelStyle == .rounded
            && controller.disclosure.action == #selector(toggleDiagnostics)
            && controller.disclosure.target === controller
        valid = valid && fits(root)
            && controller.descriptionLabel.stringValue == ApplicationMetadata.description
            && controller.donateButton.isEnabled && controller.githubButton.isEnabled
            && controller.licensesButton.isEnabled
            && controller.donateButton.title == "Support Development"
            && controller.donateButton.toolTip == "Support CamillaCompanion on Ko-fi."
            && controller.githubButton.toolTip == "Open CamillaCompanion on GitHub."
            && controller.githubButton.accessibilityHelp() == controller.githubButton.toolTip
            && !labels(root).contains(where: { $0.localizedCaseInsensitiveContains("unavailable") })
        valid = valid && openedURLs.isEmpty && reads == 0
        controller.donateButton.performClick(nil)
        valid = valid && openedURLs.map(\.absoluteString) == ["https://ko-fi.com/camillacompanion"]
            && reads == 0
        controller.githubButton.performClick(nil)
        valid = valid && openedURLs.map(\.absoluteString) == ["https://ko-fi.com/camillacompanion",
            "https://github.com/Edek/CamillaCompanion"] && reads == 0
        controller.licensesButton.performClick(nil)
        valid = valid && openedURLs.count == 3 && openedURLs.last == licensesURL && reads == 0
        let unbundled = AboutDiagnosticsWindow(provider: { reads += 1; return "" },
            licensesURL: nil, openExternalURL: { openedURLs.append($0) })
        unbundled.licensesButton.performClick(nil)
        valid = valid && !unbundled.licensesButton.isEnabled && openedURLs.count == 3 && reads == 0
        unbundled.close()
        controller.readDiagnostics()
        valid = valid && fits(root) && root.frame.height == collapsedHeight
            && controller.diagnostics.string.contains("Synthetic diagnostic report 1")
            && controller.diagnosticsScroll.isHidden
        // Native activation exercises the button's state and action dispatch,
        // shared by pointer, keyboard Space, and accessibility activation.
        controller.disclosure.performClick(nil)
        let expandedHeight = root.frame.height
        valid = valid && fits(root) && !controller.diagnosticsScroll.isHidden && expandedHeight > collapsedHeight
            && controller.disclosure.state == .on && controller.disclosure.title == "Hide Logs"
            && controller.disclosure.accessibilityLabel() == "Hide Logs"
        let expandedText = controller.diagnostics.string
        let copied = controller.diagnosticTextForCopy()
        valid = valid && reads == 3 && copied != expandedText && controller.diagnostics.string == copied
        let centered = controller.artwork.convert(controller.artwork.bounds, to: root)
        valid = valid && abs(centered.midX - root.bounds.midX) <= 1 && controller.artwork.image != nil
            && controller.metadataLabels.map(\.stringValue) == [ApplicationMetadata.name,
                "Version \(ApplicationMetadata.version) · \(ApplicationMetadata.buildIdentifier)", ApplicationMetadata.copyright]
        valid = valid && reads == 3
            && controller.diagnostics.string.contains("Synthetic diagnostic report 3")
        if let renderDirectory, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
            root.cacheDisplay(in: root.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: renderDirectory.appendingPathComponent("about-expanded.png"))
            }
        }
        controller.disclosure.performClick(nil)
        valid = valid && fits(root) && root.frame.height == collapsedHeight && reads == 3
            && controller.disclosure.state == .off && controller.disclosure.title == "Show Logs"
            && controller.disclosure.accessibilityLabel() == "Show Logs"
            && controller.diagnosticsScroll.isHidden
        controller.close()
        return valid
    }

}
