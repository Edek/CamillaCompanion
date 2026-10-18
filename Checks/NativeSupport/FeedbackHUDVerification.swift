import AppKit
import AutoAudioCore
import AutoAudioPlatform

/// Synthetic event verification that never displays a pill or announces feedback.
enum FeedbackHUDVerification {
    @MainActor static func silentModeChecks() async -> [String: Bool] {
        await FeedbackHUD.verifySilentMode()
    }
}

extension FeedbackHUD {
    @MainActor static func verifySilentMode() async -> [String: Bool] {
        var settings = FeedbackSettings()
        settings.mode = .allChanges
        let hud = FeedbackHUD(settings: settings)
        defer { hud.stop() }
        hud.receive(.output(uid: "first", name: "Fixture", restored: false))
        hud.receive(.failure(source: "dsp", message: "Fixture failure"))
        let burstScheduled = hud.coalesce != nil
        hud.setSilentMode(true)
        let invalidated = hud.generation
        let cancelled = hud.panel == nil && hud.coalesce == nil && hud.dismissal == nil
        hud.receive(.failure(source: "dsp", message: "Quiet failure"))
        hud.receive(.output(uid: "quiet", name: "Quiet fixture", restored: false))
        hud.preview(isError: true)
        try? await Task.sleep(nanoseconds: 350_000_000)
        let stayedQuiet = hud.panel == nil && hud.coalesce == nil && hud.dismissal == nil
            && hud.generation == invalidated && hud.presentation.takePending() == nil
        hud.setSilentMode(false)
        hud.receive(.output(uid: "quiet", name: "Quiet fixture", restored: false))
        let noReplay = hud.panel == nil && hud.coalesce == nil && hud.dismissal == nil
        var offSettings = FeedbackSettings()
        offSettings.mode = .off
        let disabled = FeedbackHUD(settings: offSettings)
        disabled.setSilentMode(true)
        disabled.setSilentMode(false)
        disabled.receive(.failure(source: "dsp", message: "Failure with feedback configured off"))
        let keptPolicy = disabled.panel == nil && disabled.coalesce == nil && disabled.dismissal == nil
        return ["burst deadline cancelled": burstScheduled && cancelled,
                "quiet errors and previews suppressed with static idle": stayedQuiet,
                "quiet state deduplicated without replay": noReplay,
                "configured off preserved": keptPolicy]
    }
}
