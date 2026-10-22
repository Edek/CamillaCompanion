import Foundation
import CoreFoundation
import AutoAudioCore

/// Domain validation for Main and enabled Aux Volume filters, independent of wire version.
public enum AuxDSPProtocol {
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    public static func state(configuration: Data, faders: Data) throws -> AuxDSPState {
        let configReply = try CamillaDSPProtocol.response(configuration, command: "GetConfigJson")
        guard let json = configReply["value"] as? String else {
            throw SwitcherError.message("Missing active DSP configuration")
        }
        return try state(configurationJSON: json, faders: faders)
    }
    public static func state(configurationJSON json: String, faders: Data) throws -> AuxDSPState {
        guard let config = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let pipeline = config["pipeline"] as? [[String: Any]] else {
            throw SwitcherError.message("CamillaDSP did not return an active configuration pipeline")
        }
        let filters = config["filters"] as? [String: [String: Any]] ?? [:]
        var limits: [Int: Double] = [:]
        for step in pipeline where step["type"] as? String == "Filter" {
            if let bypass = step["bypassed"], !(bypass is NSNull) {
                guard let bypass = boolean(bypass) else { throw SwitcherError.message("Invalid pipeline bypass flag") }
                if bypass { continue }
            }
            if let channels = step["channels"], !(channels is NSNull) {
                guard let channels = channels as? [Any], channels.allSatisfy({
                    guard let value = number($0) else { return false }
                    return value >= 0 && value.rounded() == value
                }) else { throw SwitcherError.message("Invalid pipeline channels") }
                if channels.isEmpty { continue }
            }
            guard let names = step["names"] as? [String] else { throw SwitcherError.message("Invalid pipeline filter names") }
            for name in names {
                guard let filter = filters[name] else { throw SwitcherError.message("Pipeline references an unknown filter") }
                guard filter["type"] as? String == "Volume" else { continue }
                guard let parameters = filter["parameters"] as? [String: Any],
                      let fader = parameters["fader"] as? String,
                      let id = (1...4).first(where: { fader == "Aux\($0)" }) else {
                    throw SwitcherError.message("Invalid Aux Volume filter fader")
                }
                var limit = 50.0
                if let value = parameters["limit"], !(value is NSNull) {
                    guard let decoded = number(value), decoded >= -150 else {
                        throw SwitcherError.message("Invalid Aux Volume filter limit")
                    }
                    limit = min(50, decoded)
                }
                limits[id] = min(limits[id] ?? 50, limit)
            }
        }
        let faderReply = try CamillaDSPProtocol.response(faders, command: "GetFaders")
        guard let values = faderReply["value"] as? [[String: Any]], values.count == 5 else {
            throw SwitcherError.message("CamillaDSP returned an invalid fader list")
        }
        var result: [AuxFader] = []
        for id in limits.keys.sorted() {
            guard let db = number(values[id]["volume"]), (-150...50).contains(db),
                  let muted = boolean(values[id]["mute"]) else {
                throw SwitcherError.message("CamillaDSP returned an invalid Aux\(id) value")
            }
            result.append(AuxFader(id: id, name: "Aux\(id)", volumeDB: db, muted: muted, maximumDB: limits[id]!))
        }
        var mainLimit = 50.0
        if let value = (config["devices"] as? [String: Any])?["volume_limit"], !(value is NSNull) {
            guard let limit = number(value), limit >= -150 else { throw SwitcherError.message("Invalid Main volume limit") }
            mainLimit = min(50, limit)
        }
        guard let mainDB = number(values[0]["volume"]), (-150...50).contains(mainDB),
              let mainMuted = boolean(values[0]["mute"]) else { throw SwitcherError.message("Invalid Main fader value") }
        return AuxDSPState(faders: result, main: AuxFader(id: 0, name: "Main Volume", volumeDB: mainDB, muted: mainMuted, maximumDB: mainLimit))
    }
    public static func volumeCommand(id: Int, db: Double) throws -> CamillaDSPCommand {
        guard (0...4).contains(id), db.isFinite, (-150...50).contains(db) else {
            throw SwitcherError.message("Invalid Aux volume request")
        }
        return .setFaderVolume(id, db)
    }
    public static func muteCommand(id: Int, muted: Bool) throws -> CamillaDSPCommand {
        guard (0...4).contains(id) else { throw SwitcherError.message("Invalid Aux mute request") }
        return .setFaderMute(id, muted)
    }
}

/// Independent finite connections leave the lifecycle manager's passive socket untouched.
@MainActor public final class CamillaAuxDSPTransport: AuxDSPTransport {
    public typealias Transaction = @MainActor (URL, [String]) async throws -> [Data]
    private let timeout: TimeInterval
    private let transaction: Transaction?
    private var generation = UUID()
    private var profile: Profile?
    private var state: AuxDSPState?
    private var protocolVersion: CamillaDSPVersion?
    private var tail: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?
    private var activeConnection: BoundedWebSocketConnection?
    private var activeCancel: (() -> Void)?
    public init(timeout: TimeInterval = 3, transaction: Transaction? = nil) {
        self.timeout = timeout.isFinite ? max(0.01, timeout) : 3
        self.transaction = transaction
    }
    public func cancel() {
        generation = UUID(); profile = nil; state = nil; protocolVersion = nil
        activeCancel?(); activeCancel = nil
        activeConnection?.abort()
        activeSocket = nil; activeConnection = nil
    }
    private func endpoint(_ profile: Profile) throws -> URL {
        try LocalCamillaDSPEndpoint.url(profile.websocketURL,
            invalidEndpoint: "Aux controls require a local CamillaDSP WebSocket endpoint")
    }
    private func perform<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let prior = tail
        let token = generation
        let work = Task { @MainActor in
            await prior?.value
            try Task.checkCancellation()
            guard self.generation == token else { throw CancellationError() }
            let result = try await operation()
            try Task.checkCancellation()
            guard self.generation == token else { throw CancellationError() }
            return result
        }
        tail = Task { _ = await work.result }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
            Task { @MainActor in
                guard self.generation == token else { return }
                self.cancel()
            }
        }
    }
    public func read(profile: Profile) async throws -> AuxDSPState {
        if self.profile != profile { cancel(); self.profile = profile }
        let token = generation
        let url = try endpoint(profile)
        return try await perform {
            self.state = nil; self.protocolVersion = nil
            let replies = try await self.exchange(url, commands: [.getState, .getConfigJson, .getFaders])
            guard self.generation == token else { throw CancellationError() }
            guard replies.count == 3 else { throw SwitcherError.message("Missing Aux refresh response") }
            try DSPReadiness.validateState(DSPReadiness.value(from: replies[0], command: "GetState"))
            try DSPReadiness.validateConfiguration(DSPReadiness.value(from: replies[1], command: "GetConfigJson"), profile: profile)
            let state = try AuxDSPProtocol.state(configuration: replies[1], faders: replies[2])
            self.state = state
            return state
        }
    }
    public func setVolume(id: Int, db: Double) async throws {
        let command = try AuxDSPProtocol.volumeCommand(id: id, db: db)
        guard let profile else { throw SwitcherError.message("Refresh Aux controls before changing them") }
        let url = try endpoint(profile)
        try await perform {
            guard let fader = (id == 0 ? self.state?.main : self.state?.faders.first(where: { $0.id == id })), db <= fader.maximumDB else {
                throw SwitcherError.message("Aux fader is unavailable or exceeds its configured limit")
            }
            let replies = try await self.exchange(url, commands: [command])
            guard replies.count == 1 else { throw SwitcherError.message("Missing Aux volume acknowledgement") }
            _ = try CamillaDSPProtocol.response(replies[0], command: "SetFaderVolume")
        }
    }
    public func setMute(id: Int, muted: Bool) async throws {
        let command = try AuxDSPProtocol.muteCommand(id: id, muted: muted)
        guard let profile else { throw SwitcherError.message("Refresh Aux controls before changing them") }
        let url = try endpoint(profile)
        try await perform {
            guard (id == 0 ? self.state?.main != nil : self.state?.faders.contains(where: { $0.id == id }) == true) else {
                throw SwitcherError.message("Aux fader is unavailable")
            }
            let replies = try await self.exchange(url, commands: [command])
            guard replies.count == 1 else { throw SwitcherError.message("Missing Aux mute acknowledgement") }
            _ = try CamillaDSPProtocol.response(replies[0], command: "SetFaderMute")
        }
    }
    private func exchange(_ url: URL, commands: [CamillaDSPCommand]) async throws -> [Data] {
        let token = generation
        let connection = transaction == nil ? BoundedWebSocketConnection(url: url, timeout: timeout) : nil
        let socket = connection?.socket
        let gate = DSPReplyGate<[Data]>()
        let cancellation = DSPExchangeCancellation()
        activeConnection = connection; activeSocket = socket
        socket?.resume()
        var deadline: Task<Void, Never>?
        defer {
            cancellation.cancel(); deadline?.cancel()
            connection?.close()
            if activeSocket === socket { activeSocket = nil; activeConnection = nil; activeCancel = nil }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
                activeCancel = {
                    gate.finish(.failure(CancellationError()))
                    cancellation.cancel(); connection?.abort()
                }
                let worker = Task { @MainActor in
                    do {
                        let session = try await CamillaDSPProtocolSession.connect { command in
                            if let transaction = self.transaction {
                                let replies = try await transaction(url, [command])
                                guard replies.count == 1 else { throw SwitcherError.message("Missing DSP reply") }
                                return replies[0]
                            }
                            guard let socket else { throw SwitcherError.message("Missing DSP connection") }
                            return try await CamillaDSPWire.request(command, socket: socket,
                                invalidResponse: "Unexpected CamillaDSP response")
                        }
                        try Task.checkCancellation()
                        guard self.generation == token else { throw CancellationError() }
                        try session.requireVersion(self.protocolVersion)
                        self.protocolVersion = session.version
                        var replies: [Data] = []
                        for command in commands {
                            try Task.checkCancellation()
                            guard self.generation == token else { throw CancellationError() }
                            replies.append(try await session.request(command))
                        }
                        gate.finish(.success(replies))
                    } catch { gate.finish(.failure(error)) }
                }
                cancellation.install(worker)
                // Releasing the gate does not depend on URLSession.receive()
                // responding promptly to the same bounded socket abort.
                deadline = DSPConnectionDeadline.schedule(
                    nanoseconds: UInt64(min(timeout, 3600) * 1_000_000_000)) {
                    gate.finish(.failure(URLError(.timedOut)))
                    cancellation.cancel(); connection?.abort()
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in
                gate.finish(.failure(CancellationError()))
                connection?.abort()
            }
        }
    }
}
