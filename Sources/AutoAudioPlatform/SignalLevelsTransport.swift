import Foundation
import CoreFoundation
import AutoAudioCore

public enum SignalLevelsProtocol {
    public static func decode(_ data: Data, inputLabels: [String], outputLabels: [String], command: String = "GetSignalLevels") throws -> SignalLevels {
        let body = try CamillaDSPProtocol.response(data, command: command)
        guard let value = body["value"] as? [String: Any] else { throw SwitcherError.message("Missing signal levels") }
        func channels(_ side: String, labels: [String]) throws -> [SignalChannelLevel] {
            guard let rms = value[side + "_rms"] as? [Any], let peak = value[side + "_peak"] as? [Any],
                  rms.count == peak.count, (rms.count == labels.count || (command == "GetSignalLevelsSinceLast" && rms.isEmpty)), rms.count <= 64 else {
                throw SwitcherError.message("DSP meter channels changed. Reopen Live Metering to refresh the configuration.")
            }
            func db(_ value: Any) throws -> Double {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                    throw SwitcherError.message("Invalid signal level")
                }
                return number.doubleValue
            }
            return try rms.indices.map { SignalChannelLevel(label: labels[$0], rmsDB: try db(rms[$0]), peakDB: try db(peak[$0])) }
        }
        return try SignalLevels(input: channels("capture", labels: inputLabels), output: channels("playback", labels: outputLabels))
    }
    public static func labels(configuration: Data) throws -> (input: [String], output: [String]) {
        let reply = try CamillaDSPProtocol.response(configuration, command: "GetConfigJson")
        guard let json = reply["value"] as? String, let data = json.data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any], let devices = config["devices"] as? [String: Any] else {
            throw SwitcherError.message("Missing DSP channel configuration")
        }
        func labels(_ side: String) throws -> [String] {
            guard let device = devices[side] as? [String: Any], let number = device["channels"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue, (1...64).contains(number.intValue) else {
                throw SwitcherError.message("Unsupported DSP meter channel count")
            }
            let names = device["labels"] as? [Any] ?? []
            return (0..<number.intValue).map { index in
                if index < names.count, let name = names[index] as? String, !name.isEmpty { return String(name.prefix(80)) }
                return "Channel \(index + 1)"
            }
        }
        return try (labels("capture"), labels("playback"))
    }
}

/// Since-last RMS and peak histories are independent in CamillaDSP. Cache only
/// actual received components, and never fabricate an initial missing value.
public struct SignalLevelsIntervalDecoder: Sendable {
    private let inputLabels: [String]
    private let outputLabels: [String]
    private var captureRMS: [Double] = []
    private var capturePeak: [Double] = []
    private var playbackRMS: [Double] = []
    private var playbackPeak: [Double] = []
    private var initialized = false
    public init(inputLabels: [String], outputLabels: [String]) {
        self.inputLabels = inputLabels; self.outputLabels = outputLabels
    }
    public mutating func decode(_ data: Data) throws -> SignalLevels {
        let body = try CamillaDSPProtocol.response(data, command: "GetSignalLevelsSinceLast")
        guard let value = body["value"] as? [String: Any] else { throw SwitcherError.message("Missing interval signal levels") }
        func values(_ key: String, count: Int) throws -> [Double] {
            guard let array = value[key] as? [Any], array.isEmpty || array.count == count else {
                throw SwitcherError.message("DSP meter channels changed. Reopen Live Metering to refresh the configuration.")
            }
            return try array.map {
                guard let number = $0 as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                    throw SwitcherError.message("Invalid interval signal level")
                }
                return number.doubleValue
            }
        }
        let cr = try values("capture_rms", count: inputLabels.count)
        let cp = try values("capture_peak", count: inputLabels.count)
        let pr = try values("playback_rms", count: outputLabels.count)
        let pp = try values("playback_peak", count: outputLabels.count)
        func retainInitialPeaks(_ fresh: [Double], previous: [Double]) -> [Double] {
            guard !fresh.isEmpty else { return previous }
            guard !initialized, previous.count == fresh.count else { return fresh }
            return zip(previous, fresh).map { max($0.0, $0.1) }
        }
        if !cr.isEmpty { captureRMS = cr }
        if !pr.isEmpty { playbackRMS = pr }
        capturePeak = retainInitialPeaks(cp, previous: capturePeak)
        playbackPeak = retainInitialPeaks(pp, previous: playbackPeak)
        // A missing initial component is not evidence of removed channels. Publish
        // the configured topology atomically, retaining transients while waiting.
        guard captureRMS.count == inputLabels.count, capturePeak.count == inputLabels.count,
              playbackRMS.count == outputLabels.count, playbackPeak.count == outputLabels.count else {
            return SignalLevels(input: [], output: [])
        }
        let firstComplete = !initialized
        initialized = true
        func channels(_ labels: [String], rms: [Double], peak: [Double], newRMS: Bool, newPeak: Bool) -> [SignalChannelLevel] {
            guard rms.count == labels.count, peak.count == labels.count else { return [] }
            return labels.indices.map { SignalChannelLevel(label: labels[$0], rmsDB: rms[$0], peakDB: peak[$0],
                                                           rmsUpdated: newRMS, peakUpdated: newPeak) }
        }
        return SignalLevels(input: channels(inputLabels, rms: captureRMS, peak: capturePeak, newRMS: firstComplete || !cr.isEmpty, newPeak: firstComplete || !cp.isEmpty),
                            output: channels(outputLabels, rms: playbackRMS, peak: playbackPeak, newRMS: firstComplete || !pr.isEmpty, newPeak: firstComplete || !pp.isEmpty))
    }
}

/// A dedicated read-only socket. Authority ends immediately; socket closure has a finite grace.
@MainActor public final class CamillaSignalLevelsTransport: SignalLevelsTransport {
    private var connection: BoundedWebSocketConnection?
    private var socket: URLSessionWebSocketTask?
    private var protocolSession: CamillaDSPProtocolSession?
    private var generation = UUID()
    private var inputLabels: [String] = []
    private var outputLabels: [String] = []
    private var intervalDecoder: SignalLevelsIntervalDecoder?
    public init() {}
    public func cancel() {
        generation = UUID()
        connection?.close()
        socket = nil; connection = nil; protocolSession = nil; inputLabels = []; outputLabels = []; intervalDecoder = nil
    }
    public func connect(profile: Profile) async throws {
        try Task.checkCancellation()
        cancel()
        let url = try LocalCamillaDSPEndpoint.url(profile.websocketURL,
            invalidEndpoint: "Live Metering requires a local DSP endpoint")
        let token = generation
        let connection = BoundedWebSocketConnection(url: url, timeout: 3)
        let socket = connection.socket!
        self.connection = connection; self.socket = socket; socket.resume()
        let state = try await exchange(.getState)
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
        try DSPReadiness.validateState(DSPReadiness.value(from: state, command: "GetState"))
        let config = try await exchange(.getConfigJson)
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
        try DSPReadiness.validateConfiguration(DSPReadiness.value(from: config, command: "GetConfigJson"), profile: profile)
        let labels = try SignalLevelsProtocol.labels(configuration: config)
        guard token == generation else { throw CancellationError() }
        inputLabels = labels.input; outputLabels = labels.output
        intervalDecoder = SignalLevelsIntervalDecoder(inputLabels: labels.input, outputLabels: labels.output)
    }
    public func read() async throws -> SignalLevels {
        let token = generation
        let data = try await exchange(.getSignalLevelsSinceLast)
        guard token == generation else { throw CancellationError() }
        do {
            guard var decoder = intervalDecoder else { throw SwitcherError.message("Interval meter configuration is unavailable") }
            let sample = try decoder.decode(data)
            intervalDecoder = decoder
            return sample
        } catch {
            throw SwitcherError.message("Interval metering requires CamillaDSP GetSignalLevelsSinceLast support. No current-chunk fallback is used. " + error.localizedDescription)
        }
    }
    private func exchange(_ command: CamillaDSPCommand) async throws -> Data {
        guard let socket, let connection else { throw SwitcherError.message("Live Metering is disconnected") }
        let token = generation
        let deadline = DSPConnectionDeadline.schedule(nanoseconds: 3_000_000_000) { connection.abort() }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if protocolSession == nil {
                let session = try await CamillaDSPProtocolSession.connect { command in
                    try await CamillaDSPWire.request(command, socket: socket, invalidResponse: "Invalid meter response")
                }
                guard token == generation else { throw CancellationError() }
                protocolSession = session
            }
            guard let session = protocolSession else { throw SwitcherError.message("Meter protocol unavailable") }
            let result = try await session.request(command)
            try Task.checkCancellation()
            return result
        } onCancel: {
            connection.abort()
        }
    }
}
