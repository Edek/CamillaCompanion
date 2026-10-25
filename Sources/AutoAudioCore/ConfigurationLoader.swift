import Foundation

public enum ConfigurationLoader {
    public static func load(from url: URL) throws -> Configuration {
        var configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        for index in configuration.profiles.indices {
            configuration.profiles[index].launchAgentPath =
                (configuration.profiles[index].launchAgentPath as NSString).expandingTildeInPath
        }
        for index in configuration.profiles.indices {
            if var gui = configuration.profiles[index].gui {
                gui.executablePath = (gui.executablePath as NSString).expandingTildeInPath
                gui.configPath = (gui.configPath as NSString).expandingTildeInPath
                configuration.profiles[index].gui = gui
            }
        }
        try validate(configuration)
        return configuration
    }

    public static func validate(_ configuration: Configuration) throws {
        guard configuration.version == 1 || configuration.version == 2 else {
            throw invalid("Unsupported configuration version: \(configuration.version)")
        }
        guard !configuration.profiles.isEmpty else { throw invalid("Add at least one profile.") }
        if let feedback = configuration.feedback {
            guard feedback.durationSeconds.isFinite, (0.5...10).contains(feedback.durationSeconds) else {
                throw invalid("Feedback durationSeconds must be between 0.5 and 10.")
            }
            guard feedback.errorDurationSeconds.isFinite, (0.5...10).contains(feedback.errorDurationSeconds) else {
                throw invalid("Feedback errorDurationSeconds must be between 0.5 and 10.")
            }
        }
        var ids = Set<String>()
        var labels = Set<String>()
        var guiPorts = Set<Int>()
        var guiLabels = Set<String>()
        for profile in configuration.profiles {
            let required = [profile.id, profile.name, profile.triggerUID, profile.captureUID,
                            profile.playbackUID, profile.launchAgentLabel, profile.launchAgentPath,
                            profile.expectedCaptureDevice, profile.expectedPlaybackDevice]
            guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw invalid("Profile fields must not be empty (profile: \(profile.id)).")
            }
            guard ids.insert(profile.id).inserted else { throw invalid("Duplicate profile ID: \(profile.id)") }
            if configuration.version == 1, profile.managedFeedUID == nil {
                throw invalid("Companion-only device roles require configuration version 2. Restore the saved version 1 configuration before using an older app.")
            }
            guard labels.insert(profile.launchAgentLabel).inserted else {
                throw invalid("Each profile must have its own LaunchAgent label: \(profile.launchAgentLabel)")
            }
            if let gui = profile.gui {
                guard profile.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
                      gui.executablePath.hasPrefix("/"), gui.configPath.hasPrefix("/"),
                      let endpoint = URLComponents(string: gui.url), endpoint.scheme == "http",
                      ["127.0.0.1", "localhost", "::1", "[::1]"].contains(endpoint.host ?? ""),
                      let port = endpoint.port, (1...65535).contains(port),
                      endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil, endpoint.query == nil else {
                    throw invalid("GUI requires a safe profile ID, absolute paths, and loopback http:// URL with explicit port.")
                }
                guard guiPorts.insert(port).inserted,
                      guiLabels.insert("org.camillacompanion.gui." + profile.id).inserted else {
                    throw invalid("Profiles must have distinct GUI endpoints and service identities.")
                }
            }
            if let feedUID = profile.managedFeedUID {
                guard feedUID == profile.captureUID else {
                    throw invalid("Profile \(profile.id) managed feed must match its CamillaDSP capture device.")
                }
                guard feedUID != profile.playbackUID, feedUID != profile.triggerUID else {
                    throw invalid("Profile \(profile.id) managed feed must differ from its DSP output and connection trigger.")
                }
            }
            let labelCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            guard profile.launchAgentLabel.unicodeScalars.allSatisfy({ labelCharacters.contains($0) }) else {
                throw invalid("Invalid LaunchAgent label: \(profile.launchAgentLabel)")
            }
            guard profile.launchAgentPath.hasPrefix("/"), profile.launchAgentPath.hasSuffix(".plist") else {
                throw invalid("LaunchAgent path must be an absolute .plist path (or use ~/ when loading a file).")
            }
            guard (0...10_000).contains(profile.startupDelayMilliseconds) else {
                throw invalid("Startup delay must be between 0 and 10000 milliseconds.")
            }
            guard let url = URLComponents(string: profile.websocketURL), url.scheme == "ws",
                  let host = url.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
                  let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
                throw invalid("WebSocket URL must be a local ws:// address with an explicit port.")
            }
        }
        guard labels.isDisjoint(with: guiLabels), !guiLabels.contains("org.camillacompanion.login") else {
            throw invalid("GUI job identity conflicts with a DSP or controller job.")
        }
    }

    private static func invalid(_ text: String) -> SwitcherError { .message(text) }
}
