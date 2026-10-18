import Foundation
import Darwin
import AutoAudioCore

@MainActor public final class LaunchdGUIManager: GUIManaging {
    public var onExit: (@MainActor (String, String) -> Void)?
    private let directory: URL
    private let runCommand: (([String]) async throws -> ProcessResult)?
    private var owned = Set<String>()
    private var shuttingDown = Set<String>()
    private var monitors: [String: DispatchSourceProcess] = [:]
    private var monitorIDs: [String: UUID] = [:]
    private var monitorPIDs: [String: pid_t] = [:]
    public init(directory: URL, runCommand: (([String]) async throws -> ProcessResult)? = nil) {
        self.directory = directory
        self.runCommand = runCommand
    }
    public func beginRecovery(_ profile: Profile, deadline: TimeInterval) { deadlines[profile.id] = deadline }
    private var deadlines: [String: TimeInterval] = [:]
    private func run(_ arguments: [String]) async throws -> ProcessResult {
        // The service identifier or plist identifies the profile's current budget.
        let budget = deadlines.filter { arguments.contains(domain + "/org.camillacompanion.gui." + $0.key) || arguments.contains(directory.appendingPathComponent("org.camillacompanion.gui." + $0.key + ".plist").path) }.values.min()
        let remaining = budget.map { $0 - ProcessInfo.processInfo.systemUptime } ?? 5
        guard remaining > 0 else { throw GUIFailure.transient("GUI recovery time exhausted") }
        do {
            if let runCommand { return try await runCommand(arguments) }
            return try await ProcessRunner.run("/bin/launchctl", arguments: arguments, timeout: min(5, remaining))
        } catch is CancellationError { throw CancellationError() }
        catch { throw GUIFailure.transient(error.localizedDescription) }
    }
    private var domain: String { "gui/\(getuid())" }
    public static func label(_ profile: Profile) -> String { "org.camillacompanion.gui." + profile.id }
    private func service(_ profile: Profile) -> String { domain + "/" + Self.label(profile) }
    private func path(_ profile: Profile) -> URL { directory.appendingPathComponent(Self.label(profile) + ".plist") }
    private func require(_ result: ProcessResult) throws {
        guard result.status == 0 else { throw GUIFailure.transient("GUI launchctl failed: \(result.stderr)") }
    }
    @discardableResult public static func validateBackend(_ profile: Profile) throws -> Data {
        guard let gui = profile.gui else { throw GUIFailure.permanent("Missing GUI configuration or endpoint") }
        guard gui.executablePath.hasPrefix("/"), gui.configPath.hasPrefix("/"),
              !gui.executablePath.contains("\0"), !gui.configPath.contains("\0"),
              FileManager.default.isExecutableFile(atPath: gui.executablePath) else {
            throw GUIFailure.permanent("GUI backend executable or configuration path is unavailable: \(gui.executablePath)")
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: gui.configPath)) }
        catch { throw GUIFailure.permanent("Cannot read GUI configuration: " + error.localizedDescription) }
        try GUIBackendConfiguration(data: data).validate(guiURL: gui.url, dspURL: profile.websocketURL)
        return data
    }
    private func arguments(_ profile: Profile) -> [String] {
        [profile.gui!.executablePath, "-c", profile.gui!.configPath]
    }
    private func validateOwnership(_ result: ProcessResult, profile: Profile) throws {
        // launchctl print includes the loaded source path and direct argument list.
        let lines = result.stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("path = " + path(profile).path),
              let beginning = lines.firstIndex(of: "arguments = {"),
              let end = lines[(beginning + 1)...].firstIndex(of: "}"),
              Array(lines[(beginning + 1)..<end]) == arguments(profile),
              lines.contains("program = " + profile.gui!.executablePath) else {
            throw GUIFailure.permanent("Refusing unrelated GUI job at \(service(profile)); loaded path and arguments do not match.")
        }
        let data = try Data(contentsOf: path(profile))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == Self.label(profile),
              plist["ProgramArguments"] as? [String] == arguments(profile),
              plist["KeepAlive"] == nil || plist["KeepAlive"] as? Bool == false else {
            throw GUIFailure.permanent("Refusing GUI job with mismatched ownership plist")
        }
    }
    public func start(_ profile: Profile) async throws {
        let autoLoad = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents").standardizedFileURL.path
        guard directory.standardizedFileURL.path != autoLoad,
              !directory.standardizedFileURL.path.hasPrefix(autoLoad + "/") else {
            throw GUIFailure.permanent("GUI job directory must be outside the login LaunchAgents directory")
        }
        try Self.validateBackend(profile)
        if shuttingDown.contains(profile.id) {
            let pending = try await run(["print", service(profile)])
            guard LaunchdDSPManager.serviceIsMissing(pending) else {
                try require(pending); try validateOwnership(pending, profile: profile)
                throw GUIFailure.transient("Owned GUI job is still shutting down")
            }
            try ensurePortAvailable(profile, ownedShutdown: true)
            shuttingDown.remove(profile.id)
        }
        let status = try await run(["print", service(profile)])
        if status.status == 0 {
            try validateOwnership(status, profile: profile)
            if Self.pid(status.stdout) == nil { try ensurePortAvailable(profile) }
            owned.insert(profile.id)
        } else {
            guard LaunchdDSPManager.serviceIsMissing(status) else { try require(status); return }
            try ensurePortAvailable(profile)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let plist: [String: Any] = ["Label": Self.label(profile), "ProgramArguments": arguments(profile),
                                       "RunAtLoad": false, "KeepAlive": false,
                                       "StandardOutPath": directory.appendingPathComponent(Self.label(profile) + ".stdout.log").path,
                                       "StandardErrorPath": directory.appendingPathComponent(Self.label(profile) + ".stderr.log").path,
                                       "WorkingDirectory": URL(fileURLWithPath: profile.gui!.executablePath).deletingLastPathComponent().path]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: path(profile), options: .atomic)
            // Track partial bootstrap so later stop can inspect and clean up an owned job.
            owned.insert(profile.id)
            try require(try await run(["bootstrap", domain, path(profile).path]))
        }
        // Retire the previous process observer before a replacement can start.
        monitorIDs.removeValue(forKey: profile.id); monitorPIDs.removeValue(forKey: profile.id)
        monitors.removeValue(forKey: profile.id)?.cancel()
        try require(try await run(["kickstart", service(profile)]))
        // Readiness observations are owned by the bounded controller startup window.
    }
    public func verifyReadiness(_ profile: Profile) async throws {
        let started = try await run(["print", service(profile)])
        guard started.status == 0 else {
            if LaunchdDSPManager.serviceIsMissing(started) { throw GUIFailure.transient("GUI launchd job disappeared during startup") }
            try require(started); return
        }
        try validateOwnership(started, profile: profile)
        guard let pid = Self.pid(started.stdout) else {
            if started.stdout.contains("last exit code =") { throw GUIFailure.transient("GUI backend exited before readiness: " + started.stdout) }
            throw GUIFailure.starting("GUI backend has no running PID; launchd: " + started.stdout)
        }
        if monitors[profile.id] == nil || monitorPIDs[profile.id] != pid {
            monitors.removeValue(forKey: profile.id)?.cancel()
            monitorPIDs[profile.id] = pid
            let token = UUID(); monitorIDs[profile.id] = token
            let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            monitor.setEventHandler { [weak self] in
                guard let self, self.monitorIDs[profile.id] == token else { return }
                self.monitorIDs.removeValue(forKey: profile.id)
                self.monitorPIDs.removeValue(forKey: profile.id)
                self.monitors.removeValue(forKey: profile.id)?.cancel()
                self.onExit?(profile.id, "GUI backend PID \(pid) exited; inspect " + self.directory.appendingPathComponent(Self.label(profile) + ".stderr.log").path)
            }
            monitors[profile.id] = monitor; monitor.resume()
        }
        guard let url = URL(string: profile.gui!.url) else { throw GUIFailure.permanent("Invalid GUI URL") }
        let timeout = min(0.45, max(0.01, (deadlines[profile.id] ?? (ProcessInfo.processInfo.systemUptime + 0.45)) - ProcessInfo.processInfo.systemUptime))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
                  http.url?.host == url.host, http.url?.port == url.port else {
                throw GUIFailure.starting("Configured GUI page is not HTTP-ready")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as GUIFailure { throw failure }
        catch { throw GUIFailure.starting("GUI HTTP readiness: " + error.localizedDescription) }
    }
    static func pid(_ output: String) -> pid_t? {
        for line in output.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("pid = "), let pid = Int32(value.dropFirst(6)), pid > 0 { return pid }
        }
        return nil
    }
    public func stop(_ profile: Profile) async throws {
        let status = try await run(["print", service(profile)])
        if LaunchdDSPManager.serviceIsMissing(status) {
            if shuttingDown.contains(profile.id) { try ensurePortAvailable(profile, ownedShutdown: true); shuttingDown.remove(profile.id) }
            monitorIDs.removeValue(forKey: profile.id)
            monitors.removeValue(forKey: profile.id)?.cancel(); owned.remove(profile.id); return
        }
        try require(status); try validateOwnership(status, profile: profile)
        monitorIDs.removeValue(forKey: profile.id)
        monitors.removeValue(forKey: profile.id)?.cancel()
        shuttingDown.insert(profile.id)
        try require(try await run(["bootout", service(profile)]))
        let after = try await run(["print", service(profile)])
        guard LaunchdDSPManager.serviceIsMissing(after) else {
            throw GUIFailure.transient("GUI stop requested but job removal is unconfirmed: " + after.stdout)
        }
        try ensurePortAvailable(profile, ownedShutdown: true)
        shuttingDown.remove(profile.id); owned.remove(profile.id)
    }
    private func ensurePortAvailable(_ profile: Profile, ownedShutdown: Bool = false) throws {
        let endpoint = URLComponents(string: profile.gui!.url)!
        let ipv6 = ["::1", "[::1]"].contains(endpoint.host!)
        let fd = Darwin.socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GUIFailure.permanent("Cannot check GUI port availability") }
        defer { Darwin.close(fd) }
        var reuse: Int32 = 1
        withUnsafePointer(to: &reuse) { _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size)) }
        var result: Int32 = -1
        if ipv6 {
            var address = sockaddr_in6(); address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6); address.sin6_port = UInt16(endpoint.port!).bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(endpoint.port!).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard result == 0 else {
            if ownedShutdown { throw GUIFailure.transient("Owned GUI shutdown is awaiting HTTP port release") }
            throw GUIFailure.permanent("GUI port unavailable or already occupied; refusing to stop its owner.")
        }
    }
}
