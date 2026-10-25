import AutoAudioPlatform

@MainActor func runInterfaceSettingsChecks() async throws {
    try runPresetFileDuplicationChecks()
    try await runProfileEditorGuidanceChecks()
    let results = InterfaceDeviceBrowserVerification.checks().map { ("Device browser: " + $0.key, $0.value) }
        + (await InterfacesSettingsVerification.checks()).map { ("Profile settings: " + $0.key, $0.value) }
    let failures = results.filter { !$0.1 }.map { $0.0 }.sorted()
    try check(failures.isEmpty, "Interfaces: " + failures.joined(separator: "; "))
}
