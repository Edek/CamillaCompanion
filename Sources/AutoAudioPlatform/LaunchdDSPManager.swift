import Foundation
import Darwin
import AutoAudioCore

/// Read-only decoding of the CamillaDSP WebSocket protocol.
public enum DSPReadiness {
    public static func value(from data: Data, command: String) throws -> Any {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root[command] as? [String: Any],
              response["result"] as? String == "Ok", let value = response["value"] else {
            throw SwitcherError.message("CamillaDSP returned an invalid or unsuccessful \(command) response")
        }
        return value
    }
    public static func validateState(_ value: Any) throws {
        if value as? String == "Starting" { throw DSPFailure.starting }
        if let state = value as? String, ["Stalled", "Inactive"].contains(state) {
            throw DSPFailure.unavailable("CamillaDSP state is \(state); expected Running or Paused")
        }
        guard let state = value as? String, ["Running", "Paused"].contains(state) else {
            throw SwitcherError.message("CamillaDSP state is \(String(describing: value)); expected Running or Paused")
        }
    }
    public static func validateConfiguration(_ value: Any, profile: Profile) throws {
        guard let json = value as? String, let data = json.data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = config["devices"] as? [String: Any] else {
            throw SwitcherError.message("CamillaDSP did not provide an active JSON configuration")
        }
        for (key, expected) in [("capture", profile.expectedCaptureDevice), ("playback", profile.expectedPlaybackDevice)] {
            guard !expected.isEmpty, let device = devices[key] as? [String: Any],
                  device["type"] as? String == "CoreAudio", device["device"] as? String == expected else {
                throw SwitcherError.message("CamillaDSP \(key) does not exactly match this profile's CoreAudio selector")
            }
        }
    }
}

@MainActor public final class LaunchdDSPManager: DSPManaging {
    public var onFailure: (@MainActor (String) -> Void)?
    private let log: (String) -> Void
    private var connection: BoundedWebSocketConnection?
    private var socket: URLSessionWebSocketTask?
    private var socketID: UUID?
    private var verified = false
    private var socketFailure: String?
    private let runCommand: ([String]) async throws -> ProcessResult
    private let sleep: (Int) async throws -> Void
    private let activationCheck: (Profile) async throws -> Void
    private var refusedStarts = Set<String>()
    public init(log: @escaping (String) -> Void = { _ in },
                runCommand: (([String]) async throws -> ProcessResult)? = nil,
                sleep: ((Int) async throws -> Void)? = nil,
                activationCheck: ((Profile) async throws -> Void)? = nil) {
        self.log = log
        self.runCommand = runCommand ?? { try await ProcessRunner.run("/bin/launchctl", arguments: $0) }
        self.sleep = sleep ?? { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
        self.activationCheck = activationCheck ?? { try await SetupConfigurationService.checkForConflictingDSP(profile: $0) }
    }

    private var domain: String { "gui/\(getuid())" }
    private func service(_ profile: Profile) -> String { "\(domain)/\(profile.launchAgentLabel)" }
    private struct JobIdentity {
        let endpoint: URL
        let executable: String
        let arguments: [String]
    }
    private struct OwnershipMismatch: LocalizedError {
        let errorDescription: String?
    }
    private var validatedJobs: [String: (profile: Profile, identity: JobIdentity)] = [:]
    private func stopIdentity(_ profile: Profile) throws -> JobIdentity {
        do { return try validate(profile) }
        catch {
            // Partial startup cleanup remains possible after files disappear,
            // but only for this exact previously validated configuration.
            guard let saved = validatedJobs[service(profile)], saved.profile == profile,
                  !FileManager.default.fileExists(atPath: profile.launchAgentPath)
                    || !FileManager.default.fileExists(atPath: saved.identity.executable) else { throw error }
            return saved.identity
        }
    }
    private func validate(_ profile: Profile) throws -> JobIdentity {
        guard !profile.launchAgentLabel.isEmpty,
              profile.launchAgentLabel.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              profile.launchAgentPath.hasPrefix("/"),
              let url = URL(string: profile.websocketURL), url.scheme == "ws",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? ""),
              let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else {
            throw SwitcherError.message("Profile requires an absolute LaunchAgent path, valid label, and local ws:// endpoint with port")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: profile.launchAgentPath))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == profile.launchAgentLabel,
              let args = plist["ProgramArguments"] as? [String], let first = args.first,
              let executable = (plist["Program"] as? String) ?? Optional(first),
              executable.hasPrefix("/"), URL(fileURLWithPath: executable).lastPathComponent == "camilladsp",
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw SwitcherError.message("LaunchAgent label/executable does not match a direct CamillaDSP job")
        }
        let matchesPort = args.enumerated().contains { index, arg in
            arg == "-p\(port)" || arg == "--port=\(port)" ||
            (["-p", "--port"].contains(arg) && index + 1 < args.count && args[index + 1] == String(port))
        }
        guard matchesPort else { throw SwitcherError.message("LaunchAgent WebSocket port does not match the profile") }
        return JobIdentity(endpoint: url, executable: executable, arguments: args)
    }
    /// The configured source path, executable and exact arguments identify the
    /// managed job. A matching label alone never authorizes adoption or unload.
    private func validateOwnership(_ result: ProcessResult, profile: Profile, identity: JobIdentity) throws {
        let lines = result.stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("path = " + profile.launchAgentPath),
              lines.contains("program = " + identity.executable),
              let beginning = lines.firstIndex(of: "arguments = {"),
              let end = lines[(beginning + 1)...].firstIndex(of: "}"),
              Array(lines[(beginning + 1)..<end]) == identity.arguments else {
            throw OwnershipMismatch(errorDescription: "Refusing unrelated DSP job at \(service(profile)); loaded path, program and arguments do not match the configured managed job.")
        }
    }
    private func command(_ args: [String]) async throws -> ProcessResult {
        try await runCommand(args)
    }
    private func requireSuccess(_ result: ProcessResult, operation: String) throws {
        guard result.status == 0 else {
            throw SwitcherError.message("launchctl \(operation) failed (\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
    static func serviceIsMissing(_ result: ProcessResult) -> Bool {
        // launchctl print uses 113 for a missing service on current macOS.
        // A missing GUI domain or permission failure is not service absence.
        result.status == 113 && result.stderr.contains("Could not find service")
    }
    public func start(_ profile: Profile) async throws {
        let exclusive = profile.requiresExclusiveDSP == true || profile.launchAgentLabel.hasPrefix("com.camillacompanion.dsp.")
        if exclusive { refusedStarts.insert(service(profile)) }
        let identity = try validate(profile)
        if exclusive {
            // First-run jobs must not adopt an unrelated server that happens
            // to answer at the same endpoint, including after Save Only/login.
            // This is one finite activation check, not an idle process scan.
            try await activationCheck(profile)
            refusedStarts.remove(service(profile))
        }
        disconnect()
        do {
            let status = try await command(["print", service(profile)])
            if status.status == 0 {
                try validateOwnership(status, profile: profile, identity: identity)
                validatedJobs[service(profile)] = (profile, identity)
            } else {
                guard Self.serviceIsMissing(status) else { try requireSuccess(status, operation: "print"); return }
                validatedJobs[service(profile)] = (profile, identity)
                try requireSuccess(try await command(["bootstrap", domain, profile.launchAgentPath]), operation: "bootstrap")
            }
            // Without -k, kickstart leaves an already running job alone.
            try requireSuccess(try await command(["kickstart", service(profile)]), operation: "kickstart")
            log("CamillaDSP service start/adoption completed")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OwnershipMismatch {
            // An unrelated job is a permanent authority refusal, not a service
            // failure that a bounded startup recovery should keep retrying.
            throw SwitcherError.message(error.localizedDescription)
        } catch {
            throw DSPFailure.unavailable(error.localizedDescription)
        }
    }
    public func stop(_ profile: Profile) async throws {
        // Reconciler may request cleanup after start throws. A preflight refusal
        // acquired no service ownership, so it cannot stop an untouched DSP job.
        guard !refusedStarts.contains(service(profile)) else {
            log("DSP activation was refused before adoption; existing service left unchanged")
            return
        }
        // Missing jobs need no configuration inspection. Loaded jobs must prove
        // their configured identity again, including after an earlier start.
        guard profile.launchAgentLabel.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw SwitcherError.message("Invalid LaunchAgent label")
        }
        disconnect()
        let status = try await command(["print", service(profile)])
        if Self.serviceIsMissing(status) { return }
        try requireSuccess(status, operation: "print")
        let identity = try stopIdentity(profile)
        try validateOwnership(status, profile: profile, identity: identity)
        let unload = try await command(["bootout", service(profile)])
        // bootout can return while the process is still exiting. One event-bound
        // grace period precedes the single verification; no rechecking loop.
        if unload.status == 0 {
            log("Unload requested; allowing one second for service shutdown")
            try await sleep(1000)
        }
        let after = try await command(["print", service(profile)])
        guard Self.serviceIsMissing(after) else {
            try requireSuccess(unload, operation: "bootout")
            if after.status != 0 { try requireSuccess(after, operation: "verify bootout") }
            throw SwitcherError.message("CamillaDSP job is still registered one second after bootout; shutdown could not be confirmed")
        }
        log("CamillaDSP service unloaded")
    }
    private func disconnect() {
        socketID = nil; verified = false; socketFailure = nil
        connection?.close(); connection = nil; socket = nil
    }
    public func verifyReadiness(_ profile: Profile) async throws {
        let url = try validate(profile).endpoint
        disconnect()
        let id = UUID(); socketID = id
        let connection = BoundedWebSocketConnection(url: url, timeout: 5, failure: { [weak self] reason in
            Task { @MainActor in
                guard let self, self.socketID == id else { return }
                self.socketFailure = reason
                if self.verified {
                    self.verified = false
                    self.onFailure?(reason)
                }
            }
        })
        let socket = connection.socket!
        self.connection = connection; self.socket = socket
        // One deadline for the entire exchange, cancelled after the finite verification.
        let deadline = DispatchWorkItem { connection.abort() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel() }
        socket.resume()
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let config = try await query("GetConfigJson", socket: socket)
                try DSPReadiness.validateConfiguration(config, profile: profile)
                let state = try await query("GetState", socket: socket)
                log("CamillaDSP reported state: \(String(describing: state))")
                do { try DSPReadiness.validateState(state) }
                catch DSPFailure.starting { throw DSPFailure.starting }
                catch {
                    let readinessError = error.localizedDescription
                    let isTransient = error is DSPFailure
                    // Diagnostic only, once on failure, within the same deadline.
                    let reason = try? await query("GetStopReason", socket: socket)
                    let diagnostic = "\(readinessError). Stop reason: \(reason.map { String(describing: $0) } ?? "unavailable"). Audio routing was not activated."
                    if isTransient { throw DSPFailure.unavailable(diagnostic) }
                    throw SwitcherError.message(diagnostic)
                }
                try Task.checkCancellation()
            } onCancel: { connection.abort() }
            guard socketID == id, socketFailure == nil, socket.state == .running else {
                throw SwitcherError.message(socketFailure ?? "Readiness verification was superseded or disconnected")
            }
            verified = true
            // Keep only delegate-based transport failure observation. No receive loop,
            // recurring health query, ping, reconnect, or timer remains active.
            log("CamillaDSP configuration and readiness verified once; passive transport failure observation only")
        } catch {
            if socketID == id { disconnect() }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let transient = error as? DSPFailure { throw transient }
            if error is URLError { throw DSPFailure.unavailable(error.localizedDescription) }
            throw error
        }
    }
    private func query(_ command: String, socket: URLSessionWebSocketTask) async throws -> Any {
        let request = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let data = try await CamillaDSPWire.request(request, socket: socket,
            invalidResponse: "Unsupported CamillaDSP WebSocket message")
        return try DSPReadiness.value(from: data, command: command)
    }
}
