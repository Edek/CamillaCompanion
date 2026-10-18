import AutoAudioPlatform

@MainActor func runWebSocketCleanupChecks() async throws {
    try await WebSocketCleanupVerification.checks()
    print("WebSocket checks passed: graceful Close/TCP teardown, Aux/preset text and binary reads, stalled-read and blocked-upgrade deadlines with confirmed remote TCP teardown, prompt cancellation and replacement, one stalled Aux setter acknowledgment with confirmed teardown and no replay/reconnection, no canceled Aux mutation dispatch, retained meter socket closed on cancel. Fixture expiry never counts as confirmed teardown.")
}
