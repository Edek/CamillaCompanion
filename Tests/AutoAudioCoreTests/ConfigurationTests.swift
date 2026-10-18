import XCTest
@testable import AutoAudioCore

final class ConfigurationTests: XCTestCase {
    private func profile() -> Profile {
        Profile(id: "home", name: "Home", triggerUID: "physical", captureUID: "virtual",
                playbackUID: "physical", launchAgentLabel: "test.home", launchAgentPath: "/tmp/home.plist",
                websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "BlackHole 2ch",
                expectedPlaybackDevice: "Interface")
    }

    func testRejectsSharedRouteAndAmbiguousProfiles() throws {
        var item = profile()
        XCTAssertThrowsError(try ConfigurationLoader.validate(Configuration(profiles: [item, item])))
        item.playbackUID = item.captureUID
        XCTAssertThrowsError(try ConfigurationLoader.validate(Configuration(profiles: [item])))
    }

    func testRejectsRemoteOrMalformedControlEndpoint() {
        for endpoint in ["ws://example.com:1234", "http://127.0.0.1:1234", "ws://127.0.0.1",
                         "ws://user:secret@localhost:1234", "ws://localhost:1234/?command=start"] {
            var item = profile()
            item.websocketURL = endpoint
            XCTAssertThrowsError(try ConfigurationLoader.validate(Configuration(profiles: [item])), endpoint)
        }
    }

    func testLoadsVersionedConfigurationAndExpandsHomePath() throws {
        var item = profile()
        item.launchAgentPath = "~/Library/LaunchAgents/test.home.plist"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(Configuration(profiles: [item])).write(to: file)
        let loaded = try ConfigurationLoader.load(from: file)
        XCTAssertEqual(loaded.profiles[0].launchAgentPath, NSHomeDirectory() + "/Library/LaunchAgents/test.home.plist")
    }
}
