import AutoAudioPlatform

@MainActor func runAuxFaderDisplayChecks() async throws {
    let samples = AuxFaderDisplayVerification.samples()
    try check(samples["pending"] == [1: -18, 2: -21], "A committed linked target is displayed immediately")
    try check(samples["old-busy"] == samples["pending"], "Old zero-dB busy snapshots cannot overwrite pending intent")
    try check(samples["confirmed"] == [1: -17.8, 2: -20.8], "Confirmation displays actual DSP values")
    try check(samples["readiness-lost"] == samples["confirmed"], "Readiness loss clears pending intent")
    try check(samples["partial-failure"] == [1: -24, 2: -20.8], "Partial failure displays independently confirmed member values")
    try check(samples["profile-changed"] == [1: 0, 2: 0], "Pending values cannot leak into another profile")
    for (scenario, passed) in AuxFaderDisplayVerification.interactionChecks() {
        try check(passed, "Aux controls remain steady and serialize input: \(scenario)")
    }
    for (scenario, passed) in await AuxFaderDisplayVerification.trimScaleChecks() {
        try check(passed, "Linked trim keeps stable individual slider scale: \(scenario)")
    }
    for (scenario, passed) in await AuxFaderDisplayVerification.liveDragChecks() {
        try check(passed, "Live native Aux drag and precise entry: \(scenario)")
    }
    print("Native Aux display checks: pending intent, confirmation, failures, cancellation, stable controls and mute buttons passed")
}
