import Foundation
import AutoAudioCore

public enum CamillaDSPDialect: Int, Sendable { case v4 = 4, v5 = 5 }

public struct CamillaDSPVersion: Equatable, Sendable {
    public let text: String
    public let dialect: CamillaDSPDialect

    public init(_ text: String, dialect: CamillaDSPDialect) throws {
        guard text.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
                         options: .regularExpression) != nil,
              let major = Int(text.split(separator: ".")[0]), major == dialect.rawValue,
              (dialect == .v4 && text == "4.1.3") || (dialect == .v5 && text == "5.0.0-beta.2") else {
            throw SwitcherError.message("Unsupported CamillaDSP version or protocol: \(text). Supported versions: 4.1.3 and 5.0.0-beta.2.")
        }
        self.text = text; self.dialect = dialect
    }
}

public struct CamillaDSPVersionChanged: Error, LocalizedError {
    public let previous: CamillaDSPVersion
    public let current: CamillaDSPVersion
    public var errorDescription: String? {
        "CamillaDSP changed from \(previous.text) to \(current.text). Refresh controls before changing DSP settings."
    }
}

/// Only operations used by the companion. Features never construct wire JSON.
public enum CamillaDSPCommand {
    case getVersion, getState, getStopReason, getConfigJson, getConfigFilePath, getFaders, getSignalLevelsSinceLast
    case setFaderVolume(Int, Double), setFaderMute(Int, Bool)
    case readConfigFile(String), readConfigJson(String), validateConfigJson(String)
    case setConfigJson(String), setConfigFilePath(String)

    public var name: String {
        switch self {
        case .getVersion: return "GetVersion"
        case .getState: return "GetState"
        case .getStopReason: return "GetStopReason"
        case .getConfigJson: return "GetConfigJson"
        case .getConfigFilePath: return "GetConfigFilePath"
        case .getFaders: return "GetFaders"
        case .getSignalLevelsSinceLast: return "GetSignalLevelsSinceLast"
        case .setFaderVolume: return "SetFaderVolume"
        case .setFaderMute: return "SetFaderMute"
        case .readConfigFile: return "ReadConfigFile"
        case .readConfigJson: return "ReadConfigJson"
        case .validateConfigJson: return "ValidateConfigJson"
        case .setConfigJson: return "SetConfigJson"
        case .setConfigFilePath: return "SetConfigFilePath"
        }
    }

    public func encoded(for dialect: CamillaDSPDialect) throws -> String {
        var fields: [String: Any] = ["command": name]
        let legacy: Any
        switch self {
        case let .setFaderVolume(id, db):
            guard (0...4).contains(id), db.isFinite, (-150...50).contains(db) else {
                throw SwitcherError.message("Invalid DSP fader volume request")
            }
            fields["fader"] = id; fields["value"] = db
            legacy = [name: [id, db]]
        case let .setFaderMute(id, muted):
            guard (0...4).contains(id) else { throw SwitcherError.message("Invalid DSP fader mute request") }
            fields["fader"] = id; fields["value"] = muted
            legacy = [name: [id, muted]]
        case let .readConfigFile(value), let .readConfigJson(value), let .validateConfigJson(value),
             let .setConfigJson(value), let .setConfigFilePath(value):
            fields["value"] = value; legacy = [name: value]
        default: legacy = name
        }
        let data = try JSONSerialization.data(withJSONObject: dialect == .v4 ? legacy : fields,
                                             options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

public enum CamillaDSPProtocol {
    /// Envelope decoding only. Domain callers still validate payload types and limits.
    public static func response(_ data: Data, command: String,
                                dialect: CamillaDSPDialect? = nil) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwitcherError.message("Invalid CamillaDSP \(command) reply")
        }
        let body: [String: Any]
        if root["reply"] != nil {
            guard dialect != .v4, root["reply"] as? String == command else {
                throw SwitcherError.message("Unexpected CamillaDSP reply for \(command)")
            }
            body = root
        } else {
            guard dialect != .v5, root.count == 1, let value = root[command] as? [String: Any] else {
                throw SwitcherError.message("Unexpected CamillaDSP reply for \(command)")
            }
            body = value
        }
        guard body["result"] as? String == "Ok" else {
            let result: String
            let message: String?
            if root["reply"] == nil, let error = body["result"] as? [String: String],
               error.count == 1, let item = error.first {
                result = item.key; message = item.value
            } else {
                result = body["result"] as? String ?? "invalid result"
                message = body["message"] as? String
            }
            let detail = message.map { ": " + String($0.prefix(600)) } ?? ""
            throw SwitcherError.message("CamillaDSP \(command): \(result)\(detail)")
        }
        return body
    }
}

/// One negotiated connection. Its caller owns lifetime, authority and the deadline.
@MainActor public final class CamillaDSPProtocolSession {
    public typealias Exchange = @MainActor (String) async throws -> Data
    public let version: CamillaDSPVersion
    private let exchange: Exchange

    private init(version: CamillaDSPVersion, exchange: @escaping Exchange) {
        self.version = version; self.exchange = exchange
    }

    public static func connect(exchange: @escaping Exchange) async throws -> CamillaDSPProtocolSession {
        try Task.checkCancellation()
        let first = try await exchange(CamillaDSPCommand.getVersion.encoded(for: .v4))
        try Task.checkCancellation()
        guard let root = try JSONSerialization.jsonObject(with: first) as? [String: Any] else {
            throw SwitcherError.message("Invalid CamillaDSP version response")
        }
        let dialect: CamillaDSPDialect
        let reply: Data
        // v5 explicitly rejects a legacy JSON string as an invalid command.
        // Only that protocol rejection permits a second, read-only probe.
        if root["reply"] as? String == "Invalid", root.count == 2,
           root["error"] as? String == #"invalid type: string "GetVersion", expected internally tagged enum WsCommand at line 1 column 12"# {
            dialect = .v5
            reply = try await exchange(CamillaDSPCommand.getVersion.encoded(for: .v5))
            try Task.checkCancellation()
        } else { dialect = .v4; reply = first }
        let body = try CamillaDSPProtocol.response(reply, command: "GetVersion", dialect: dialect)
        guard let text = body["value"] as? String else {
            throw SwitcherError.message("CamillaDSP did not return a version string")
        }
        return try CamillaDSPProtocolSession(version: CamillaDSPVersion(text, dialect: dialect), exchange: exchange)
    }

    public func requireVersion(_ expected: CamillaDSPVersion?) throws {
        if let expected, version != expected {
            throw CamillaDSPVersionChanged(previous: expected, current: version)
        }
    }

    public func request(_ command: CamillaDSPCommand) async throws -> Data {
        try Task.checkCancellation()
        let reply = try await exchange(command.encoded(for: version.dialect))
        try Task.checkCancellation()
        _ = try CamillaDSPProtocol.response(reply, command: command.name, dialect: version.dialect)
        return reply
    }
}
