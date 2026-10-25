import Foundation
import Darwin
import AutoAudioCore

public struct InterfaceProfileDraft: Equatable, Sendable {
    public var id: String
    public var name: String
    public var executablePath: String
    public var configurationPath: String
    public var triggerUID: String
    public var captureUID: String
    public var playbackUID: String
    public var managedFeedUID: String?
    /// Snapshot-only provenance for the configured startup YAML. Never persisted in Configuration.
    public var loadedConfigurationPath: String?
    /// IDs the user confirmed will lose auto-activation when this draft is saved.
    /// Snapshot-only metadata; never persisted in Configuration.
    public var confirmedAutoActivationReplacementIDs: Set<String>
    public var dspInputUID: String {
        get { captureUID }
        set { captureUID = newValue }
    }
    public var websocketPort: Int
    public var autoActivate: Bool
    public var routeAlerts: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String = "", executablePath: String = "",
                configurationPath: String = "", triggerUID: String = "", captureUID: String = "",
                playbackUID: String = "", websocketPort: Int = 1234, autoActivate: Bool = true,
                routeAlerts: Bool = false, loadedConfigurationPath: String? = nil,
                confirmedAutoActivationReplacementIDs: Set<String> = []) {
        self.init(id: id, name: name, executablePath: executablePath, configurationPath: configurationPath,
                  triggerUID: triggerUID, captureUID: captureUID, managedFeedUID: captureUID,
                  playbackUID: playbackUID, websocketPort: websocketPort, autoActivate: autoActivate,
                  routeAlerts: routeAlerts, loadedConfigurationPath: loadedConfigurationPath,
                  confirmedAutoActivationReplacementIDs: confirmedAutoActivationReplacementIDs)
    }

    /// Role-aware initializer. Pass nil to save a Companion-only profile.
    public init(id: String = UUID().uuidString.lowercased(), name: String = "", executablePath: String = "",
                configurationPath: String = "", triggerUID: String = "", captureUID: String = "",
                managedFeedUID: String?, playbackUID: String = "", websocketPort: Int = 1234,
                autoActivate: Bool = true, routeAlerts: Bool = false, loadedConfigurationPath: String? = nil,
                confirmedAutoActivationReplacementIDs: Set<String> = []) {
        self.id = id; self.name = name; self.executablePath = executablePath
        self.configurationPath = configurationPath; self.triggerUID = triggerUID
        self.captureUID = captureUID; self.managedFeedUID = managedFeedUID; self.playbackUID = playbackUID
        self.loadedConfigurationPath = loadedConfigurationPath
        self.confirmedAutoActivationReplacementIDs = confirmedAutoActivationReplacementIDs
        self.websocketPort = websocketPort; self.autoActivate = autoActivate; self.routeAlerts = routeAlerts
    }
}

public struct InterfaceProfilesState {
    public let profiles: [InterfaceProfileDraft]
    public let devices: [AudioDevice]
    public let activeProfileID: String?
    public let selectedProfileID: String?
    public let pendingProfileIDs: Set<String>
    public let profileIssues: [String: String]
    public init(profiles: [InterfaceProfileDraft], devices: [AudioDevice], activeProfileID: String?,
                selectedProfileID: String? = nil, pendingProfileIDs: Set<String> = [],
                profileIssues: [String: String] = [:]) {
        self.profiles = profiles; self.devices = devices; self.activeProfileID = activeProfileID
        self.selectedProfileID = selectedProfileID; self.pendingProfileIDs = pendingProfileIDs
        self.profileIssues = profileIssues
    }
}

/// Stores interface profiles in the existing config without changing runtime services or routing.
@MainActor public final class InterfaceProfileStore {
    public typealias CommandRunner = SetupCommandRunner
    private let configurationURL: URL
    private let commandRunner: CommandRunner?
    private var baseline: Data?
    private var mutationInProgress = false

    public init(configurationURL: URL, commandRunner: CommandRunner? = nil) {
        self.configurationURL = configurationURL; self.commandRunner = commandRunner
    }

    public func snapshot(devices: [AudioDevice], activeProfileID: String?, selectedProfileID: String? = nil,
                         loadedProfiles: [Profile]? = nil) throws -> InterfaceProfilesState {
        let (data, configuration) = try readConfiguration()
        baseline = baseline ?? data
        try ensureUnchanged(data)
        var profileIssues: [String: String] = [:]
        let profiles = configuration.profiles.map { profile -> InterfaceProfileDraft in
            do {
                let details = try Self.readJob(path: profile.launchAgentPath, configuredLabel: profile.launchAgentLabel)
                guard URLComponents(string: profile.websocketURL)?.port == details.port else {
                    throw SwitcherError.message("The saved DSP job port does not match this profile.")
                }
                return InterfaceProfileDraft(id: profile.id, name: profile.name,
                    executablePath: details.executablePath, configurationPath: details.configurationPath,
                    triggerUID: profile.triggerUID, captureUID: profile.captureUID, managedFeedUID: profile.managedFeedUID,
                    playbackUID: profile.playbackUID,
                    websocketPort: details.port, autoActivate: profile.autoActivate, routeAlerts: profile.routeAlerts,
                    loadedConfigurationPath: details.configurationPath)
            } catch {
                profileIssues[profile.id] = error.localizedDescription
                return InterfaceProfileDraft(id: profile.id, name: profile.name, executablePath: "", configurationPath: "",
                    triggerUID: profile.triggerUID, captureUID: profile.captureUID, managedFeedUID: profile.managedFeedUID,
                    playbackUID: profile.playbackUID, websocketPort: URLComponents(string: profile.websocketURL)?.port ?? 1234,
                    autoActivate: profile.autoActivate, routeAlerts: profile.routeAlerts)
            }
        }
        let pending: Set<String>
        if let loadedProfiles {
            let savedByID = Dictionary(uniqueKeysWithValues: configuration.profiles.map { ($0.id, $0) })
            let loadedByID = Dictionary(uniqueKeysWithValues: loadedProfiles.map { ($0.id, $0) })
            pending = Set(Set(savedByID.keys).union(loadedByID.keys).filter { savedByID[$0] != loadedByID[$0] })
        } else { pending = [] }
        return InterfaceProfilesState(profiles: profiles, devices: devices, activeProfileID: activeProfileID,
                                      selectedProfileID: selectedProfileID, pendingProfileIDs: pending,
                                      profileIssues: profileIssues)
    }

    public static func suggestedDSPPaths(profiles: [InterfaceProfileDraft], activeProfileID: String?) -> (executablePath: String, configurationPath: String)? {
        ProfileDeviceMapping.savedDSPPaths(profiles: profiles, activeProfileID: activeProfileID)
    }

    @discardableResult public func save(_ draft: InterfaceProfileDraft, devices: [AudioDevice]) async throws -> Configuration {
        guard !mutationInProgress else { throw SwitcherError.message("A profile save is already in progress.") }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let (originalBytes, original) = try readConfiguration()
        baseline = baseline ?? originalBytes
        try ensureUnchanged(originalBytes)
        try Self.validateDraft(draft, devices: devices)
        let existingIndex = original.profiles.firstIndex(where: { $0.id == draft.id })
        let existing = existingIndex.map { original.profiles[$0] }
        let replacementIDs = draft.autoActivate
            ? Set(original.profiles.filter { $0.id != draft.id && $0.triggerUID == draft.triggerUID && $0.autoActivate }.map(\.id))
            : []
        guard draft.confirmedAutoActivationReplacementIDs == replacementIDs else {
            throw SwitcherError.message(replacementIDs.isEmpty
                ? "The auto-activation confirmation is out of date. Refresh Interfaces settings before saving."
                : "Another profile already auto-activates for this connection trigger. Confirm which profile should replace it before saving.")
        }
        let oldJob: DSPJobConfigurationDetails? = try existing.map { try Self.readJob(path: $0.launchAgentPath, configuredLabel: $0.launchAgentLabel) }
        if let expectedPath = draft.loadedConfigurationPath, let oldJob,
           expectedPath != oldJob.configurationPath {
            throw SwitcherError.message("The configured DSP job changed its startup YAML since this editor opened. Refresh Interfaces settings before saving.")
        }
        if let existing, let oldJob, URLComponents(string: existing.websocketURL)?.port != oldJob.port {
            throw SwitcherError.message("The saved DSP job port does not match profile \(existing.name). Reopen setup to review it.")
        }
        let keepJob = existing != nil && oldJob?.executablePath == draft.executablePath &&
            oldJob?.configurationPath == draft.configurationPath && oldJob?.port == draft.websocketPort

        let yamlURL = URL(fileURLWithPath: draft.configurationPath)
        let yamlBytes = try Data(contentsOf: yamlURL)
        let mapping = try ProfileDeviceMapping.suggestions(configurationPath: draft.configurationPath, devices: devices)
        guard let captureSelector = mapping.capture.selector, let playbackSelector = mapping.playback.selector else {
            throw SwitcherError.message("The YAML must define explicit capture and playback device selectors.")
        }
        if case .unsupported(let reason) = mapping.capture.resolution { throw SwitcherError.message(reason) }
        if case .unsupported(let reason) = mapping.playback.resolution { throw SwitcherError.message(reason) }
        let selectors = (capture: captureSelector, playback: playbackSelector,
                         captureChannels: mapping.capture.channels, playbackChannels: mapping.playback.channels)
        guard try Data(contentsOf: yamlURL) == yamlBytes else {
            throw SwitcherError.message("The DSP configuration changed while it was being read. Review the profile again.")
        }
        try Self.validateSelector(selectors.capture, uid: draft.captureUID, devices: devices,
                                  direction: "capture", input: true, channels: selectors.captureChannels)
        try Self.validateSelector(selectors.playback, uid: draft.playbackUID, devices: devices,
                                  direction: "playback", input: false, channels: selectors.playbackChannels)
        let runner = commandRunner ?? { executable, args in
            try await ProcessRunner.run(executable, arguments: args, workingDirectory: yamlURL.deletingLastPathComponent())
        }
        let result = try await runner(draft.executablePath, ["--check", draft.configurationPath])
        guard result.status == 0 else {
            throw SwitcherError.message("CamillaDSP could not validate this configuration. " + String((result.stderr + result.stdout).prefix(2000)))
        }
        guard try Data(contentsOf: yamlURL) == yamlBytes else {
            throw SwitcherError.message("The DSP configuration changed during validation. Review the profile again.")
        }
        try ensureUnchanged(Data(contentsOf: configurationURL))
        if let oldJob, let existing { try Self.verifyExistingJob(oldJob, path: existing.launchAgentPath) }

        let job = keepJob ? nil : try Self.makeJob(draft, configurationURL: configurationURL)
        let profile: Profile
        if let existing {
            profile = Profile(id: existing.id, name: draft.name, triggerUID: draft.triggerUID,
                captureUID: draft.captureUID, managedFeedUID: draft.managedFeedUID, playbackUID: draft.playbackUID,
                launchAgentLabel: job?.label ?? existing.launchAgentLabel,
                launchAgentPath: job?.url.path ?? existing.launchAgentPath,
                websocketURL: "ws://127.0.0.1:\(draft.websocketPort)",
                expectedCaptureDevice: selectors.capture, expectedPlaybackDevice: selectors.playback,
                routeAlerts: draft.routeAlerts, autoActivate: draft.autoActivate,
                startupDelayMilliseconds: existing.startupDelayMilliseconds, gui: existing.gui,
                requiresExclusiveDSP: existing.requiresExclusiveDSP)
        } else {
            guard oldJob == nil else { throw SwitcherError.message("Cannot create a profile with an existing ID.") }
            profile = Profile(id: draft.id, name: draft.name, triggerUID: draft.triggerUID,
                captureUID: draft.captureUID, managedFeedUID: draft.managedFeedUID, playbackUID: draft.playbackUID,
                launchAgentLabel: job!.label, launchAgentPath: job!.url.path,
                websocketURL: "ws://127.0.0.1:\(draft.websocketPort)",
                expectedCaptureDevice: selectors.capture, expectedPlaybackDevice: selectors.playback,
                routeAlerts: draft.routeAlerts, autoActivate: draft.autoActivate, requiresExclusiveDSP: true)
        }
        var updated = original
        if let existingIndex { updated.profiles[existingIndex] = profile }
        else { updated.profiles.append(profile) }
        for index in updated.profiles.indices where replacementIDs.contains(updated.profiles[index].id) {
            updated.profiles[index].autoActivate = false
        }
        // Version 2 is required to make explicit nil feed roles unambiguous to newer readers.
        // Old readers ignore unknown fields, so a v1 document must never carry managedFeedUID: null.
        updated.version = 2
        try ConfigurationLoader.validate(updated)

        let output = try Self.replacingProfile(in: originalBytes, with: profile, id: draft.id,
                                               disablingAutoActivationIDs: replacementIDs)
        var created: [(URL, Data)] = []
        do {
            if let job {
                guard !FileManager.default.fileExists(atPath: job.stateURL.path) else {
                    throw SwitcherError.message("An existing DSP state file occupies the reserved profile state path.")
                }
                try Self.publishNew(job.data, at: job.url); created.append((job.url, job.data))
            }
            try ensureUnchanged(Data(contentsOf: configurationURL))
            if let oldJob, let existing { try Self.verifyExistingJob(oldJob, path: existing.launchAgentPath) }
            try output.write(to: configurationURL, options: .atomic)
        } catch {
            for (url, bytes) in created.reversed() where (try? Data(contentsOf: url)) == bytes { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        baseline = try Data(contentsOf: configurationURL)
        return updated
    }

    @discardableResult public func remove(id: String) throws -> Configuration {
        guard !mutationInProgress else { throw SwitcherError.message("Wait for the profile save to finish before removing a profile.") }
        let (bytes, original) = try readConfiguration()
        baseline = baseline ?? bytes
        try ensureUnchanged(bytes)
        guard original.profiles.count > 1 else { throw SwitcherError.message("At least one interface profile must remain.") }
        guard original.profiles.contains(where: { $0.id == id }) else { return original }
        var updated = original; updated.profiles.removeAll(where: { $0.id == id })
        try ConfigurationLoader.validate(updated)
        guard var root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              var profiles = root["profiles"] as? [[String: Any]] else { throw SwitcherError.message("The configuration has an unsupported structure.") }
        profiles.removeAll { $0["id"] as? String == id }; root["profiles"] = profiles
        try ensureUnchanged(Data(contentsOf: configurationURL))
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: configurationURL, options: .atomic)
        baseline = try Data(contentsOf: configurationURL)
        return updated
    }

    private func readConfiguration() throws -> (Data, Configuration) {
        let bytes = try Data(contentsOf: configurationURL)
        var value = try JSONDecoder().decode(Configuration.self, from: bytes)
        for index in value.profiles.indices {
            value.profiles[index].launchAgentPath = (value.profiles[index].launchAgentPath as NSString).expandingTildeInPath
        }
        try ConfigurationLoader.validate(value)
        return (bytes, value)
    }
    private func ensureUnchanged(_ data: Data) throws {
        if let baseline, baseline != data {
            throw SwitcherError.message("The configuration changed outside this editor. Quit and reopen Interfaces settings to review the latest version.")
        }
    }

    private struct NewJob { let label: String; let url: URL; let stateURL: URL; let data: Data }

    private static func readJob(path: String, configuredLabel: String) throws -> DSPJobConfigurationDetails {
        try DSPJobConfiguration.read(path: path, configuredLabel: configuredLabel)
    }

    private static func verifyExistingJob(_ details: DSPJobConfigurationDetails, path: String) throws {
        let jobURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard try Data(contentsOf: jobURL) == details.jobBytes else {
            throw SwitcherError.message("The existing DSP job changed during validation. Review the profile again.")
        }
        try details.verifyStateConfigurationReference()
    }

    private static func validateDraft(_ draft: InterfaceProfileDraft, devices: [AudioDevice]) throws {
        let text = [draft.id, draft.name, draft.executablePath, draft.configurationPath,
                    draft.triggerUID, draft.captureUID, draft.playbackUID]
        guard text.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("\0") }),
              draft.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              draft.executablePath.hasPrefix("/"), draft.configurationPath.hasPrefix("/"),
              URL(fileURLWithPath: draft.executablePath).lastPathComponent == "camilladsp",
              FileManager.default.isExecutableFile(atPath: draft.executablePath),
              (1...65535).contains(draft.websocketPort) else {
            throw SwitcherError.message("Choose a name, installed camilladsp executable, valid port, and DSP input and output devices.")
        }
        guard (try URL(fileURLWithPath: draft.configurationPath).resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw SwitcherError.message("Choose an existing CamillaDSP YAML configuration.")
        }
        guard [draft.triggerUID, draft.captureUID, draft.playbackUID].allSatisfy({ uid in devices.filter { $0.uid == uid }.count <= 1 }),
              draft.managedFeedUID.map({ feed in devices.filter { $0.uid == feed }.count <= 1 }) ?? true else {
            throw SwitcherError.message("A selected audio device is ambiguous.")
        }
        try Self.validateCapability(uid: draft.captureUID, devices: devices, input: true, role: "DSP input")
        try Self.validateCapability(uid: draft.playbackUID, devices: devices, input: false, role: "DSP output")
        if let feed = draft.managedFeedUID {
            guard feed == draft.captureUID, feed != draft.playbackUID, feed != draft.triggerUID else {
                throw SwitcherError.message("Automatic routing requires the DSP input itself as the system feed, separate from the DSP output and connection trigger.")
            }
            try Self.validateCapability(uid: feed, devices: devices, input: false, role: "managed system feed")
        }
    }

    private static func validateCapability(uid: String, devices: [AudioDevice], input: Bool, role: String) throws {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        guard input ? device.hasInput : device.hasOutput else {
            throw SwitcherError.message("The selected \(role) device has no \(input ? "input" : "output") channels.")
        }
    }

    private static func validateSelector(_ selector: String, uid: String, devices: [AudioDevice], direction: String,
                                         input: Bool, channels: Int?) throws {
        guard !selector.isEmpty, !selector.contains("\0") else { throw SwitcherError.message("The YAML has no explicit \(direction) device selector.") }
        if let device = devices.first(where: { $0.uid == uid }) {
            let capable = input ? device.hasInput : device.hasOutput
            guard capable, channels.map({ (input ? device.inputChannels : device.outputChannels) >= $0 }) ?? true,
                  selector == uid || selector == device.name,
                  devices.filter({ $0.name == selector }).count < 2 || selector == uid else {
                throw SwitcherError.message("The selected \(direction) interface does not exactly match the YAML selector \(selector).")
            }
        }
    }

    private static func makeJob(_ draft: InterfaceProfileDraft, configurationURL: URL) throws -> NewJob {
        let root = configurationURL.deletingLastPathComponent().appendingPathComponent("DSPJobs", isDirectory: true)
        let revision = UUID().uuidString.lowercased()
        let label = "com.camillacompanion.dsp.\(draft.id).\(revision)"
        let url = root.appendingPathComponent(label + ".plist")
        let state = root.appendingPathComponent("\(draft.id)-\(revision)-state.yml")
        let job: [String: Any] = ["Label": label,
            "ProgramArguments": [draft.executablePath, "-s", state.path, "-a", "127.0.0.1", "-p", String(draft.websocketPort), draft.configurationPath],
            "WorkingDirectory": URL(fileURLWithPath: draft.configurationPath).deletingLastPathComponent().path,
            "RunAtLoad": false, "KeepAlive": false, "ProcessType": "Interactive",
            "StandardOutPath": configurationURL.deletingLastPathComponent().appendingPathComponent("camilladsp-\(draft.id).stdout.log").path,
            "StandardErrorPath": configurationURL.deletingLastPathComponent().appendingPathComponent("camilladsp-\(draft.id).stderr.log").path]
        return NewJob(label: label, url: url, stateURL: state,
                      data: try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0))
    }

    private static func replacingProfile(in data: Data, with profile: Profile, id: String,
                                         disablingAutoActivationIDs: Set<String> = []) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var profiles = root["profiles"] as? [[String: Any]] else { throw SwitcherError.message("The configuration has an unsupported structure.") }
        let encoder = JSONEncoder(); let encoded = try JSONSerialization.jsonObject(with: encoder.encode(profile)) as! [String: Any]
        if let index = profiles.firstIndex(where: { $0["id"] as? String == id }) {
            var merged = profiles[index]
            for (key, value) in encoded { merged[key] = value }
            if let storedPath = profiles[index]["launchAgentPath"] as? String,
               (storedPath as NSString).expandingTildeInPath == profile.launchAgentPath {
                merged["launchAgentPath"] = storedPath
            }
            profiles[index] = merged
        } else { profiles.append(encoded) }
        for index in profiles.indices where disablingAutoActivationIDs.contains(profiles[index]["id"] as? String ?? "") {
            profiles[index]["autoActivate"] = false
        }
        root["profiles"] = profiles
        root["version"] = 2
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func publishNew(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".interface-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        guard link(temp.path, url.path) == 0 else { throw SwitcherError.message("Cannot create DSP job without replacing existing data.") }
    }
}
