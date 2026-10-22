import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runCamillaDSPProtocolChecks() async throws {
    var count = 0
    func expect(_ value: Bool, _ message: String) throws {
        try check(value, message); count += 1
    }
    func rejects(_ message: String, _ operation: () async throws -> Void) async throws {
        var rejected = false
        do { try await operation() } catch { rejected = true }
        try expect(rejected, message)
    }
    func legacy(_ name: String, _ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [name: ["result": "Ok", "value": value]])
    }
    func modern(_ name: String, _ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["reply": name, "result": "Ok", "value": value])
    }
    func object(_ encoded: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(encoded.utf8), options: [.fragmentsAllowed]) as! [String: Any]
    }

    let legacyGetVersion = try CamillaDSPCommand.getVersion.encoded(for: .v4)
    try expect(legacyGetVersion == #""GetVersion""#, "v4 version probe uses the legacy string command")
    let v4Setter = try object(CamillaDSPCommand.setFaderVolume(2, -12.5).encoded(for: .v4))
    try expect((v4Setter["SetFaderVolume"] as? [NSNumber])?.map(\.doubleValue) == [2, -12.5],
               "v4 setter preserves the legacy tuple payload")
    let v5Setter = try object(CamillaDSPCommand.setFaderVolume(2, -12.5).encoded(for: .v5))
    try expect(v5Setter["command"] as? String == "SetFaderVolume" && v5Setter["fader"] as? Int == 2 &&
               v5Setter["value"] as? Double == -12.5,
               "v5 setter uses a command object with named arguments")
    let v5Read = try object(CamillaDSPCommand.readConfigFile("/tmp/a.yaml").encoded(for: .v5))
    try expect(v5Read["command"] as? String == "ReadConfigFile" && v5Read["value"] as? String == "/tmp/a.yaml",
               "v5 config read uses a command object")
    try await rejects("Setter validates fader IDs before encoding") {
        _ = try CamillaDSPCommand.setFaderMute(5, true).encoded(for: .v5)
    }
    try await rejects("Setter validates finite volume before encoding") {
        _ = try CamillaDSPCommand.setFaderVolume(0, .infinity).encoded(for: .v4)
    }

    let faders: [[String: Any]] = [["volume": -12.0, "mute": false]]
    let oldPayload = try legacy("GetFaders", faders)
    let newPayload = try modern("GetFaders", faders)
    let oldBody = try CamillaDSPProtocol.response(oldPayload, command: "GetFaders", dialect: .v4)
    let newBody = try CamillaDSPProtocol.response(newPayload, command: "GetFaders", dialect: .v5)
    try expect((oldBody["value"] as? [[String: Any]])?.first?["volume"] as? Double ==
               (newBody["value"] as? [[String: Any]])?.first?["volume"] as? Double,
               "Both dialects preserve the same meter and fader payload")
    try await rejects("v4 rejects the v5 reply envelope") {
        _ = try CamillaDSPProtocol.response(newPayload, command: "GetFaders", dialect: .v4)
    }
    try await rejects("v5 rejects the legacy reply envelope") {
        _ = try CamillaDSPProtocol.response(oldPayload, command: "GetFaders", dialect: .v5)
    }

    var v4Commands: [String] = []
    let v4 = try await CamillaDSPProtocolSession.connect { command in
        v4Commands.append(command)
        return try legacy("GetVersion", "4.1.3")
    }
    try expect(v4.version.text == "4.1.3" && v4.version.dialect == .v4 && v4Commands == [legacyGetVersion],
               "v4 negotiates with one read-only GetVersion exchange")

    let invalid = try JSONSerialization.data(withJSONObject: ["reply": "Invalid",
        "error": #"invalid type: string "GetVersion", expected internally tagged enum WsCommand at line 1 column 12"#])
    var v5Commands: [String] = []
    let v5 = try await CamillaDSPProtocolSession.connect { command in
        v5Commands.append(command)
        if v5Commands.count == 1 { return invalid }
        return try modern("GetVersion", "5.0.0-beta.2")
    }
    try expect(v5.version.text == "5.0.0-beta.2" && v5.version.dialect == .v5 && v5Commands.count == 2,
               "Only explicit invalid legacy-command response triggers the v5 read-only probe")
    let v5ProbeObject = try object(v5Commands[1])
    try expect(v5Commands[0] == legacyGetVersion && v5ProbeObject["command"] as? String == "GetVersion",
               "v5 fallback changes the probe encoding")
    var writes = 0
    let readOnly = try await CamillaDSPProtocolSession.connect { command in
        if command.contains("SetFader") { writes += 1 }
        return try legacy("GetVersion", "4.1.3")
    }
    try expect(readOnly.version.dialect == .v4 && writes == 0, "Negotiation sends no write commands")

    let pinned4 = try CamillaDSPVersion("4.1.3", dialect: .v4)
    let pinned5 = try CamillaDSPVersion("5.0.0-beta.2", dialect: .v5)
    try v4.requireVersion(pinned4)
    try v5.requireVersion(pinned5)
    try await rejects("Pinned v4 version rejects a v5 session") {
        try v4.requireVersion(pinned5)
    }
    try await rejects("Pinned v5 version rejects a v4 session") {
        try v5.requireVersion(pinned4)
    }

    try await rejects("Unsupported major version is rejected") {
        _ = try await CamillaDSPProtocolSession.connect { _ in try legacy("GetVersion", "6.0.0") }
    }
    try await rejects("Mismatched version and negotiated dialect is rejected") {
        _ = try await CamillaDSPProtocolSession.connect { command in
            if command == legacyGetVersion { return invalid }
            return try modern("GetVersion", "4.1.3")
        }
    }
    var failedProbeCount = 0
    try await rejects("Transport failure during legacy probe is not converted into v5 fallback") {
        _ = try await CamillaDSPProtocolSession.connect { _ in
            failedProbeCount += 1
            throw URLError(.networkConnectionLost)
        }
    }
    try expect(failedProbeCount == 1, "Transport error stops without a second probe")
    var malformedCount = 0
    try await rejects("Malformed response does not trigger a v5 fallback") {
        _ = try await CamillaDSPProtocolSession.connect { _ in
            malformedCount += 1
            return Data(#"{"GetVersion":{"result":"Invalid","value":"unknown"}}"#.utf8)
        }
    }
    try expect(malformedCount == 1, "Non-v5 rejection stops after one version probe")
    var unrelatedInvalidCount = 0
    try await rejects("Unrelated invalid-command response does not trigger v5 fallback") {
        _ = try await CamillaDSPProtocolSession.connect { _ in
            unrelatedInvalidCount += 1
            return try JSONSerialization.data(withJSONObject: ["reply": "Invalid", "error": "Unknown command"])
        }
    }
    try expect(unrelatedInvalidCount == 1, "Fallback is limited to the known legacy GetVersion rejection")
    var unsupportedVersionCommands = 0
    var unsupportedVersionWrites = 0
    try await rejects("Unsupported v5 beta is rejected") {
        _ = try await CamillaDSPProtocolSession.connect { command in
            unsupportedVersionCommands += 1
            if command.contains("SetFader") { unsupportedVersionWrites += 1 }
            if command == legacyGetVersion { return invalid }
            return try modern("GetVersion", "5.0.0-beta.3")
        }
    }
    try expect(unsupportedVersionCommands == 2 && unsupportedVersionWrites == 0,
               "Unsupported v5 beta is rejected after read-only probes and before writes")

    var v4ErrorMessage: String?
    do {
        _ = try CamillaDSPProtocol.response(
            Data(#"{"SetConfigJson":{"result":{"ConfigValidationError":"invalid volume filter"}}}"#.utf8),
            command: "SetConfigJson", dialect: .v4)
    } catch SwitcherError.message(let message) { v4ErrorMessage = message }
    try expect(v4ErrorMessage == "CamillaDSP SetConfigJson: ConfigValidationError: invalid volume filter",
               "v4 structured result preserves the protocol error and detail")
    var v5ErrorMessage: String?
    do {
        _ = try CamillaDSPProtocol.response(
            Data(#"{"reply":"SetConfigJson","result":"ConfigValidationError","message":"invalid volume filter"}"#.utf8),
            command: "SetConfigJson", dialect: .v5)
    } catch SwitcherError.message(let message) { v5ErrorMessage = message }
    try expect(v5ErrorMessage == "CamillaDSP SetConfigJson: ConfigValidationError: invalid volume filter",
               "v5 flat result preserves the protocol error and detail")

    var cachedCommands: [String] = []
    let cached = try await CamillaDSPProtocolSession.connect { command in
        cachedCommands.append(command)
        if command == legacyGetVersion { return invalid }
        if try object(command)["command"] as? String == "GetVersion" { return try modern("GetVersion", "5.0.0-beta.2") }
        return try modern("GetState", "Running")
    }
    _ = try await cached.request(.getState)
    let cachedRequest = try object(cachedCommands[2])
    try expect(cachedCommands.count == 3 && cachedRequest["command"] as? String == "GetState",
               "Session caches its negotiated dialect for typed requests")

    print("CamillaDSP protocol checks: \(count) assertions passed.")
}
