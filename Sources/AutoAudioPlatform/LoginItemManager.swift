import Foundation
import Darwin
import AutoAudioCore

public enum LoginItemState: String, Sendable { case enabled, disabled, unavailable }

public struct LoginItemStatus: Sendable {
    public let state: LoginItemState
    public let canChange: Bool
    public let message: String
    public let label: String?
    public var isEnabled: Bool { state == .enabled }
    public init(state: LoginItemState, canChange: Bool, message: String, label: String? = nil) {
        self.state = state; self.canChange = canChange; self.message = message; self.label = label
    }
}

/// Injection boundary keeps checks away from the user's LaunchAgents and launchd domain.
@MainActor public protocol LoginItemBackend: AnyObject {
    func files(in directory: URL) throws -> [URL]
    func read(_ url: URL) throws -> Data?
    func executableExists(_ url: URL) -> Bool
    func writeAtomically(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
    func backup(_ data: Data, name: String, directory: URL) throws
    func launchctl(_ arguments: [String]) async throws -> ProcessResult
}

@MainActor public final class SystemLoginItemBackend: LoginItemBackend {
    public init() {}
    public func files(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
    public func read(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SwitcherError.message("Login configuration must be a regular file: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    }
    public func executableExists(_ url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path) }
    public func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func remove(_ url: URL) throws {
        if try read(url) != nil { try FileManager.default.removeItem(at: url) }
    }
    public func backup(_ data: Data, name: String, directory: URL) throws {
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try writeAtomically(data, to: destination)
    }
    public func launchctl(_ arguments: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run("/bin/launchctl", arguments: arguments, timeout: 3)
    }
}

/// Controls future logins only. Never bootstraps, stops or restarts the current session.
@MainActor public final class LoginItemManager {
    public private(set) var status = LoginItemStatus(state: .unavailable, canChange: false, message: "Checking login setting…")
    private let executableURL: URL
    private let configURL: URL
    private let stateURL: URL
    private let directory: URL
    private let domain: String
    private let backend: any LoginItemBackend
    private var changing = false
    private static let currentLabel = "org.camillacompanion.login"
    private var reservedLabels: Set<String> { [Self.currentLabel] }

    public init(executableURL: URL, configURL: URL, stateURL: URL,
                launchAgentsDirectory: URL? = nil, domain: String? = nil, backend: (any LoginItemBackend)? = nil) {
        self.executableURL = executableURL.standardizedFileURL
        self.configURL = configURL.standardizedFileURL
        self.stateURL = stateURL.standardizedFileURL
        self.directory = launchAgentsDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
        self.domain = domain ?? "gui/\(getuid())"
        self.backend = backend ?? SystemLoginItemBackend()
    }

    @discardableResult public func refresh() async -> LoginItemStatus {
        guard !changing else { return status }
        do { status = try await inspect().status }
        catch { status = LoginItemStatus(state: .unavailable, canChange: false, message: error.localizedDescription) }
        return status
    }

    @discardableResult public func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus {
        guard !changing else { throw SwitcherError.message("A login setting change is already in progress") }
        changing = true
        defer { changing = false }
        do {
            let before = try await inspect()
            if (before.status.state == .enabled) == enabled { status = before.status; return status }
            let oldData = before.job?.data
            let label = before.job?.label ?? Self.currentLabel
            let path = before.job?.url ?? directory.appendingPathComponent(label + ".plist")
            var plist = before.job?.plist ?? newPropertyList()
            plist["Disabled"] = !enabled
            if let oldData {
                try backend.backup(oldData, name: path.lastPathComponent,
                    directory: stateURL.deletingLastPathComponent().appendingPathComponent("LoginItemBackups"))
            }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            var written = false
            do {
                // Refuse changes that raced an external editor or another Settings window.
                guard try backend.read(path) == oldData else { throw SwitcherError.message("Login configuration changed. Reopen Settings and try again.") }
                try backend.writeAtomically(data, to: path)
                written = true
                try require(try await backend.launchctl([enabled ? "enable" : "disable", domain + "/" + label]))
                let after = try await inspect()
                guard after.status.state == (enabled ? .enabled : .disabled) else {
                    throw SwitcherError.message("macOS did not confirm the login setting")
                }
                status = after.status
                return status
            } catch {
                let original = error
                guard written else { throw original }
                do {
                    // Never overwrite a subsequent edit while rolling back our own transaction.
                    guard try backend.read(path) == data else {
                        throw SwitcherError.message("Login configuration changed during rollback")
                    }
                    if let oldData { try backend.writeAtomically(oldData, to: path) }
                    else { try backend.remove(path) }
                    let wasDisabled = before.overrideDisabled ?? (before.status.state != .enabled)
                    try require(try await backend.launchctl([wasDisabled ? "disable" : "enable", domain + "/" + label]))
                } catch {
                    throw SwitcherError.message("\(original.localizedDescription). Could not restore the previous login setting: \(error.localizedDescription)")
                }
                throw original
            }
        } catch {
            // A successful rollback leaves the actual startup choice usable. The
            // Settings checkbox must return to that choice instead of implying Off.
            let failure = error
            do { status = try await inspect().status }
            catch { status = LoginItemStatus(state: .unavailable, canChange: false, message: failure.localizedDescription) }
            throw failure
        }
    }

    private struct Job {
        let url: URL
        let data: Data
        let plist: [String: Any]
        let label: String
        var arguments: [String] { plist["ProgramArguments"] as! [String] }
    }
    private struct Inspection {
        let job: Job?
        let overrideDisabled: Bool?
        let status: LoginItemStatus
    }
    private func inspect() async throws -> Inspection {
        guard [executableURL, configURL, stateURL].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
              backend.executableExists(executableURL), try backend.read(configURL) != nil else {
            throw SwitcherError.message("Choose an available app executable and configuration before enabling login startup")
        }
        var jobs: [Job] = []
        let files = try backend.files(in: directory).filter { $0.pathExtension == "plist" }
        for url in files {
            let reservedFilename = reservedLabels.contains(url.deletingPathExtension().lastPathComponent)
            let data: Data
            let plist: [String: Any]
            do {
                guard let value = try backend.read(url) else { continue }
                data = value
                guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw SwitcherError.message("Cannot inspect login configuration: \(url.lastPathComponent)")
                }
                plist = value
            } catch {
                // Other applications' damaged or protected files must not prevent
                // this setting. Our reserved paths still require full inspection.
                if reservedFilename { throw error }
                continue
            }
            let label = plist["Label"] as? String ?? ""
            let args = plist["ProgramArguments"] as? [String] ?? []
            let related = args.first == executableURL.path || value("--state", in: args) == stateURL.path || value("--config", in: args) == configURL.path
            if reservedLabels.contains(label) || reservedLabels.contains(url.deletingPathExtension().lastPathComponent) || related {
                guard reservedLabels.contains(label), url.lastPathComponent == label + ".plist",
                      compatible(plist, arguments: args) else {
                    throw SwitcherError.message("Another login job conflicts with this app. Review \(url.lastPathComponent) before changing Start at Login.")
                }
                jobs.append(Job(url: url, data: data, plist: plist, label: label))
            }
        }
        guard jobs.count <= 1 else { throw SwitcherError.message("Multiple app login jobs exist. Keep one startup job before changing Start at Login.") }
        let job = jobs.first
        for label in reservedLabels.sorted() {
            let loaded = try await backend.launchctl(["print", domain + "/" + label])
            if loaded.status == 0 {
                guard let job, job.label == label, loadedMatches(loaded.stdout, job: job) else {
                    throw SwitcherError.message("A loaded app login job does not match its saved configuration. Start at Login is unavailable.")
                }
            } else if !LaunchdDSPManager.serviceIsMissing(loaded) { try require(loaded) }
        }
        let overrides = try await backend.launchctl(["print-disabled", domain])
        try require(overrides)
        let disabled = try overrideValue(for: job?.label ?? Self.currentLabel, output: overrides.stdout)
        let enabled = job != nil && !(disabled ?? (job?.plist["Disabled"] as? Bool ?? false))
        return Inspection(job: job, overrideDisabled: disabled,
            status: LoginItemStatus(state: enabled ? .enabled : .disabled, canChange: true,
                message: "Applies at your next login.", label: job?.label))
    }
    private func compatible(_ plist: [String: Any], arguments: [String]) -> Bool {
        guard arguments.count >= 8, arguments[0] == executableURL.path, arguments[1] == "run",
              value("--config", in: arguments) == configURL.path, value("--state", in: arguments) == stateURL.path,
              value("--menu-bar", in: arguments) == "true", plist["Program"] == nil,
              plist["RunAtLoad"] as? Bool == true, plist["ProcessType"] as? String == "Interactive" else { return false }
        // Preserve all existing arguments and environment, including profile/session choices.
        // Duplicate core options are ambiguous even if one occurrence matches.
        return ["--config", "--state", "--menu-bar"].allSatisfy { key in arguments.filter { $0 == key }.count == 1 }
    }
    private func loadedMatches(_ output: String, job: Job) -> Bool {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("path = " + job.url.path), lines.contains("program = " + executableURL.path),
              let start = lines.firstIndex(of: "arguments = {"),
              let end = lines[(start + 1)...].firstIndex(of: "}") else { return false }
        return Array(lines[(start + 1)..<end]) == job.arguments
    }
    private func value(_ key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    private func overrideValue(for label: String, output: String) throws -> Bool? {
        guard output.contains("disabled services = {") && output.contains("}") else {
            throw SwitcherError.message("Cannot read macOS login startup status")
        }
        let prefix = "\"" + label + "\" => "
        let values = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.hasPrefix(prefix) }
        guard values.count <= 1 else { throw SwitcherError.message("Ambiguous macOS login startup status") }
        guard let line = values.first else { return nil }
        switch String(line.dropFirst(prefix.count)) {
        case "true", "disabled": return true
        case "false", "enabled": return false
        default: throw SwitcherError.message("Cannot read macOS login startup status")
        }
    }
    private func newPropertyList() -> [String: Any] {
        ["Label": Self.currentLabel,
         "ProgramArguments": [executableURL.path, "run", "--config", configURL.path, "--state", stateURL.path, "--menu-bar", "true"],
         "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive",
         "StandardOutPath": stateURL.deletingLastPathComponent().appendingPathComponent("camillacompanion.stdout.log").path,
         "StandardErrorPath": stateURL.deletingLastPathComponent().appendingPathComponent("camillacompanion.stderr.log").path]
    }
    private func require(_ result: ProcessResult) throws {
        guard result.status == 0 else {
            throw SwitcherError.message("macOS could not update login startup: " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
