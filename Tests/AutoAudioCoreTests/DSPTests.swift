import XCTest
import AutoAudioCore
@testable import AutoAudioPlatform

final class DSPTests: XCTestCase {
    private var profile: Profile {
        Profile(id: "test", name: "Test", triggerUID: "physical", captureUID: "virtual",
                playbackUID: "physical", launchAgentLabel: "example.dsp", launchAgentPath: "/tmp/example.plist",
                websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
    }
    func testReadinessRequiresReadyStateAndSuccessfulEnvelope() throws {
        for state in ["Running", "Paused"] { XCTAssertNoThrow(try DSPReadiness.validateState(state)) }
        for state in ["Inactive", "Starting", "Stalled", "Unknown"] { XCTAssertThrowsError(try DSPReadiness.validateState(state)) }
        let good = Data(#"{"GetState":{"result":"Ok","value":"Paused"}}"#.utf8)
        XCTAssertEqual(try DSPReadiness.value(from: good, command: "GetState") as? String, "Paused")
        for reply in [#"{"GetState":{"result":"Error","value":"Running"}}"#, #"{"GetVersion":{"result":"Ok","value":"Running"}}"#, "garbage"] {
            XCTAssertThrowsError(try DSPReadiness.value(from: Data(reply.utf8), command: "GetState"))
        }
    }
    func testConfigurationRequiresBothExactCoreAudioSelectors() throws {
        func configuration(_ capture: Any, _ playback: Any, type: String = "CoreAudio") throws -> String {
            let object: [String: Any] = ["devices": ["capture": ["type": type, "device": capture], "playback": ["type": type, "device": playback]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        XCTAssertNoThrow(try DSPReadiness.validateConfiguration(configuration("Virtual", "Physical"), profile: profile))
        XCTAssertThrowsError(try DSPReadiness.validateConfiguration(configuration("Virtual", "Wrong"), profile: profile))
        XCTAssertThrowsError(try DSPReadiness.validateConfiguration(configuration(NSNull(), "Physical"), profile: profile))
        XCTAssertThrowsError(try DSPReadiness.validateConfiguration(configuration("Virtual", "Physical", type: "File"), profile: profile))
    }
    @MainActor func testMissingJobIsNotAnyCommandFailure() {
        XCTAssertTrue(LaunchdDSPManager.serviceIsMissing(ProcessResult(status: 113, stdout: "", stderr: "Could not find service \"test\"")))
        XCTAssertFalse(LaunchdDSPManager.serviceIsMissing(ProcessResult(status: 113, stdout: "", stderr: "Could not find domain")))
        XCTAssertFalse(LaunchdDSPManager.serviceIsMissing(ProcessResult(status: 1, stdout: "", stderr: "Operation not permitted")))
    }
    @MainActor func testRunnerCapturesResultWithoutBlocking() async throws {
        let result = try await ProcessRunner.run("/usr/bin/printf", arguments: ["hello"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertEqual(result.stderr, "")
        let failure = try await ProcessRunner.run("/usr/bin/false", arguments: [])
        XCTAssertNotEqual(failure.status, 0)
    }
    @MainActor func testRunnerTimeoutAndCancellationAreFinite() async throws {
        let began = Date()
        do {
            _ = try await ProcessRunner.run("/bin/sleep", arguments: ["20"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(began), 3) }
        let task = Task { try await ProcessRunner.run("/bin/sleep", arguments: ["20"], timeout: 10) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
