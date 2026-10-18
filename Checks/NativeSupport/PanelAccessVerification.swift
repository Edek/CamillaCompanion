import AppKit
import AutoAudioCore
import AutoAudioPlatform

/// Ordinary checks retain the standard popover and never show native windows.
@MainActor enum PanelAccessVerification {
    static func syntheticChecks() -> [String: Bool] {
        var commands = 0
        var guiCommands = 0
        var quitCalls = 0
        let menu = MenuBarController(command: { _ in commands += 1; return ControllerReply() },
            guiCommand: { _ in guiCommands += 1; return GUIReply() }, quit: { quitCalls += 1 })
        defer { menu.stop() }
        let host = menu.popover.contentViewController
        let controls = menu.panel
        let meters = menu.liveLevels
        var checks: [String: Bool] = [:]
        var preferences = UIPreferences(liveLevels: true, showMenuBarIcon: false)
        menu.setUIPreferences(preferences, save: { _ in })
        checks["Hidden idle icon retains the standard popover and shared controls"] =
            !menu.item.isVisible && !menu.isShown && !menu.panelVisible
            && menu.popover.contentViewController === host && menu.panel === controls
            && menu.liveLevels === meters && !meters.snapshot.reading

        menu.setPinned(true)
        preferences.showMenuBarIcon = true
        menu.setUIPreferences(preferences, save: { _ in })
        checks["Restoring the icon retains the original popover host and Pin"] =
            menu.item.isVisible && menu.popover.contentViewController === host
            && menu.pinned && menu.popover.behavior == .applicationDefined && !menu.isShown
        preferences.showMenuBarIcon = false
        menu.setUIPreferences(preferences, save: { _ in })
        checks["Repeated icon changes retain one popover without opening it"] =
            !menu.item.isVisible && !menu.isShown && !menu.panelVisible
            && menu.popover.contentViewController === host && menu.pinned

        menu.panelVisible = true
        menu.applicationWillHide(Notification(name: NSApplication.willHideNotification))
        checks["Hiding the application suspends hidden-icon panel meter eligibility"] =
            !menu.meterReaderVisible && !meters.snapshot.reading
        menu.applicationDidUnhide(Notification(name: NSApplication.didUnhideNotification))
        menu.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        menu.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        checks["Closing retains the shared popover while hiding its temporary anchor"] =
            !menu.item.isVisible && !menu.panelVisible && !menu.panelClosing
            && !menu.meterReaderVisible && !meters.snapshot.reading
            && menu.popover.contentViewController === host

        let more = menu.makeMoreMenu()
        let settings = more.items.first { $0.title == "Settings" }
        let quit = more.items.first { $0.title == "Quit and Restore Output" }
        checks["Hidden-icon controls retain Settings and Quit access"] =
            settings?.isEnabled == true && settings?.action != nil && settings?.target === menu
            && quit?.isEnabled == true && quit?.action != nil && quit?.target === menu
        if let quit { menu.menuAction(quit) }
        checks["Hidden-icon Quit reaches the existing quit handler once"] = quitCalls == 1
        checks["Preference and lifecycle changes dispatch no controller or GUI commands"] =
            commands == 0 && guiCommands == 0

        let failing = MenuBarController(command: { _ in commands += 1; return ControllerReply() },
            guiCommand: { _ in guiCommands += 1; return GUIReply() }, quit: {})
        defer { failing.stop() }
        var saveAttempts = 0
        failing.setUIPreferences(UIPreferences(), save: { _ in
            saveAttempts += 1
            throw SwitcherError.message("Fixture preference write failure")
        })
        let settingsWindow = failing.makeSettingsWindow()
        defer { settingsWindow.close() }
        if let toggle = findButton("Show Menu Bar Icon", in: settingsWindow.window?.contentView),
           let action = toggle.action {
            toggle.state = .off
            let dispatched = NSApp.sendAction(action, to: toggle.target, from: toggle)
            checks["Failed preference save preserves the icon and restores the Settings toggle"] =
                dispatched && saveAttempts == 1 && failing.item.isVisible && toggle.state == .on
                && containsText("Fixture preference write failure", in: settingsWindow.window?.contentView)
        } else {
            checks["Failed preference save preserves the icon and restores the Settings toggle"] = false
        }
        return checks
    }

    /// Real popover focus and ordering run only in this finite isolated process.
    /// No service, transport or audio target is configured.
    static func nativeInteractionChecks() async -> [String: Bool] {
        guard ProcessInfo.processInfo.environment["AUTOSWITCH_NATIVE_PANEL_ACCESS_ONLY"] == "1" else {
            return ["Native panel interaction requires its isolated runner": false]
        }
        var commands = 0
        var guiCommands = 0
        let menu = MenuBarController(command: { _ in commands += 1; return ControllerReply() },
            guiCommand: { _ in guiCommands += 1; return GUIReply() }, quit: {})
        defer { menu.stop() }
        var preferences = UIPreferences(liveLevels: true, showMenuBarIcon: false)
        menu.setUIPreferences(preferences, save: { _ in })
        let host = menu.popover.contentViewController
        let controls = menu.panel
        let meters = menu.liveLevels
        var checks: [String: Bool] = [:]
        func diagnoseFailure(_ scenario: String) {
            guard checks[scenario] == false else { return }
            let window = host?.view.window
            print("Native panel stage: \(scenario)")
            print("  icon=\(menu.item.isVisible) popover=\(menu.popover.isShown) panelVisible=\(menu.panelVisible) closing=\(menu.panelClosing) meterVisible=\(menu.meterReaderVisible) reading=\(meters.snapshot.reading)")
            print("  window=\(window?.windowNumber ?? -1) key=\(window?.isKeyWindow == true) visible=\(window?.isVisible == true) appHidden=\(NSApp.isHidden) appActive=\(NSApp.isActive) pinned=\(menu.pinned) animates=\(menu.popover.animates)")
            print("  anchorWindow=\(menu.item.button?.window?.windowNumber ?? -1) hostRetained=\(menu.popover.contentViewController === host) error=\(menu.visibleError ?? "none")")
        }
        checks["Hidden-icon preference starts with its standard popover closed"] =
            !menu.item.isVisible && !menu.isShown && !menu.panelVisible
        diagnoseFailure("Hidden-icon preference starts with its standard popover closed")
        menu.show()
        await settleNativeEvents()
        checks["Hidden-icon show temporarily restores the anchor and opens the usual popover"] =
            menu.item.isVisible && menu.popover.isShown && menu.panelVisible
            && menu.popover.contentViewController === host && menu.panel === controls
        diagnoseFailure("Hidden-icon show temporarily restores the anchor and opens the usual popover")
        let shownWindow = host?.view.window
        menu.show()
        await settleNativeEvents()
        checks["Repeated hidden-icon show focuses the same popover and controller"] =
            menu.item.isVisible && menu.isShown && menu.panelVisible
            && host?.view.window === shownWindow && shownWindow?.isKeyWindow == true
            && menu.panel === controls && menu.liveLevels === meters
        diagnoseFailure("Repeated hidden-icon show focuses the same popover and controller")
        menu.popover.performClose(nil)
        await waitForPanelClose(menu, stage: "temporary anchor close")
        checks["Closing the usual popover hides its temporary anchor and stops meter eligibility"] =
            !menu.item.isVisible && !menu.isShown && !menu.panelVisible
            && !menu.meterReaderVisible && !meters.snapshot.reading
        diagnoseFailure("Closing the usual popover hides its temporary anchor and stops meter eligibility")
        menu.show()
        await settleNativeEvents()
        checks["Hidden-icon show reopens the retained standard popover"] =
            menu.item.isVisible && menu.isShown && menu.panelVisible
            && menu.popover.contentViewController === host
        diagnoseFailure("Hidden-icon show reopens the retained standard popover")

        preferences.showMenuBarIcon = true
        menu.setUIPreferences(preferences, save: { _ in })
        menu.popover.performClose(nil)
        await waitForPanelClose(menu, stage: "restored icon preference close")
        checks["Restoring the icon preference retains the anchor after the popover closes"] =
            menu.item.isVisible && !menu.isShown && !menu.panelVisible
            && menu.popover.contentViewController === host
        diagnoseFailure("Restoring the icon preference retains the anchor after the popover closes")
        menu.show()
        await settleNativeEvents()
        preferences.showMenuBarIcon = false
        menu.setUIPreferences(preferences, save: { _ in })
        await settleNativeEvents()
        checks["Hiding the icon preference preserves the anchor for the already open popover"] =
            menu.item.isVisible && menu.isShown && menu.panelVisible
            && menu.popover.contentViewController === host
        diagnoseFailure("Hiding the icon preference preserves the anchor for the already open popover")
        menu.popover.performClose(nil)
        await waitForPanelClose(menu, stage: "newly hidden icon preference close")
        checks["The temporary anchor hides when a newly hidden-icon popover closes"] =
            !menu.item.isVisible && !menu.isShown && !menu.panelVisible
        diagnoseFailure("The temporary anchor hides when a newly hidden-icon popover closes")

        menu.show()
        await settleNativeEvents()
        NSApp.hide(nil)
        await settleNativeEvents()
        checks["Application hide suspends hidden-icon popover meter eligibility"] =
            NSApp.isHidden && !menu.meterReaderVisible && !meters.snapshot.reading
        diagnoseFailure("Application hide suspends hidden-icon popover meter eligibility")
        menu.show()
        await settleNativeEvents()
        checks["Hidden-icon show unhides the application and restores its usual popover"] =
            !NSApp.isHidden && menu.item.isVisible && menu.isShown && menu.panelVisible
            && menu.popover.contentViewController === host
        diagnoseFailure("Hidden-icon show unhides the application and restores its usual popover")

        let settings = menu.makeSettingsWindow()
        defer { settings.close() }
        menu.setPinned(true)
        menu.prepareForOwnedWindow()
        settings.show()
        await settleNativeEvents()
        checks["Pin keeps the usual hidden-icon popover open beside Settings"] =
            menu.isShown && menu.panelVisible && menu.item.isVisible && menu.pinned
            && menu.popover.behavior == .applicationDefined && settings.window?.isVisible == true
        diagnoseFailure("Pin keeps the usual hidden-icon popover open beside Settings")
        settings.close()
        menu.setPinned(false)
        menu.show()
        await settleNativeEvents()
        menu.prepareForOwnedWindow()
        await waitForPanelClose(menu, stage: "unpinned owned-window close")
        checks["Unpinned owned-window access closes the popover and hides its temporary anchor"] =
            !menu.isShown && !menu.panelVisible && !menu.item.isVisible && !menu.meterReaderVisible
        diagnoseFailure("Unpinned owned-window access closes the popover and hides its temporary anchor")
        for _ in 0..<10 { await Task.yield() }
        checks["Native access lifecycle sends no DSP or GUI commands and starts no meter read"] =
            commands == 0 && guiCommands == 0 && !meters.snapshot.reading
        for (scenario, passed) in checks where !passed { print("Native panel failed: \(scenario)") }
        return checks
    }

    private static func findButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews {
            if let found = findButton(title, in: child) { return found }
        }
        return nil
    }

    private static func containsText(_ text: String, in view: NSView?) -> Bool {
        guard let view else { return false }
        if let field = view as? NSTextField, field.stringValue.contains(text) { return true }
        return view.subviews.contains { containsText(text, in: $0) }
    }

    private static func settleNativeEvents(seconds: TimeInterval = 0.25) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func waitForPanelClose(_ menu: MenuBarController, stage: String) async {
        let began = ProcessInfo.processInfo.systemUptime
        let deadline = began + 2
        let closingWindow = menu.popover.contentViewController?.view.window
        var observedHiddenWindowWhileShown = false
        while true {
            if menu.popover.isShown && closingWindow?.isVisible == false {
                observedHiddenWindowWhileShown = true
            }
            let finished = !menu.popover.isShown && !menu.panelVisible && !menu.panelClosing
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if finished || ProcessInfo.processInfo.systemUptime >= deadline {
                print("Native panel close wait: \(stage), elapsed=\(String(format: "%.3f", elapsed))s finished=\(finished) hiddenWindowWhileShown=\(observedHiddenWindowWhileShown) window=\(closingWindow?.windowNumber ?? -1) windowVisible=\(closingWindow?.isVisible == true)")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
