import Foundation
import CoreFoundation
import AutoAudioCore
import Yams

/// A finite operation uses one monotonic deadline, including recovery. No connection
/// survives the user command. Injected transactions use the same deadline/cancellation gate.
@MainActor public final class CamillaPresetDSPTransport: PresetDSPTransport {
    public typealias Transaction = @MainActor (URL, [String]) async throws -> [Data]
    private let timeout: TimeInterval
    private let transaction: Transaction?
    private var generation = UUID()
    private var busyToken: UUID?
    private var activeCancel: (() -> Void)?
    private var catalogEntries: [PresetEntry] = []
    private var catalogConfigurations: [String: String] = [:]
    private var operationVersion: CamillaDSPVersion?
    private var catalogVersion: CamillaDSPVersion?
    public init(timeout: TimeInterval = 20, transaction: Transaction? = nil) {
        self.timeout = timeout.isFinite ? min(20, max(0.05, timeout)) : 20
        self.transaction = transaction
    }
    public func cancel() {
        generation = UUID(); busyToken = nil
        activeCancel?(); activeCancel = nil
        catalogEntries = []; catalogConfigurations = [:]; operationVersion = nil; catalogVersion = nil
    }
    private func endpoint(_ profile: Profile) throws -> URL {
        try LocalCamillaDSPEndpoint.url(profile.websocketURL,
            invalidEndpoint: "Presets require a local CamillaDSP WebSocket endpoint.")
    }
    private func check(_ token: UUID, deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw SwitcherError.message("The preset command reached its time limit.")
        }
    }
    private func begin() throws -> (UUID, TimeInterval) {
        guard busyToken == nil else { throw SwitcherError.message("Wait for the current preset command.") }
        let token = generation
        busyToken = token; operationVersion = nil
        return (token, ProcessInfo.processInfo.systemUptime + timeout)
    }
    private func finish(_ token: UUID) { if busyToken == token { busyToken = nil; operationVersion = nil } }
    private func json(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw SwitcherError.message("Preset YAML must contain a finite JSON-compatible configuration mapping.")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func object(_ string: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            throw SwitcherError.message("CamillaDSP returned an invalid configuration mapping.")
        }
        return result
    }
    private func string(_ reply: Data, command: String) throws -> String {
        guard let value = try CamillaDSPProtocol.response(reply, command: command)["value"] as? String else {
            throw SwitcherError.message("CamillaDSP did not return a string for \(command).")
        }
        return value
    }
    private struct Actual {
        var config: String
        var path: String?
        var faders: Data
        var title: String?
    }
    private func actual(_ url: URL, profile: Profile, deadline: TimeInterval, token: UUID) async throws -> Actual {
        let commands: [CamillaDSPCommand] = [.getState, .getConfigJson, .getConfigFilePath, .getFaders]
        let names = commands.map(\.name)
        let replies = try await exchange(url, commands: commands, deadline: deadline, token: token)
        try DSPReadiness.validateState(DSPReadiness.value(from: replies[0], command: names[0]))
        let config = try string(replies[1], command: names[1])
        try DSPReadiness.validateConfiguration(config, profile: profile)
        _ = try AuxDSPProtocol.state(configuration: replies[1], faders: replies[3])
        let pathValue = try CamillaDSPProtocol.response(replies[2], command: names[2])["value"]
        guard pathValue is NSNull || pathValue is String else {
            throw SwitcherError.message("CamillaDSP returned an invalid active preset path.")
        }
        return Actual(config: config, path: pathValue as? String, faders: replies[3],
                      title: try object(config)["title"] as? String)
    }
    private func ask(_ url: URL, command: CamillaDSPCommand,
                     deadline: TimeInterval, token: UUID) async throws -> Data {
        let replies = try await exchange(url, commands: [command], deadline: deadline, token: token)
        _ = try CamillaDSPProtocol.response(replies[0], command: command.name)
        return replies[0]
    }
    private func localFile(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), ["yaml", "yml"].contains((path as NSString).pathExtension.lowercased()) else {
            throw SwitcherError.message("Preset must be an absolute YAML file path.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 2_000_000,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw SwitcherError.message("Preset must be a readable regular YAML file smaller than 2 MB.")
        }
        return url.resolvingSymlinksInPath()
    }
    /// Camilla v4.1.3 resolves Conv filenames relative to the canonical config
    /// directory during validate_config(Some(path)), after token substitution.
    /// JSON validation has no path context, so resolve those references first.
    /// A relative file absent there is rejected instead of relying on daemon cwd.
    private func resolveCoefficients(_ config: inout [String: Any], file: URL) throws {
        guard var filters = config["filters"] as? [String: [String: Any]] else { return }
        let devices = config["devices"] as? [String: Any] ?? [:]
        let capture = devices["capture"] as? [String: Any] ?? [:]
        for name in filters.keys {
            guard var filter = filters[name], filter["type"] as? String == "Conv",
                  var params = filter["parameters"] as? [String: Any],
                  let filename = params["filename"] as? String else { continue }
            var expanded = filename
            for (token, value) in [("$samplerate$", devices["samplerate"]), ("$channels$", capture["channels"])] {
                if expanded.contains(token) {
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue > 0, number.doubleValue.rounded() == number.doubleValue else {
                        throw SwitcherError.message("Coefficient filename contains an unresolved token.")
                    }
                    expanded = expanded.replacingOccurrences(of: token, with: number.stringValue)
                }
            }
            guard !expanded.isEmpty else { throw SwitcherError.message("Coefficient filename is empty.") }
            let resolved = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : file.deletingLastPathComponent().appendingPathComponent(expanded)
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: resolved.path) else {
                throw SwitcherError.message("Coefficient file is missing or unreadable: \(expanded)")
            }
            // Preserve Camilla's non-canonical absolute spelling for exact content verification.
            params["filename"] = resolved.path; filter["parameters"] = params; filters[name] = filter
        }
        config["filters"] = filters
    }
    private func candidate(_ path: String, url: URL, profile: Profile, current: Actual,
                           deadline: TimeInterval, token: UUID) async throws -> (configuration: String, impact: PresetImpact) {
        let file = try localFile(path)
        // Parse locally with Yams as well as the daemon's parser. Never deserialize objects.
        let yaml = try String(contentsOf: file, encoding: .utf8)
        guard let local = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw SwitcherError.message("Preset YAML must contain a configuration mapping.")
        }
        _ = try json(local)
        let fileReply = try await ask(url, command: .readConfigFile(file.path), deadline: deadline, token: token)
        let daemonYAML = try string(fileReply, command: "ReadConfigFile")
        guard let parsed = try Yams.load(yaml: daemonYAML) as? [String: Any] else {
            throw SwitcherError.message("CamillaDSP returned invalid normalized YAML.")
        }
        let read = try await ask(url, command: .readConfigJson(try json(parsed)), deadline: deadline, token: token)
        var normalized = try object(string(read, command: "ReadConfigJson"))
        try resolveCoefficients(&normalized, file: file)
        let validation = try await ask(url, command: .validateConfigJson(try json(normalized)), deadline: deadline, token: token)
        let candidate = try string(validation, command: "ValidateConfigJson")
        try DSPReadiness.validateConfiguration(candidate, profile: profile)
        let impact = try PresetCompatibility.classify(activeConfiguration: current.config, candidateConfiguration: candidate)
        let limits = try AuxDSPProtocol.state(configurationJSON: candidate, faders: current.faders)
        guard let main = limits.main, main.volumeDB <= main.maximumDB,
              limits.faders.allSatisfy({ $0.volumeDB <= $0.maximumDB }) else {
            throw SwitcherError.message("Current Main or Aux volume exceeds this preset's limit. Lower the volume first.")
        }
        try check(token, deadline: deadline)
        return (candidate, impact)
    }
    public func inspect(profile: Profile, paths: [String]) async throws -> PresetDSPState {
        let (token, deadline) = try begin(); defer { finish(token) }
        let url = try endpoint(profile)
        let current = try await actual(url, profile: profile, deadline: deadline, token: token)
        var entries: [PresetEntry] = []
        var configurations: [String: String] = [:]
        var activeMatchesFile = !paths.contains(current.path ?? "")
        for path in paths {
            try check(token, deadline: deadline)
            var title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            do {
                let candidate = try await candidate(path, url: url, profile: profile, current: current, deadline: deadline, token: token)
                let config = candidate.configuration
                configurations[path] = config
                if path == current.path {
                    activeMatchesFile = PresetConfigurationIdentity.matches(
                        activeConfiguration: current.config, candidateConfiguration: config)
                }
                if let value = try object(config)["title"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = value }
                entries.append(PresetEntry(path: path, title: title, requiresAudioRestart: candidate.impact.requiresAudioRestart,
                    settingChanges: candidate.impact.settingChanges))
            } catch {
                try check(token, deadline: deadline)
                if error is CamillaDSPVersionChanged { throw error }
                entries.append(PresetEntry(path: path, title: title, available: false, reason: error.localizedDescription))
            }
        }
        try check(token, deadline: deadline)
        catalogEntries = entries; catalogConfigurations = configurations; catalogVersion = operationVersion
        return PresetDSPState(activePath: activeMatchesFile ? current.path : nil, activeTitle: current.title, entries: entries)
    }
    /// Reclassify the already inspected immutable candidates using confirmed DSP
    /// content/faders. This adds no file reads, sockets or second catalog scan.
    private func reclassifiedState(_ current: Actual, requestedPath: String, requestedConfiguration: String,
                                   deadline: TimeInterval, token: UUID) throws -> PresetDSPState {
        var configurations = catalogConfigurations
        configurations[requestedPath] = requestedConfiguration
        var entries = catalogEntries
        if !entries.contains(where: { $0.path == requestedPath }) {
            let title = (try object(requestedConfiguration)["title"] as? String)
                ?? URL(fileURLWithPath: requestedPath).deletingPathExtension().lastPathComponent
            entries.append(PresetEntry(path: requestedPath, title: title))
        }
        var updated: [PresetEntry] = []
        for original in entries {
            try check(token, deadline: deadline)
            guard let config = configurations[original.path] else {
                updated.append(original); continue
            }
            var entry = original
            do {
                let impact = try PresetCompatibility.classify(activeConfiguration: current.config, candidateConfiguration: config)
                let limits = try AuxDSPProtocol.state(configurationJSON: config, faders: current.faders)
                guard let main = limits.main, main.volumeDB <= main.maximumDB,
                      limits.faders.allSatisfy({ $0.volumeDB <= $0.maximumDB }) else {
                    throw SwitcherError.message("Current Main or Aux volume exceeds this preset's limit. Lower the volume first.")
                }
                entry.available = true; entry.reason = nil
                entry.requiresAudioRestart = impact.requiresAudioRestart; entry.settingChanges = impact.settingChanges
                if let title = try object(config)["title"] as? String { entry.title = String(title.prefix(160)) }
            } catch {
                entry.available = false; entry.reason = String(error.localizedDescription.prefix(600))
                entry.requiresAudioRestart = false; entry.settingChanges = []
            }
            updated.append(entry)
        }
        try check(token, deadline: deadline)
        catalogEntries = updated; catalogConfigurations = configurations; catalogVersion = operationVersion
        return PresetDSPState(activePath: current.path, activeTitle: current.title, entries: updated)
    }
    public func apply(path: String, profile: Profile) async throws -> PresetDSPState {
        try await applyValidated(path: path, profile: profile, expectedImpact: nil)
    }
    public func apply(path: String, profile: Profile, expectedImpact: PresetImpact) async throws -> PresetDSPState {
        try await applyValidated(path: path, profile: profile, expectedImpact: expectedImpact)
    }
    private func applyValidated(path: String, profile: Profile, expectedImpact: PresetImpact?) async throws -> PresetDSPState {
        let (token, deadline) = try begin(); defer { finish(token) }
        let url = try endpoint(profile)
        // Reserve part of the shared deadline for rollback.
        let mutationDeadline = deadline - timeout * 0.35
        let original = try await actual(url, profile: profile, deadline: mutationDeadline, token: token)
        guard let originalPath = original.path, !originalPath.isEmpty else {
            throw SwitcherError.message("Preset switching requires a known active file path so recovery can restore it.")
        }
        let candidate = try await candidate(path, url: url, profile: profile, current: original, deadline: mutationDeadline, token: token)
        if let expectedImpact, candidate.impact != expectedImpact {
            throw SwitcherError.message("Preset restart impact or changed settings no longer match the displayed selection. Refresh presets before applying.")
        }
        let expected = candidate.configuration
        // Capture live changes immediately before mutation. External edits invalidate preflight.
        let before = try await actual(url, profile: profile, deadline: mutationDeadline, token: token)
        guard try json(object(before.config)) == json(object(original.config)), before.path == original.path,
              try faderValues(before.faders) == faderValues(original.faders) else {
            throw SwitcherError.message("DSP configuration or faders changed during validation. Refresh presets and try again.")
        }
        var mutationAttempted = false
        do {
            try check(token, deadline: mutationDeadline)
            mutationAttempted = true
            // Apply the immutable validated snapshot. Reloading the file here could
            // activate unvalidated devices if another application edited it meanwhile.
            _ = try await ask(url, command: .setConfigJson(expected), deadline: mutationDeadline, token: token)
            _ = try await retryPointer(url, path: path, deadline: mutationDeadline, token: token)
            let confirmed = try await verify(url, profile: profile, config: expected, path: path,
                                             faders: before.faders, deadline: mutationDeadline, token: token)
            return try reclassifiedState(confirmed, requestedPath: path, requestedConfiguration: expected,
                deadline: mutationDeadline, token: token)
        } catch {
            let failure = error
            // Lifecycle cancellation revokes authority. Never write into the new generation.
            if generation != token || Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error is CamillaDSPVersionChanged { throw error }
            if mutationAttempted {
                let restored: PresetDSPState
                do {
                    _ = try await ask(url, command: .setConfigJson(before.config), deadline: deadline, token: token)
                    _ = try await retryPointer(url, path: originalPath, deadline: deadline, token: token)
                    let confirmed = try await verify(url, profile: profile, config: before.config, path: originalPath,
                                         faders: before.faders, deadline: deadline, token: token)
                    restored = try reclassifiedState(confirmed, requestedPath: path, requestedConfiguration: expected,
                        deadline: deadline, token: token)
                } catch {
                    if generation != token || Task.isCancelled || error is CancellationError { throw CancellationError() }
                    throw DSPFailure.unavailable("Preset switch failed: \(failure.localizedDescription) Recovery could not be verified: \(error.localizedDescription)")
                }
                throw PresetFailure.restored("Preset switch failed: \(failure.localizedDescription) Previous configuration and path were restored.",
                                             restored)
            }
            throw failure
        }
    }
    private func faderValues(_ reply: Data) throws -> String {
        guard let values = try CamillaDSPProtocol.response(reply, command: "GetFaders")["value"] else {
            throw SwitcherError.message("Missing faders.")
        }
        return try json(values)
    }
    private func verify(_ url: URL, profile: Profile, config: String, path: String,
                        faders: Data, deadline: TimeInterval, token: UUID) async throws -> Actual {
        var lastError: Error = SwitcherError.message("Preset content was not applied.")
        // Finite readiness only. SetConfigJson acknowledgment means queued, not yet active.
        for attempt in 0..<120 {
            try check(token, deadline: deadline)
            do {
                let observed = try await actual(url, profile: profile,
                    deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 1.5), token: token)
                guard observed.path == path, try json(object(observed.config)) == json(object(config)),
                      try faderValues(observed.faders) == faderValues(faders) else {
                    throw SwitcherError.message("Active preset content, path, or faders did not match the requested result.")
                }
                return observed
            } catch {
                try check(token, deadline: deadline); lastError = error
            }
            if attempt < 119 { try await pause(deadline: deadline, token: token) }
        }
        throw lastError
    }
    /// Updating the file pointer is idempotent. A temporarily unavailable API may
    /// be retried while processing reopens. Config submissions are never replayed.
    private func retryPointer(_ url: URL, path: String, deadline: TimeInterval, token: UUID) async throws -> Data {
        for attempt in 0..<120 {
            try check(token, deadline: deadline)
            do {
                return try await ask(url, command: .setConfigFilePath(path),
                    deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 1.5), token: token)
            } catch {
                try check(token, deadline: deadline)
                guard error is URLError || error is PresetConnectionFailure, attempt < 119 else { throw error }
                try await pause(deadline: deadline, token: token)
            }
        }
        throw SwitcherError.message("Preset file identity could not be confirmed while audio reopened.")
    }
    private func pause(deadline: TimeInterval, token: UUID) async throws {
        try check(token, deadline: deadline)
        let seconds = min(0.1, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private func exchange(_ url: URL, commands: [CamillaDSPCommand], deadline: TimeInterval, token: UUID) async throws -> [Data] {
        try check(token, deadline: deadline)
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        let gate = DSPReplyGate<[Data]>()
        let connection = transaction == nil ? BoundedWebSocketConnection(url: url, timeout: remaining) : nil
        let socket = connection?.socket
        socket?.resume()
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        defer {
            worker?.cancel(); timer?.cancel()
            connection?.close()
            if generation == token { activeCancel = nil }
        }
        return try await withTaskCancellationHandler {
            let replies: [Data] = try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
                activeCancel = {
                    gate.finish(.failure(CancellationError()))
                    worker?.cancel(); connection?.abort()
                }
                worker = Task { @MainActor in
                    do {
                        let session = try await CamillaDSPProtocolSession.connect { command in
                            try self.check(token, deadline: deadline)
                            if let transaction = self.transaction {
                                let replies = try await transaction(url, [command])
                                guard replies.count == 1 else { throw SwitcherError.message("Missing preset reply") }
                                return replies[0]
                            }
                            guard let socket else { throw SwitcherError.message("Missing preset connection") }
                            return try await CamillaDSPWire.request(command, socket: socket,
                                invalidResponse: "Unexpected CamillaDSP response")
                        }
                        try self.check(token, deadline: deadline)
                        try session.requireVersion(self.operationVersion)
                        if self.operationVersion == nil {
                            if let catalogVersion = self.catalogVersion, catalogVersion != session.version {
                                self.catalogEntries = []; self.catalogConfigurations = [:]; self.catalogVersion = nil
                            }
                            self.operationVersion = session.version
                        }
                        var replies: [Data] = []
                        for command in commands {
                            try self.check(token, deadline: deadline)
                            replies.append(try await session.request(command))
                        }
                        try self.check(token, deadline: deadline)
                        guard replies.count == commands.count else { throw SwitcherError.message("Missing preset command response.") }
                        gate.finish(.success(replies))
                    } catch { gate.finish(.failure(error)) }
                }
                timer = DSPConnectionDeadline.schedule(
                    nanoseconds: UInt64(max(0.001, remaining) * 1_000_000_000)) {
                    gate.finish(.failure(PresetConnectionFailure.timedOut))
                    worker?.cancel(); connection?.abort()
                }
            }
            try check(token, deadline: deadline)
            return replies
        } onCancel: {
            Task { @MainActor in
                gate.finish(.failure(CancellationError()))
                connection?.abort()
            }
        }
    }
}
private enum PresetConnectionFailure: Error, LocalizedError {
    case timedOut
    var errorDescription: String? { "The preset API connection reached its time limit." }
}
