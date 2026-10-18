import AutoAudioPlatform

@MainActor func runAuxSettingsChecks() async throws {
    for (scenario, passed) in await AuxFaderSettingsVerification.stagedSettingsChecks() {
        try check(passed, "Native Aux settings: \(scenario)")
    }
    print("Native Aux settings checks: automatic persistence, validation, floor bounds, visibility, fresh trims and numeric selection passed")
}
