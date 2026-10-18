import AppKit
import AutoAudioCore
import AutoAudioPlatform

/// Checks-owned scenarios for the menu controller.
@MainActor enum MenuBarVerification {
    static func verifyCompanionDSPModeMapping() async -> [String: Bool] {
        let gate = MenuConcurrentReplyFixture()
        let menu = MenuBarController(command: { await gate.request($0) },
            guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
        defer { menu.stop(); gate.completeOutstanding() }
        let available = ControllerProfile(id: "fixture", name: "Fixture", available: true,
            guiUnavailableReason: "Not configured", gui: nil)
        let unavailable = ControllerProfile(id: "fixture", name: "Fixture", available: false,
            guiUnavailableReason: "Not configured", gui: nil)
        func model(_ mode: AutomationMode, companion: Bool) -> MenuBarPresentation {
            MenuBarPresentation(mode: mode, state: mode == .forceOff ? .idle : .active("fixture"),
                preferredProfileID: "fixture", outputName: "Fixture output", suspended: false,
                released: false, recovering: false, profiles: [companion ? unavailable : available],
                automaticSwitching: !companion)
        }
        func click(_ index: Int) -> Bool {
            let control = menu.panel.dspControl
            control.selectedSegment = index
            guard let action = control.action else { return false }
            return NSApp.sendAction(action, to: control.target, from: control)
        }
        var result: [String: Bool] = [:]
        menu.update(model(.automatic, companion: true))
        let control = menu.panel.dspControl
        result["Saved companion Auto displays On without writing a new policy"] =
            control.segmentCount == 2 && control.label(forSegment: 0) == "On" &&
            control.label(forSegment: 1) == "Off" && control.selectedSegment == 0 && gate.requests.isEmpty
        let savedAutoOnAction = click(0)
        let savedAutoOnArrived = await gate.waitForRequestBounded(0)
        result["Selecting On from saved companion Auto explicitly dispatches On"] = savedAutoOnAction && savedAutoOnArrived &&
            gate.requests.first?.command == .on && gate.requests.first?.profileID == "fixture"
        gate.complete(0, ControllerReply())
        for _ in 0..<20 { await Task.yield() }
        menu.update(model(.forceOn, companion: true))
        let offAction = click(1)
        let offRequestArrived = await gate.waitForRequestBounded(1)
        let gotOff = offAction && offRequestArrived
        result["Companion Off selection dispatches Off for the selected profile"] = gotOff &&
            gate.requests.last?.command == .off && gate.requests.last?.profileID == "fixture"
        gate.complete(1, ControllerReply())
        for _ in 0..<20 { await Task.yield() }
        menu.update(model(.forceOff, companion: true))
        result["Companion Off remains selected at segment 1"] = control.segmentCount == 2 && control.selectedSegment == 1
        let onAction = click(0)
        let onRequestArrived = await gate.waitForRequestBounded(2)
        let gotOn = onAction && onRequestArrived
        result["Companion On selection dispatches On for the selected profile"] = gotOn &&
            gate.requests.last?.command == .on && gate.requests.last?.profileID == "fixture"
        gate.complete(2, ControllerReply())
        for _ in 0..<20 { await Task.yield() }
        menu.update(model(.forceOn, companion: false))
        result["Automatic routing restores Auto/On/Off with On at segment 1"] =
            control.segmentCount == 3 && (0..<3).map({ control.label(forSegment: $0) }) == ["Auto", "On", "Off"] &&
            control.selectedSegment == 1 && control.isEnabled(forSegment: 1)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("camillacompanion-companion-ui-relaunch-\(UUID().uuidString)", isDirectory: true)
        let stateURL = directory.appendingPathComponent("runtime.json")
        let preferencesStore = JSONUIPreferencesStore(runtimeStateURL: stateURL)
        let savedPreferences = UIPreferences(automaticSwitching: false, companionDSPMode: .forceOn,
                                             companionProfileID: "fixture")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try preferencesStore.save(savedPreferences)
            let restoredPreferences = try JSONUIPreferencesStore(runtimeStateURL: stateURL).load()
            let relaunched = MenuBarController(command: { await gate.request($0) },
                guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
            defer { relaunched.stop(); try? FileManager.default.removeItem(at: directory) }
            relaunched.setUIPreferences(restoredPreferences, save: { _ in })
            let offline = MenuBarPresentation(mode: restoredPreferences.companionDSPMode, state: .idle,
                preferredProfileID: restoredPreferences.companionProfileID, outputName: "Fixture output",
                suspended: false, released: false, recovering: false, profiles: [unavailable],
                automaticSwitching: restoredPreferences.automaticSwitching)
            relaunched.update(offline)
            let offlineControl = relaunched.panel.dspControl
            result["Relaunch restores companion On while the selected profile is offline"] =
                restoredPreferences == savedPreferences && offlineControl.segmentCount == 2 &&
                offlineControl.label(forSegment: 0) == "On" && offlineControl.label(forSegment: 1) == "Off" &&
                offlineControl.selectedSegment == 0 && offlineControl.isEnabled(forSegment: 0)
            let reconnected = MenuBarPresentation(mode: restoredPreferences.companionDSPMode, state: .active("fixture"),
                preferredProfileID: restoredPreferences.companionProfileID, outputName: "Fixture output",
                suspended: false, released: false, recovering: false, profiles: [available],
                automaticSwitching: restoredPreferences.automaticSwitching)
            relaunched.update(reconnected)
            result["Reconnect keeps the saved companion On selection"] =
                offlineControl.segmentCount == 2 && offlineControl.selectedSegment == 0 &&
                offlineControl.isEnabled(forSegment: 0)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            result["Relaunch restores companion On while the selected profile is offline"] = false
            result["Reconnect keeps the saved companion On selection"] = false
        }
        return result
    }

    /// Deterministic suspended replies exercise menu authority without DSP or IPC.
    static func verifyRecoveredCommandFeedback() async -> [String: Bool] {
        let gate = MenuConcurrentReplyFixture()
        let menu = MenuBarController(command: { await gate.request($0) },
            guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
        defer { menu.stop() }
        let older = menu.send(.release)
        await gate.waitForRequest(0)
        let newer = menu.send(.resume)
        await gate.waitForRequest(1)
        gate.complete(1, ControllerReply())
        await newer.value
        gate.complete(0, ControllerReply(error: "Superseded routing failure"))
        await older.value
        var result = ["Late failed command cannot replace newer success": menu.commandError == nil]
        let current = menu.send(.resume)
        await gate.waitForRequest(2)
        gate.complete(2, ControllerReply(error: "Current routing failure"))
        await current.value
        result["Current real command failure remains visible"] = menu.visibleError == "Current routing failure"
        return result
    }

    /// Suspended owned commands exercise cache acceptance separately from shared feedback.
    static func verifyPresetCoordinationOrdering() async -> [String: Bool] {
        let path = "/fixture/presets/ready.yml"
        let snapshot = PresetSnapshot(profileID: "fixture", entries: [.init(path: path, title: "Ready fixture preset")],
            activePath: path, activeTitle: "Ready fixture preset", ready: true)
        let signalProfile = Profile(id: "fixture", name: "Fixture", triggerUID: "trigger", captureUID: "capture",
            playbackUID: "playback", launchAgentLabel: "unused", launchAgentPath: "/unused",
            websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
        func model(reconfiguring: Bool = false) -> MenuBarPresentation {
            MenuBarPresentation(mode: .forceOn, state: .active("fixture"), preferredProfileID: "fixture",
                outputName: "Fixture output", suspended: false, released: false, recovering: false,
                profiles: [ControllerProfile(id: "fixture", name: "Fixture", available: true,
                    guiUnavailableReason: "Not configured", gui: nil)], reconfiguringAudio: reconfiguring)
        }
        func makeMenu(_ gate: MenuConcurrentReplyFixture) -> MenuBarController {
            let menu = MenuBarController(command: { await gate.request($0) },
                guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
            menu.setUIPreferences(UIPreferences(presetsFolderPath: "/fixture/presets"), save: { _ in })
            menu.update(model()); menu.updatePresets(snapshot)
            return menu
        }
        func picker(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton,
               popup.itemArray.contains(where: { ($0.representedObject as? String) == path }) { return popup }
            for child in view.subviews { if let popup = picker(in: child) { return popup } }
            return nil
        }
        var result: [String: Bool] = [:]

        do {
            let gate = MenuConcurrentReplyFixture()
            let menu = makeMenu(gate)
            defer { menu.stop(); gate.completeOutstanding() }
            menu.requestPresetRefresh()
            let presetTask = menu.presetRequestTask
            guard await gate.waitForRequestBounded(0) else {
                result["Preset before routing dispatches owned read"] = false; return result
            }
            let routingTask = menu.send(.release)
            guard await gate.waitForRequestBounded(1) else {
                result["Routing after preset dispatches owned command"] = false; return result
            }
            gate.complete(1, ControllerReply()); await routingTask.value
            var changed = snapshot; changed.activeTitle = "Accepted after routing"
            gate.complete(0, ControllerReply(error: "Superseded preset failure", presets: changed))
            await presetTask?.value
            result["Newer routing feedback suppresses preset error without discarding cache"] = menu.commandError == nil
                && menu.presetSnapshot == changed && !menu.presetRequestInFlight

            let olderRoutingTask = menu.send(.resume)
            guard await gate.waitForRequestBounded(2) else {
                result["Routing before preset dispatches owned command"] = false; return result
            }
            menu.requestPresetRefresh()
            let newerPresetTask = menu.presetRequestTask
            guard await gate.waitForRequestBounded(3) else {
                result["Preset after routing dispatches owned read"] = false; return result
            }
            gate.complete(3, ControllerReply(presets: snapshot)); await newerPresetTask?.value
            gate.complete(2, ControllerReply(error: "Superseded routing failure")); await olderRoutingTask.value
            result["Newer preset feedback suppresses older routing error"] = menu.commandError == nil
                && menu.presetSnapshot == snapshot && !menu.presetRequestInFlight
        }

        do {
            let gate = MenuConcurrentReplyFixture()
            let menu = makeMenu(gate)
            defer { menu.stop(); gate.completeOutstanding() }
            menu.requestPresetRefresh()
            let obsoleteTask = menu.presetRequestTask
            guard await gate.waitForRequestBounded(0) else {
                result["Invalidation fixture dispatches original read"] = false; return result
            }
            menu.setUIPreferences(UIPreferences(presetsFolderPath: "/fixture/replacement"), save: { _ in })
            menu.requestPresetRefresh()
            let replacementTask = menu.presetRequestTask
            guard await gate.waitForRequestBounded(1) else {
                result["Invalidation permits replacement before obsolete reply"] = false; return result
            }
            gate.complete(0, ControllerReply(error: "Obsolete folder failure", presets: snapshot)); await obsoleteTask?.value
            result["Obsolete preset reply cannot release replacement lock or restore cache"] = menu.presetRequestInFlight
                && menu.presetSnapshot == nil && menu.commandError == nil && gate.requests.count == 2
            var replacement = snapshot; replacement.activeTitle = "Replacement folder"
            gate.complete(1, ControllerReply(presets: replacement)); await replacementTask?.value
            result["Replacement preset reply retains authority after obsolete completion"] = !menu.presetRequestInFlight
                && menu.presetSnapshot == replacement && menu.commandError == nil

            menu.requestPresetRefresh()
            let errorTask = menu.presetRequestTask
            guard await gate.waitForRequestBounded(2) else {
                result["No-snapshot error fixture dispatches read"] = false; return result
            }
            gate.complete(2, ControllerReply(error: "Read failed without snapshot")); await errorTask?.value
            result["Preset error without snapshot preserves cache and releases lock"] = menu.presetSnapshot == replacement
                && !menu.presetRequestInFlight && menu.commandError == "Read failed without snapshot"

            menu.requestPresetRefresh()
            let reconfigurationTask = menu.presetRequestTask
            guard await gate.waitForRequestBounded(3) else {
                result["Reconfiguration fixture dispatches read"] = false; return result
            }
            menu.update(model(reconfiguring: true))
            var accepted = snapshot; accepted.activeTitle = "Accepted during reconfiguration"
            gate.complete(3, ControllerReply(presets: accepted)); await reconfigurationTask?.value
            let requestCount = gate.requests.count
            menu.requestPresetChange(path)
            result["Same-profile reconfiguration accepts reply while disabling preset interaction"] = menu.presetSnapshot == accepted
                && !menu.presetRequestInFlight && picker(in: menu.panel)?.isEnabled == false
                && gate.requests.count == requestCount
        }

        for lifecycle in ["close", "hide", "stop"] {
            let gate = MenuConcurrentReplyFixture()
            let menu = makeMenu(gate)
            var stopped = false
            defer { if !stopped { menu.stop() }; gate.completeOutstanding() }
            menu.updateSignalTarget(profile: signalProfile, ready: true)
            menu.panelVisible = true
            menu.requestPresetChange(path)
            let changeTask = menu.presetRequestTask
            guard await gate.waitForRequestBounded(0) else {
                result["\(lifecycle) fixture dispatches preset change"] = false; continue
            }
            menu.updateSignalTarget(profile: signalProfile, ready: false)
            menu.updateSignalTarget(profile: signalProfile, ready: true)
            result["\(lifecycle) fixture queues readiness behind preset change"] = menu.presetRefreshPending
                && gate.requests.count == 1 && gate.requests.first?.command == .preset
                && gate.requests.first?.presetPath == path
            if lifecycle == "close" { menu.beginPanelClose() }
            else if lifecycle == "hide" { menu.applicationWillHide(Notification(name: NSApplication.willHideNotification)) }
            else { menu.stop(); stopped = true }
            var changed = snapshot; changed.activeTitle = "Accepted after \(lifecycle)"
            gate.complete(0, ControllerReply(presets: changed)); await changeTask?.value
            // Give an accidentally spawned follow-up task a bounded chance to dispatch.
            for _ in 0..<20 { await Task.yield() }
            result["\(lifecycle) accepts dispatched change and discards queued reread"] = menu.presetSnapshot == changed
                && !menu.presetRequestInFlight && !menu.presetRefreshPending && gate.requests.count == 1
        }
        return result
    }

    static func verifyPresetMenuPreparation() async -> [String: Bool] {
        let gate = MenuPresetReplyFixture()
        let menu = MenuBarController(command: { await gate.request($0) },
            guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
        defer { menu.stop() }
        let profile = ControllerProfile(id: "fixture", name: "Fixture", available: true,
            guiUnavailableReason: "Not configured", gui: nil)
        let model = MenuBarPresentation(mode: .forceOn, state: .active("fixture"),
            preferredProfileID: "fixture", outputName: "Output", suspended: false,
            released: false, recovering: false, profiles: [profile])
        menu.setUIPreferences(UIPreferences(presetsFolderPath: "/fixture/presets"), save: { _ in })
        menu.update(model)
        var external = PresetSnapshot(profileID: "fixture", entries: [.init(path: "/fixture/flat.yml", title: "Flat")],
            activeTitle: "GUI preset", ready: true)
        menu.updatePresets(external)
        let prepared = Task { await menu.panel.onPreparePresetMenu?() }
        await gate.waitUntilRequested()
        external.entries.append(.init(path: "/fixture/warm.yml", title: "Warm", requiresAudioRestart: true))
        gate.complete(ControllerReply(presets: external))
        let opened = await prepared.value
        var result = ["External preset menu opening reads fresh candidates": opened == true
            && gate.requests.count == 1 && menu.presetSnapshot?.activePath == nil
            && menu.presetSnapshot?.entries.count == 2]
        let failedPreparation = Task { await menu.panel.onPreparePresetMenu?() }
        await gate.waitUntilRequested()
        var failed = external; failed.ready = false; failed.error = "GUI transition interrupted inspection"
        gate.complete(ControllerReply(error: failed.error, presets: failed))
        let failedOpened = await failedPreparation.value
        let retry = Task { await menu.panel.onPreparePresetMenu?() }
        await gate.waitUntilRequested()
        gate.complete(ControllerReply(presets: external))
        let retryOpened = await retry.value
        result["Failed external inspection permits a fresh explicit retry"] = failedOpened == false && retryOpened == true
            && menu.presetSnapshot?.ready == true && menu.commandError == nil
        let stale = Task { await menu.panel.onPreparePresetMenu?() }
        await gate.waitUntilRequested()
        let replacement = ControllerProfile(id: "other", name: "Other", available: true,
            guiUnavailableReason: "Not configured", gui: nil)
        menu.update(MenuBarPresentation(mode: .forceOn, state: .active("other"), preferredProfileID: "other",
            outputName: "Output", suspended: false, released: false, recovering: false, profiles: [replacement]))
        gate.complete(ControllerReply(presets: external))
        let staleOpened = await stale.value
        result["Profile change discards old preset opening and identity"] = staleOpened == false && menu.presetSnapshot == nil
        return result
    }

    static func verifyPresetMenuAuthority() async -> [String: Bool] {
        let gate = MenuPresetReplyFixture()
        let controller = MenuBarController(command: { await gate.request($0) },
                                           guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
        defer { controller.stop() }
        let path = "/fixture/presets/ready.yml"
        let snapshot = PresetSnapshot(profileID: "fixture", entries: [PresetEntry(path: path, title: "Ready fixture preset")],
                                      activePath: path, activeTitle: "Ready fixture preset", ready: true)
        func model(id: String = "fixture", available: Bool = true, reconfiguring: Bool = false) -> MenuBarPresentation {
            MenuBarPresentation(mode: .forceOn, state: .active(id), preferredProfileID: id,
                outputName: "Fixture output", suspended: false, released: false, recovering: false,
                profiles: [ControllerProfile(id: id, name: "Fixture", available: available, guiUnavailableReason: "Not configured", gui: nil)],
                reconfiguringAudio: reconfiguring)
        }
        func findPicker(in view: NSView) -> NSPopUpButton? {
            if let picker = view as? NSPopUpButton,
               picker.itemArray.contains(where: { ($0.representedObject as? String) == path }) { return picker }
            for child in view.subviews { if let picker = findPicker(in: child) { return picker } }
            return nil
        }
        controller.setUIPreferences(UIPreferences(presetsFolderPath: "/fixture/presets"), save: { _ in })
        controller.update(model()); controller.updatePresets(snapshot)
        guard let picker = findPicker(in: controller.panel) else { return ["preset authority fixture locates native picker": false] }
        var result = ["ready cached presets enable native picker": picker.isEnabled]
        for (name, unavailable) in [("unavailable", model(available: false)), ("reconfiguring", model(reconfiguring: true))] {
            controller.update(unavailable)
            controller.requestPresetChange(path)
            result["cached presets respect current \(name) DSP authority"] = !picker.isEnabled
                && gate.requests.isEmpty && picker.toolTip == unavailable.refreshAux.reason
            controller.update(model())
            result["cached presets become available after \(name) authority restores"] = picker.isEnabled
                && picker.selectedItem?.representedObject as? String == path
        }
        controller.requestPresetRefresh()
        await gate.waitUntilRequested()
        result["pending preset read stays serialized with busy help"] = !picker.isEnabled
            && controller.presetRequestInFlight && picker.toolTip == "Reading or changing preset…"
        gate.complete(ControllerReply(presets: snapshot))
        await controller.presetRequestTask?.value
        result["completed preset read unlocks same selection"] = !controller.presetRequestInFlight
            && picker.isEnabled && picker.selectedItem?.representedObject as? String == path
        controller.requestPresetRefresh()
        await gate.waitUntilRequested()
        var failed = snapshot; failed.ready = false; failed.error = "Fixture read failure"
        gate.complete(ControllerReply(error: failed.error, presets: failed))
        await controller.presetRequestTask?.value
        result["failed read releases lock for explicit refresh while retaining error"] = !controller.presetRequestInFlight
            && picker.isEnabled && picker.toolTip == failed.error
        controller.updatePresets(snapshot)
        for change in ["profile", "folder"] {
            controller.requestPresetRefresh()
            await gate.waitUntilRequested()
            if change == "profile" { controller.update(model(id: "replacement")) }
            else { controller.setUIPreferences(UIPreferences(presetsFolderPath: "/fixture/other"), save: { _ in }) }
            gate.complete(ControllerReply(presets: snapshot))
            await controller.presetRequestTask?.value
            let requestsBeforeStaleSelection = gate.requests.count
            controller.requestPresetChange(path)
            result["late preset read cannot restore stale cache after \(change) changes"] = !controller.presetRequestInFlight
                && controller.presetSnapshot == nil && picker.isEnabled
                && gate.requests.count == requestsBeforeStaleSelection
            controller.update(model()); controller.updatePresets(snapshot)
        }
        return result
    }

    /// Recover the open preset selector from actual target readiness events.
    /// Owned snapshots and suspended replies avoid audio, service and window mutations.
    static func verifyPresetRestartRefresh() async -> [String: Bool] {
        let gate = MenuPresetReplyFixture()
        let controller = MenuBarController(command: { await gate.request($0) },
                                           guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
        defer { controller.stop() }
        let profile = Profile(id: "fixture", name: "Fixture", triggerUID: "trigger", captureUID: "capture",
                              playbackUID: "playback", launchAgentLabel: "unused", launchAgentPath: "/unused",
                              websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
        let path = "/fixture/presets/ready.yml"
        let snapshot = PresetSnapshot(profileID: profile.id, entries: [PresetEntry(path: path, title: "Ready fixture preset")],
                                      activePath: path, activeTitle: "Ready fixture preset", ready: true)
        let empty = PresetSnapshot(profileID: profile.id)
        var result: [String: Bool] = [:]
        func model(ready: Bool) -> MenuBarPresentation {
            MenuBarPresentation(mode: .automatic, state: ready ? .active(profile.id) : .starting(profile.id),
                preferredProfileID: profile.id, outputName: "Fixture output", suspended: false, released: false, recovering: false,
                profiles: [ControllerProfile(id: profile.id, name: profile.name, available: true, guiUnavailableReason: "Not configured", gui: nil)])
        }
        func publish(ready: Bool, presets: PresetSnapshot) {
            // App publishes presentation, activates presets, then updates the target.
            controller.update(model(ready: ready))
            controller.updatePresets(presets)
            controller.updateSignalTarget(profile: profile, ready: ready)
        }
        func picker(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton,
               popup.itemArray.contains(where: { ($0.representedObject as? String) == path }) { return popup }
            for child in view.subviews { if let popup = picker(in: child) { return popup } }
            return nil
        }
        controller.setUIPreferences(UIPreferences(presetsFolderPath: "/fixture/presets"), save: { _ in })
        publish(ready: true, presets: snapshot)
        guard let popup = picker(in: controller.panel) else { return ["restart fixture finds preset selector": false] }
        result["closed panel readiness performs no preset read"] = gate.requests.isEmpty && !controller.presetRequestInFlight
        controller.panelVisible = true
        publish(ready: false, presets: empty)
        publish(ready: true, presets: empty)
        guard controller.presetRequestInFlight else { result["open restart requests fresh presets"] = false; return result }
        await gate.waitUntilRequested()
        controller.update(model(ready: true)); controller.updateSignalTarget(profile: profile, ready: true)
        result["open restart requests presets once without reopening"] = gate.requests.count == 1
            && gate.requests.last?.command == .presets && !popup.isEnabled && !controller.presetRefreshPending
        gate.complete(ControllerReply(presets: snapshot))
        await controller.presetRequestTask?.value
        result["fresh restart reply restores selector and current preset"] = popup.isEnabled
            && popup.selectedItem?.representedObject as? String == path

        // The old read can finish after readiness has already recovered.
        controller.requestPresetRefresh()
        await gate.waitUntilRequested()
        let oldTask = controller.presetRequestTask
        let reads = gate.requests.count
        publish(ready: false, presets: empty); publish(ready: true, presets: empty)
        controller.updateSignalTarget(profile: profile, ready: true)
        result["recovery coalesces behind pending read"] = controller.presetRefreshPending && gate.requests.count == reads
        gate.complete(ControllerReply(error: "Old read canceled", presets: empty))
        await oldTask?.value
        guard controller.presetRequestInFlight else { result["pending recovery drains after old reply"] = false; return result }
        await gate.waitUntilRequested()
        result["pending recovery drains exactly one fresh read"] = gate.requests.count == reads + 1 && !controller.presetRefreshPending
        gate.complete(ControllerReply(presets: snapshot))
        await controller.presetRequestTask?.value
        result["old canceled reply cannot leave recovered selector disabled"] = popup.isEnabled

        // A busy core snapshot can outlive the readiness event without a menu task.
        publish(ready: false, presets: empty)
        var busy = snapshot; busy.busy = true
        publish(ready: true, presets: busy)
        result["busy snapshot retains one readiness refresh"] = controller.presetRefreshPending && !controller.presetRequestInFlight
        controller.updatePresets(snapshot)
        guard controller.presetRequestInFlight else { result["busy completion drains recovery"] = false; return result }
        await gate.waitUntilRequested()
        var failed = empty; failed.error = "Read failed"
        gate.complete(ControllerReply(error: failed.error, presets: failed))
        await controller.presetRequestTask?.value
        let failedReadCount = gate.requests.count
        for _ in 0..<3 {
            controller.update(model(ready: true)); controller.updateSignalTarget(profile: profile, ready: true)
            controller.updatePresets(failed); await Task.yield()
        }
        result["failed recovery read permits explicit refresh without retry loop"] = popup.isEnabled
            && controller.presetSnapshot?.ready == false
            && !controller.presetRefreshPending && !controller.presetRequestInFlight && gate.requests.count == failedReadCount

        for state in ["closed", "closing", "hidden"] {
            controller.panelVisible = state != "closed"
            controller.panelClosing = state == "closing"
            controller.applicationHidden = state == "hidden"
            publish(ready: false, presets: empty); publish(ready: true, presets: empty)
            result["\(state) panel recovery performs no read"] = gate.requests.count == failedReadCount
                && !controller.presetRequestInFlight && !controller.presetRefreshPending
        }
        controller.panelClosing = false; controller.applicationHidden = false; controller.panelVisible = true
        for state in ["close", "hide"] {
            controller.requestPresetRefresh(); await gate.waitUntilRequested()
            let task = controller.presetRequestTask
            let count = gate.requests.count
            publish(ready: false, presets: empty); publish(ready: true, presets: empty)
            if state == "close" { controller.beginPanelClose() }
            else { controller.applicationWillHide(Notification(name: NSApplication.willHideNotification)) }
            gate.complete(ControllerReply(presets: empty)); await task?.value
            result["\(state) discards queued recovery after old reply"] = gate.requests.count == count
                && !controller.presetRefreshPending && !controller.presetRequestInFlight
            controller.panelClosing = false; controller.applicationHidden = false; controller.panelVisible = true
        }
        return result
    }

    /// Bounded, unshown lifecycle fixture. Uses snapshots only, never a DSP read.
    static func verifyPanelLifecycle() -> [String: Bool] {
        let controller = MenuBarController(command: { _ in ControllerReply(error: "Inert fixture") },
                                           guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
        defer { controller.stop() }
        var checks: [String: Bool] = [:]
        let profile = ControllerProfile(id: "anchor", name: "Anchor", available: true,
            guiUnavailableReason: "GUI not configured", gui: nil, captureUID: "virtual")
        var anchorSizes: [NSSize] = []
        for (output, released, restoring) in [("virtual", false, false), ("physical", true, false),
                                             ("physical", false, true), ("virtual", false, false)] {
            let model = MenuBarPresentation(mode: .automatic, state: .active("anchor"),
                preferredProfileID: "anchor", outputName: output, suspended: false,
                released: released, recovering: false, profiles: [profile],
                outputUID: output, routingRestoring: restoring)
            controller.update(model)
            controller.item.button?.superview?.layoutSubtreeIfNeeded()
            if let button = controller.item.button { anchorSizes.append(button.frame.size) }
        }
        checks["Routing bright/dim transitions retain a fixed status icon anchor"] =
            controller.item.length == NSStatusItem.squareLength && anchorSizes.count == 4
            && anchorSizes.allSatisfy { $0 == anchorSizes.first }
        checks["Panel defaults unpinned"] = !controller.pinned && controller.popover.behavior == .transient
        for pinned in [false, true] {
            controller.setPinned(pinned)
            controller.panelVisible = true
            controller.setChildMenuTracking(true)
            controller.setChildMenuTracking(true)
            controller.setChildMenuTracking(false)
            let nested = controller.popover.behavior == .applicationDefined
            controller.setChildMenuTracking(false)
            checks["Child tracking restores chosen Pin \(pinned)"] = nested
                && controller.popover.behavior == (pinned ? .applicationDefined : .transient)
            controller.panelVisible = true; controller.panelClosing = false
            controller.prepareForOwnedWindow()
            checks["Owned Settings Aux and About windows respect Pin \(pinned)"] = controller.panelVisible == pinned
                && controller.panelClosing == !pinned
                && controller.popover.behavior == (pinned ? .applicationDefined : .transient)
            controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
            controller.applicationWillHide(Notification(name: NSApplication.willHideNotification))
            checks["Hidden app blocks reads with Pin \(pinned)"] = !controller.meterReaderVisible && !controller.liveLevels.snapshot.reading
            controller.applicationDidUnhide(Notification(name: NSApplication.didUnhideNotification))
        }
        controller.panel.metersPanel.setReadingContext(profileID: "fixture", ready: true)
        var snapshot = SignalLevelsSnapshot()
        snapshot.enabled = true; snapshot.reading = true
        snapshot.levels = SignalLevels(input: [.init(label: "Left", rmsDB: -24, peakDB: -6)],
                                       output: [.init(label: "Right", rmsDB: -20, peakDB: -4)])
        controller.renderMeterSnapshot(snapshot)
        let values = controller.panel.metersPanel.displayedMeterValues
        let height = controller.panel.metersPanel.fittingSize.height
        controller.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        controller.renderMeterSnapshot(SignalLevelsSnapshot())
        checks["Close cancels reader eligibility and freezes meter geometry"] = !controller.meterReaderVisible
            && !controller.liveLevels.snapshot.reading && controller.panelClosing
            && controller.panel.metersPanel.displayedMeterValues == values
            && controller.panel.metersPanel.fittingSize.height == height
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        checks["Close completion reconciles meters and retains Pin"] = !controller.panelClosing && controller.pinned
            && controller.panel.metersPanel.displayedMeterValues.allSatisfy(\.isEmpty)
            && controller.panel.metersPanel.numericAvailability.allSatisfy { !$0 }
        controller.panelVisible = true; controller.panelClosing = false
        controller.renderMeterSnapshot(snapshot)
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        checks["Stale close completion leaves reopened panel intact"] = controller.panelVisible
            && controller.panel.metersPanel.displayedMeterValues == values
        controller.togglePanel()
        checks["Status icon explicitly dismisses pinned panel"] = controller.panelClosing && !controller.panelVisible && controller.pinned
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        var escaped = false
        controller.panel.onClose = { escaped = true }
        controller.panel.cancelOperation(nil)
        checks["Escape explicitly dismisses pinned panel"] = escaped && controller.pinned
        let menu = controller.makeMoreMenu()
        checks["More submenu labels have no ellipses"] = menu.items.allSatisfy { !$0.title.contains("…") && !$0.title.contains("...") }
        checks["Quit is red and retains native action"] = menu.items.last?.action == #selector(MenuBarController.menuAction(_:))
            && menu.items.last?.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed
        for change in ["readiness", "profile"] {
            let fixture = MenuBarController(command: { _ in ControllerReply(error: "Inert fixture") },
                                            guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: {})
            defer { fixture.stop() }
            let original = Profile(id: "original", name: "Original", triggerUID: "trigger", captureUID: "capture",
                playbackUID: "playback", launchAgentLabel: "unused", launchAgentPath: "/unused",
                websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
            var replacement = original; replacement.id = "replacement"
            // Opted in but never visible: only synthetic snapshots are rendered,
            // and closing cannot reset history merely by turning Live Levels off.
            fixture.setUIPreferences(UIPreferences(liveLevels: true), save: { _ in })
            fixture.updateSignalTarget(profile: original, ready: true)
            fixture.renderMeterSnapshot(snapshot)
            fixture.panel.metersPanel.clickNumericHeading()
            let captured = fixture.panel.metersPanel.displayedMeterValues
            let capturedNumbers = fixture.panel.metersPanel.numericPeaks
            let capturedAvailability = fixture.panel.metersPanel.numericAvailability
            let capturedHeight = fixture.panel.metersPanel.fittingSize.height
            fixture.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
            if change == "readiness" {
                fixture.updateSignalTarget(profile: original, ready: false)
                fixture.updateSignalTarget(profile: original, ready: true)
            } else {
                fixture.updateSignalTarget(profile: replacement, ready: true)
                fixture.updateSignalTarget(profile: original, ready: true)
            }
            checks["Closing \(change) bounce records reset while freezing pixels and geometry"] =
                fixture.panel.metersPanel.displayedMeterValues == captured
                && fixture.panel.metersPanel.numericPeaks == capturedNumbers
                && fixture.panel.metersPanel.numericAvailability == capturedAvailability
                && fixture.panel.metersPanel.fittingSize.height == capturedHeight
                && !fixture.liveLevels.snapshot.reading
            fixture.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
            var lower = snapshot
            lower.levels = SignalLevels(input: [.init(label: "Left", rmsDB: -40, peakDB: -30)],
                                        output: [.init(label: "Right", rmsDB: -40, peakDB: -30)])
            fixture.renderMeterSnapshot(lower)
            checks["Closing \(change) bounce discards old Peak Hold maxima on next sample"] =
                fixture.panel.metersPanel.numericModeCaption == "Peak Hold"
                && fixture.panel.metersPanel.numericPeaks == ["-30.0", "-30.0"]
        }
        return checks
    }

    /// Exercise the real Settings refresh button and More-menu actions with an
    /// owned unshown window and local fixture. Never opens Finder or routes audio.
    static func verifyAuxRefreshDispatch() async throws -> [String: Bool] {
        let profile = Profile(id: "fixture", name: "Fixture", triggerUID: "trigger", captureUID: "capture",
                              playbackUID: "playback", launchAgentLabel: "unused", launchAgentPath: "/unused",
                              websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "capture", expectedPlaybackDevice: "playback")
        let transport = MenuAuxRefreshFixture()
        let preferences = AuxPreferences(visibleIDs: [1, 3], linkGroups: [[1, 2]])
        let aux = AuxController(transport: transport, loadPreferences: { _ in preferences }, savePreferences: { _, _ in })
        var openedURLs: [URL] = []
        var openSucceeds = true
        var controllerCommands = 0
        let menu = MenuBarController(command: { _ in controllerCommands += 1; return ControllerReply(error: "Inert fixture") },
            guiCommand: { _ in GUIReply(error: "Inert fixture") }, quit: { }, openURL: {
                openedURLs.append($0); return openSucceeds
            })
        defer { menu.stop() }
        let model = MenuBarPresentation(mode: .forceOn, state: .active(profile.id), preferredProfileID: profile.id,
            outputName: "Physical output", suspended: false, released: true, recovering: false,
            profiles: [ControllerProfile(id: profile.id, name: profile.name, available: true,
                                         guiUnavailableReason: nil, gui: nil, captureUID: profile.captureUID)],
            outputUID: profile.playbackUID)
        menu.update(model)
        aux.onChange = { menu.updateAux($0) }
        aux.activate(profile: profile)
        try await aux.refreshForUser()
        var completion: CheckedContinuation<Void, Never>?
        menu.setAuxHandlers(refresh: {
            defer { completion?.resume(); completion = nil }
            try await aux.refreshForUser()
        }, volume: { _, _, _ in }, mute: { _, _, _ in }, preferences: { _ in })
        let before = menu.panel.auxPanel.sliderPositions
        let beforeMain = menu.panel.mainPanel.sliderPositions[0]
        transport.main.volumeDB = -24
        transport.main.muted = true
        transport.faders[0].volumeDB = -42
        transport.faders[1].volumeDB = -47
        transport.faders[2].muted = true
        transport.faders[2].maximumDB = -2
        menu.settingsWindow = menu.makeSettingsWindow()
        let settings = menu.settingsWindow!
        let enabledBefore = settings.faderRefreshEnabled
        let reads = transport.reads
        await withCheckedContinuation { continuation in
            completion = continuation
            if !settings.performFaderRefreshForVerification() { completion?.resume(); completion = nil }
        }
        await Task.yield()
        var result: [String: Bool] = [:]
        result["Settings refresh updates Main without a separate query"] = menu.panel.mainPanel.sliderPositions[0] != beforeMain && menu.panel.mainPanel.displayedVolumes[0] == -24 && menu.panel.mainPanel.displayedMuteStates[0] == NSControl.StateValue.on.rawValue
        result["Settings refresh works in healthy bypass"] = enabledBefore && !model.restartDSP.enabled && transport.reads == reads + 1
        result["Settings refresh moves actual slider and numeric display"] = menu.panel.auxPanel.sliderPositions[1] != before[1]
            && menu.panel.auxPanel.displayedVolumes[1] == -42
        result["Settings refresh updates mute limits and hidden member without setters"] = menu.panel.auxPanel.displayedMuteStates[3] == NSControl.StateValue.on.rawValue
            && menu.auxSnapshot?.faders.first(where: { $0.id == 2 })?.volumeDB == -47
            && menu.auxSnapshot?.faders.first(where: { $0.id == 3 })?.maximumDB == -2 && transport.setters == 0
        result["Settings reports successful refresh"] = settings.faderRefreshResult?.localizedCaseInsensitiveContains("synced") == true
        var busy = aux.snapshot; busy.busy = true; menu.updateAux(busy)
        result["Busy Settings refresh disabled with reason"] = !settings.faderRefreshEnabled && settings.faderRefreshHelp?.contains("Finish") == true
            && !settings.performFaderRefreshForVerification()
        menu.requestAuxRefresh()
        result["Declined refresh reports Settings error without read"] = menu.auxRefreshError?.contains("Finish") == true
            && settings.faderRefreshResult?.contains("Finish") == true && transport.reads == reads + 1
        menu.updateAux(aux.snapshot)
        transport.readError = SwitcherError.message("Fixture read failed")
        await withCheckedContinuation { continuation in
            completion = continuation
            if !settings.performFaderRefreshForVerification() { completion?.resume(); completion = nil }
        }
        await Task.yield()
        result["Read failure reaches Settings after readiness invalidation"] = settings.faderRefreshResult?.contains("Fixture read failed") == true
            && menu.auxRefreshError?.contains("Fixture read failed") == true
        transport.readError = nil
        // App recovery refreshes directly, not through the Settings callback.
        try await aux.refreshForUser()
        result["Fresh recovery retires failed read feedback"] = menu.auxRefreshError == nil
            && menu.visibleError == nil && menu.auxSnapshot?.ready == true
        menu.rejectAuxCommand("Fixture failed mute write")
        try await aux.refreshForUser()
        result["Fresh recovery preserves genuine write failure"] = menu.auxError == "Fixture failed mute write"
            && menu.visibleError == "Fixture failed mute write"
        menu.auxError = nil
        menu.update(MenuBarPresentation(mode: .forceOn, state: .suspended,
            preferredProfileID: profile.id, outputName: "Physical output", suspended: true,
            released: false, recovering: false, profiles: model.profiles, outputUID: profile.playbackUID))
        menu.requestAuxRefresh()
        let unavailableFeedback = menu.auxRefreshError != nil
        menu.update(model)
        aux.activate(profile: profile, ready: false)
        aux.activate(profile: profile, ready: true)
        try await aux.refreshForUser()
        result["Recovered authority retires declined refresh feedback"] = unavailableFeedback
            && menu.auxRefreshError == nil && menu.visibleError == nil
        let more = menu.makeMoreMenu()
        let titles = more.items.filter { !$0.isSeparatorItem }.map(\.title)
        result["More removes duplicate Aux, routing and refresh actions"] = titles == ["Settings", "Open Presets Folder", "About & Diagnostics", "Quit and Restore Output"]
        let noFolder = more.items.first { $0.title == "Open Presets Folder" }!
        result["Missing presets preference disables folder action with reason"] = !noFolder.isEnabled && noFolder.toolTip?.contains("Settings") == true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("camillacompanion-presets-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        menu.setUIPreferences(UIPreferences(presetsFolderPath: folder.path), save: { _ in })
        let folderAction = menu.makeMoreMenu().items.first { $0.title == "Open Presets Folder" }!
        menu.menuAction(folderAction)
        result["Presets folder uses injected URL opener"] = folderAction.isEnabled && openedURLs == [folder.standardizedFileURL]
        openSucceeds = false
        menu.menuAction(folderAction)
        result["Presets open failure reports actionable error"] = menu.commandError?.contains("Could not open the presets folder") == true
        let inactive = MenuBarPresentation(mode: .forceOff, state: .idle, preferredProfileID: profile.id,
            outputName: "Physical output", suspended: false, released: false, recovering: false,
            profiles: [ControllerProfile(id: profile.id, name: profile.name, available: false, guiUnavailableReason: "Unavailable", gui: nil)])
        menu.update(inactive)
        result["Presets folder is independent of DSP and GUI"] = menu.makeMoreMenu().items.first { $0.title == "Open Presets Folder" }!.isEnabled
            && !settings.faderRefreshEnabled && controllerCommands == 0
        menu.update(model)
        let plainFile = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: plainFile)
        for invalid in [plainFile.path, folder.appendingPathComponent("missing").path] {
            menu.setUIPreferences(UIPreferences(presetsFolderPath: invalid), save: { _ in })
            let item = menu.makeMoreMenu().items.first { $0.title == "Open Presets Folder" }!
            result["Reject invalid presets folder " + (invalid == plainFile.path ? "file" : "missing")] = !item.isEnabled && item.toolTip?.contains("directory") == true
        }
        result["Dim icon remains clickable"] = menu.item.button?.isEnabled == true && menu.iconDimmed == true
        return result
    }
}

@MainActor private final class MenuConcurrentReplyFixture {
    private var replies: [Int: CheckedContinuation<ControllerReply, Never>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var count = 0
    private(set) var requests: [ControllerRequest] = []
    func request(_ request: ControllerRequest) async -> ControllerReply {
        let index = count; count += 1
        requests.append(request)
        return await withCheckedContinuation {
            replies[index] = $0
            waiters.removeValue(forKey: index)?.resume()
        }
    }
    func waitForRequest(_ index: Int) async {
        if replies[index] != nil { return }
        await withCheckedContinuation { waiters[index] = $0 }
    }
    func waitForRequestBounded(_ index: Int) async -> Bool {
        for _ in 0..<1_000 {
            if replies[index] != nil { return true }
            await Task.yield()
        }
        return replies[index] != nil
    }
    func complete(_ index: Int, _ reply: ControllerReply) {
        replies.removeValue(forKey: index)?.resume(returning: reply)
    }
    func completeOutstanding() {
        let pending = Array(replies.values)
        replies.removeAll()
        for continuation in pending { continuation.resume(returning: ControllerReply(error: "Fixture cleanup")) }
    }
}

@MainActor private final class MenuPresetReplyFixture {
    private var pendingReply: CheckedContinuation<ControllerReply, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private(set) var requests: [ControllerRequest] = []
    func request(_ request: ControllerRequest) async -> ControllerReply {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            pendingReply = continuation
            startWaiter?.resume(); startWaiter = nil
        }
    }
    func waitUntilRequested() async {
        if pendingReply != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func complete(_ reply: ControllerReply) {
        let continuation = pendingReply; pendingReply = nil
        continuation?.resume(returning: reply)
    }
}

@MainActor private final class MenuAuxRefreshFixture: AuxDSPTransport {
    var main = AuxFader(id: 0, name: "Main Volume", volumeDB: 0, muted: false, maximumDB: 0)
    var faders = [AuxFader(id: 1, name: "Left", volumeDB: -3, muted: false, maximumDB: 0),
                  AuxFader(id: 2, name: "Right", volumeDB: -6, muted: false, maximumDB: 0),
                  AuxFader(id: 3, name: "Sub", volumeDB: 0, muted: false, maximumDB: 0)]
    var reads = 0
    var setters = 0
    var readError: Error?
    func read(profile: Profile) async throws -> AuxDSPState {
        reads += 1
        if let readError { throw readError }
        return AuxDSPState(faders: faders, main: main)
    }
    func setVolume(id: Int, db: Double) async throws { setters += 1 }
    func setMute(id: Int, muted: Bool) async throws { setters += 1 }
    func cancel() { }
}
