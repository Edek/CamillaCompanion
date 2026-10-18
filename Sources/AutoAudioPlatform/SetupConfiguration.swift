import Foundation
import Darwin
import AutoAudioCore
import Yams

public struct SetupDraft: Sendable {
    public var executablePath = ""
    public var configurationPath = ""
    public var captureUID = ""
    public var playbackUID = ""
    public var websocketPort = 1234
    public var existingLaunchAgentPath: String?
    public var presetsFolderPath: String?
    public var gui: GUIConfiguration?
    public var confirmedGUIAbsent = false
    public var automaticSwitching = false
    public init() {}
}

public struct SetupReceipt: Codable, Equatable, Sendable {
    public var version = 1
    public var confirmedGUIAbsentProfileIDs: [String]
    public init(confirmedGUIAbsentProfileIDs: [String] = []) {
        self.confirmedGUIAbsentProfileIDs = confirmedGUIAbsentProfileIDs
    }
    public static func url(configurationURL: URL) -> URL {
        configurationURL.deletingLastPathComponent().appendingPathComponent("app-setup.json")
    }
    public static func load(configurationURL: URL) throws -> SetupReceipt {
        do {
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url(configurationURL: configurationURL)))
            guard value.version == 1 else { throw SwitcherError.message("Unsupported setup information version") }
            return value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init() }
    }
}

public struct PreparedSetup {
    public let configuration: Configuration
    public let preferences: UIPreferences
    public let receipt: SetupReceipt
    public let summary: String
    public let hardwareAvailable: Bool
    fileprivate let jobData: Data?
    fileprivate let sourceFiles: [URL: Data]
    fileprivate let reservedStateURL: URL?
}

public typealias SetupCommandRunner = @MainActor (String, [String]) async throws -> ProcessResult

/// First-run file preparation. No service or audio changes occur here.
@MainActor public enum SetupConfigurationService {
    public static func selectors(configurationPath: String) throws -> (capture: String, playback: String) {
        let yaml = try String(contentsOfFile: configurationPath, encoding: .utf8)
        guard let root = try Yams.load(yaml: yaml) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else {
            throw SwitcherError.message("Choose a CamillaDSP YAML configuration with a devices section.")
        }
        func selector(_ key: String) throws -> String {
            guard let section = devices[key] as? [String: Any], section["type"] as? String == "CoreAudio",
                  let name = section["device"] as? String, !name.isEmpty else {
                throw SwitcherError.message("This beta requires explicit CoreAudio capture and playback devices in the DSP configuration.")
            }
            return name
        }
        return try (selector("capture"), selector("playback"))
    }

    public static func prepare(_ draft: SetupDraft, configurationURL: URL, devices: [AudioDevice],
                               commandRunner: SetupCommandRunner? = nil) async throws -> PreparedSetup {
        let fm = FileManager.default
        guard draft.executablePath.hasPrefix("/"), URL(fileURLWithPath: draft.executablePath).lastPathComponent == "camilladsp",
              fm.isExecutableFile(atPath: draft.executablePath) else {
            throw SwitcherError.message("Choose the installed camilladsp executable.")
        }
        let yamlURL = URL(fileURLWithPath: draft.configurationPath)
        guard draft.configurationPath.hasPrefix("/"), (try yamlURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw SwitcherError.message("Choose an existing CamillaDSP YAML configuration.")
        }
        let yamlBytes = try Data(contentsOf: yamlURL)
        let selectors = try selectors(configurationPath: draft.configurationPath)
        let runner = commandRunner ?? { try await ProcessRunner.run($0, arguments: $1, workingDirectory: yamlURL.deletingLastPathComponent()) }
        let validation = try await runner(draft.executablePath, ["--check", draft.configurationPath])
        guard validation.status == 0 else {
            throw SwitcherError.message("CamillaDSP could not validate this configuration. " + String((validation.stderr + validation.stdout).prefix(2000)))
        }
        guard try Data(contentsOf: yamlURL) == yamlBytes else {
            throw SwitcherError.message("The DSP configuration changed during validation. Review setup again.")
        }
        guard (1...65535).contains(draft.websocketPort), !draft.captureUID.isEmpty, !draft.playbackUID.isEmpty,
              !draft.captureUID.contains("\0"), !draft.playbackUID.contains("\0"),
              draft.captureUID != draft.playbackUID else { throw SwitcherError.message("Select distinct capture and playback devices and a valid WebSocket port.") }
        func validateDevice(_ uid: String, selector: String) throws {
            guard devices.filter({ $0.name == selector }).count < 2 || selector == uid else {
                throw SwitcherError.message("More than one connected device is named \(selector). Use explicit device UIDs in the DSP configuration.")
            }
            if let device = devices.first(where: { $0.uid == uid }) {
                guard device.hasOutput, selector == uid || selector == device.name else {
                    throw SwitcherError.message("The selected device does not match the DSP configuration's selector: \(selector)")
                }
            }
        }
        try validateDevice(draft.captureUID, selector: selectors.capture)
        try validateDevice(draft.playbackUID, selector: selectors.playback)
        if let folder = draft.presetsFolderPath {
            guard folder.hasPrefix("/"), (try URL(fileURLWithPath: folder).resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw SwitcherError.message("Choose an existing presets folder.")
            }
        }
        var label = "com.camillacompanion.dsp.default"
        var jobURL = configurationURL.deletingLastPathComponent().appendingPathComponent("DSPJobs/\(label).plist")
        var jobData: Data?
        var reservedStateURL: URL?
        var sources = [yamlURL: yamlBytes]
        if let existing = draft.existingLaunchAgentPath {
            jobURL = URL(fileURLWithPath: existing)
            let data = try Data(contentsOf: jobURL)
            guard let job = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let existingLabel = job["Label"] as? String,
                  let arguments = job["ProgramArguments"] as? [String], arguments.first == draft.executablePath,
                  arguments.contains(draft.configurationPath) else {
                throw SwitcherError.message("The LaunchAgent must directly run the chosen CamillaDSP executable and configuration.")
            }
            func option(_ names: [String]) -> String? {
                for (index, argument) in arguments.enumerated() {
                    if names.contains(argument), index + 1 < arguments.count { return arguments[index + 1] }
                    for name in names where argument.hasPrefix(name + "=") { return String(argument.dropFirst(name.count + 1)) }
                    if names.contains("-p"), argument.hasPrefix("-p"), argument.count > 2 { return String(argument.dropFirst(2)) }
                }
                return nil
            }
            guard option(["-p", "--port"]) == String(draft.websocketPort),
                  let address = option(["-a", "--address"]), ["127.0.0.1", "localhost", "::1"].contains(address),
                  job["KeepAlive"] == nil || (job["KeepAlive"] as? Bool) == false,
                  job["RunAtLoad"] == nil || (job["RunAtLoad"] as? Bool) == false else {
                throw SwitcherError.message("Import requires an on-demand LaunchAgent with KeepAlive and RunAtLoad off, and a loopback WebSocket address matching the selected port. Its file will not be changed.")
            }
            label = existingLabel; sources[jobURL] = data
        } else {
            let stateURL = jobURL.deletingLastPathComponent().appendingPathComponent("default-state.yml")
            guard !fm.fileExists(atPath: stateURL.path) else {
                throw SwitcherError.message("Existing DSP state was found at the setup location. It was preserved. Choose an existing compatible LaunchAgent instead.")
            }
            reservedStateURL = stateURL
            let job: [String: Any] = ["Label": label,
                "ProgramArguments": [draft.executablePath, "-s", stateURL.path, "-a", "127.0.0.1", "-p", String(draft.websocketPort), draft.configurationPath],
                "WorkingDirectory": yamlURL.deletingLastPathComponent().path, "RunAtLoad": false, "KeepAlive": false,
                "ProcessType": "Interactive", "StandardOutPath": configurationURL.deletingLastPathComponent().appendingPathComponent("camilladsp.stdout.log").path,
                "StandardErrorPath": configurationURL.deletingLastPathComponent().appendingPathComponent("camilladsp.stderr.log").path]
            jobData = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        }
        let profile = Profile(id: "default", name: "CamillaDSP", triggerUID: draft.playbackUID,
            captureUID: draft.captureUID, playbackUID: draft.playbackUID, launchAgentLabel: label,
            launchAgentPath: jobURL.path, websocketURL: "ws://127.0.0.1:\(draft.websocketPort)",
            expectedCaptureDevice: selectors.capture, expectedPlaybackDevice: selectors.playback, gui: draft.gui,
            requiresExclusiveDSP: true)
        let configuration = Configuration(profiles: [profile]); try ConfigurationLoader.validate(configuration)
        if let gui = profile.gui {
            sources[URL(fileURLWithPath: gui.configPath)] = try LaunchdGUIManager.validateBackend(profile)
        }
        let preferences = UIPreferences(presetsFolderPath: draft.presetsFolderPath, automaticSwitching: draft.automaticSwitching,
            companionDSPMode: .forceOn, companionProfileID: profile.id)
        _ = try preferences.validated()
        let available = devices.contains(where: { $0.uid == draft.captureUID }) && devices.contains(where: { $0.uid == draft.playbackUID })
        let summary = "DSP: \(draft.executablePath)\nConfiguration: \(draft.configurationPath)\nCapture: \(selectors.capture)\nPlayback: \(selectors.playback)\n\(draft.existingLaunchAgentPath == nil ? "Create on-demand DSP job" : "Import on-demand DSP job"): \(label)\nMode: \(draft.automaticSwitching ? "Automatic Switching" : "Companion Mode, macOS output unchanged")\n\(available ? "Selected devices are connected." : "A selected device is disconnected. DSP will wait until it is available.")\nCamillaDSP will be managed when you activate. Existing DSP configuration files are kept as they are."
        return PreparedSetup(configuration: configuration, preferences: preferences,
            receipt: .init(confirmedGUIAbsentProfileIDs: draft.confirmedGUIAbsent && draft.gui == nil ? [profile.id] : []),
            summary: summary, hardwareAvailable: available, jobData: jobData, sourceFiles: sources, reservedStateURL: reservedStateURL)
    }

    /// A single bounded read immediately before first activation, with no kill, bootout, or audio mutation.
    public static func checkForConflictingDSP(_ prepared: PreparedSetup, commandRunner: SetupCommandRunner? = nil) async throws {
        try validateSources(prepared)
        let profile = prepared.configuration.profiles[0]
        let allowedJob = prepared.jobData == nil ? prepared.sourceFiles[URL(fileURLWithPath: profile.launchAgentPath)] : nil
        try await inspectDSPConflicts(profile: profile, allowedJob: allowedJob, commandRunner: commandRunner)
    }

    /// The same finite ownership check at later activations, including Save Only followed by run or login.
    public static func checkForConflictingDSP(profile: Profile, commandRunner: SetupCommandRunner? = nil) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: profile.launchAgentPath))
        try await inspectDSPConflicts(profile: profile, allowedJob: data, commandRunner: commandRunner)
        guard try Data(contentsOf: URL(fileURLWithPath: profile.launchAgentPath)) == data else {
            throw SwitcherError.message("The saved DSP job changed during activation checks.")
        }
    }

    private static func inspectDSPConflicts(profile: Profile, allowedJob: Data?, commandRunner: SetupCommandRunner?) async throws {
        let runner = commandRunner ?? { try await ProcessRunner.run($0, arguments: $1) }
        guard profile.launchAgentPath.hasPrefix("/"),
              profile.launchAgentLabel.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw SwitcherError.message("The DSP service identity is invalid. Setup has not changed anything.")
        }
        var allowedArguments: [String]?
        if let allowedJob {
            guard let plist = try PropertyListSerialization.propertyList(from: allowedJob, format: nil) as? [String: Any],
                  plist["Label"] as? String == profile.launchAgentLabel,
                  let args = plist["ProgramArguments"] as? [String], let executable = args.first,
                  executable.hasPrefix("/"), URL(fileURLWithPath: executable).lastPathComponent == "camilladsp",
                  plist["Program"] == nil || plist["Program"] as? String == executable else {
                throw SwitcherError.message("The saved DSP job no longer matches this setup.")
            }
            allowedArguments = args
        }
        var permittedPID: Int?
        let job = try await runner("/bin/launchctl", ["print", "gui/\(getuid())/\(profile.launchAgentLabel)"])
        if job.status == 0 {
            let lines = job.stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let args = allowedArguments, lines.contains("path = " + profile.launchAgentPath),
                  lines.contains("program = " + (args.first ?? "")),
                  let first = lines.firstIndex(of: "arguments = {"), let last = lines[(first + 1)...].firstIndex(of: "}"),
                  Array(lines[(first + 1)..<last]) == args else {
                throw SwitcherError.message("A different DSP job already uses this service identity. Setup will not replace it.")
            }
            permittedPID = lines.first(where: { $0.hasPrefix("pid = ") }).flatMap { Int($0.dropFirst(6)) }
        } else if !LaunchdDSPManager.serviceIsMissing(job) {
            throw SwitcherError.message("Cannot inspect the existing DSP service. Setup has not changed anything.")
        }
        let processes = try await runner("/bin/ps", ["-axo", "pid=,comm="])
        guard processes.status == 0 else { throw SwitcherError.message("Cannot check for another running CamillaDSP instance.") }
        for line in processes.stdout.components(separatedBy: .newlines) {
            let values = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard values.count == 2, let pid = Int(values[0]) else { continue }
            if URL(fileURLWithPath: String(values[1])).lastPathComponent == "camilladsp", pid != permittedPID {
                throw SwitcherError.message("CamillaDSP is already running outside this setup. Stop it in its current manager before activating, or import its compatible LaunchAgent. Setup will not stop it.")
            }
        }
    }

    /// Publishes only new files. Config is published last; failures remove only bytes this transaction created.
    public static func save(_ prepared: PreparedSetup, configurationURL: URL, runtimeStateURL: URL,
                            publishFile: ((Data, URL) throws -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: runtimeStateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(runtimeStateURL.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SwitcherError.message("Cannot inspect the controller lock.") }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw SwitcherError.message("Another controller is using these settings. Setup has not changed anything.")
        }
        try validateSources(prepared)
        let priorState = [runtimeStateURL, runtimeStateURL.appendingPathExtension("aux-preferences.json"),
                          runtimeStateURL.appendingPathExtension("fallback-preferences.json")]
        guard priorState.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SwitcherError.message("Existing controller state or settings were found. They were preserved. Choose a new setup location or recover the existing configuration.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var files: [(URL, Data)] = []
        if let job = prepared.jobData { files.append((URL(fileURLWithPath: prepared.configuration.profiles[0].launchAgentPath), job)) }
        files.append((runtimeStateURL.appendingPathExtension("ui-preferences.json"), try encoder.encode(prepared.preferences)))
        files.append((SetupReceipt.url(configurationURL: configurationURL), try encoder.encode(prepared.receipt)))
        files.append((configurationURL, try encoder.encode(prepared.configuration)))
        guard files.allSatisfy({ !FileManager.default.fileExists(atPath: $0.0.path) }) else {
            throw SwitcherError.message("Existing setup or settings were found. They were preserved. Open the existing configuration instead.")
        }
        var created: [(URL, Data)] = []
        let publish = publishFile ?? publishNew
        do {
            for (url, data) in files {
                try publish(data, url); created.append((url, data))
            }
        } catch {
            for (url, data) in created.reversed() where (try? Data(contentsOf: url)) == data { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    public static func validateForActivation(_ prepared: PreparedSetup) throws {
        try validateSources(prepared)
        if let job = prepared.jobData {
            guard try Data(contentsOf: URL(fileURLWithPath: prepared.configuration.profiles[0].launchAgentPath)) == job else {
                throw SwitcherError.message("The saved DSP job changed. Review setup again before activating.")
            }
        }
    }
    private static func validateSources(_ prepared: PreparedSetup) throws {
        for (url, expected) in prepared.sourceFiles where try Data(contentsOf: url) != expected {
            throw SwitcherError.message("A selected configuration file changed. Review setup again before activating.")
        }
        if let state = prepared.reservedStateURL, FileManager.default.fileExists(atPath: state.path) {
            throw SwitcherError.message("Existing DSP state was found at the setup location. Setup has preserved it.")
        }
    }
    private static func publishNew(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard link(temporary.path, url.path) == 0 else { throw SwitcherError.message("Cannot create setup file without replacing existing data: \(url.lastPathComponent)") }
    }
}
