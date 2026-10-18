import XCTest
import AutoAudioCore
import AutoAudioPlatform

final class RouteStoreTests: XCTestCase {
    func testRoundTripAndRemovalPreservesOtherFiles() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("nested/route.json")
            let store = JSONRouteStore(url: url)
            XCTAssertNil(try store.load())
            let record = RouteRecord(profileID: "home", captureUID: "virtual", previousOutputUID: "headphones",
                                     previousAlertUID: "builtin", ownsOutput: true, ownsAlerts: false)
            try store.save(record)
            XCTAssertEqual(try store.load(), record)
            let other = url.deletingLastPathComponent().appendingPathComponent("other.txt")
            try Data("keep".utf8).write(to: other)
            try store.save(nil)
            XCTAssertNil(try store.load())
            XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "keep")
            try store.save(nil)
        }
    }

    func testCorruptStateIsAnErrorNotAnAbsentRecord() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("route.json")
            try Data("{broken".utf8).write(to: url)
            XCTAssertThrowsError(try JSONRouteStore(url: url).load())
        }
    }
    func testRemovalRefusesDirectory() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let child = root.appendingPathComponent("unrelated.txt")
            try Data("keep".utf8).write(to: child)
            XCTAssertThrowsError(try JSONRouteStore(url: root).save(nil))
            XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
        }
    }

}
