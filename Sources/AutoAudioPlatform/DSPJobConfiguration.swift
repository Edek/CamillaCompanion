import Foundation
import AutoAudioCore
import Yams

/// Read-only metadata recovered from one configured CamillaDSP LaunchAgent.
/// Startup policy and logging options are retained in the source job, not normalized here.
public struct DSPJobConfigurationDetails: Sendable {
    public let label: String
    public let executablePath: String
    public let configurationPath: String
    public let port: Int
    public let jobBytes: Data
    public let stateFilePath: String?
    public let stateFileBytes: Data?
    private let stateFileExisted: Bool
    private let stateConfigurationPath: String?
    private let workingDirectoryPath: String?

    fileprivate init(label: String, executablePath: String, configurationPath: String, port: Int,
                     jobBytes: Data, stateFilePath: String?, stateFileBytes: Data?, stateConfigurationPath: String?,
                     stateFileExisted: Bool, workingDirectoryPath: String?) {
        self.label = label; self.executablePath = executablePath; self.configurationPath = configurationPath
        self.port = port; self.jobBytes = jobBytes; self.stateFilePath = stateFilePath
        self.stateFileBytes = stateFileBytes; self.stateFileExisted = stateFileExisted
        self.stateConfigurationPath = stateConfigurationPath
        self.workingDirectoryPath = workingDirectoryPath
    }

    /// State volume and mute values change during normal DSP use. Guard only the
    /// config_path identity, which determines which YAML the configured job runs.
    public func verifyStateConfigurationReference() throws {
        guard let stateFilePath, let stateConfigurationPath else { return }
        let stateURL = URL(fileURLWithPath: stateFilePath)
        guard FileManager.default.fileExists(atPath: stateFilePath) else {
            guard !stateFileExisted else {
                throw SwitcherError.message("The configured DSP state file disappeared during validation. Review the profile again.")
            }
            return
        }
        let latestBytes = try DSPJobConfiguration.readBounded(stateURL, limit: 4 * 1024 * 1024,
            error: "The configured DSP state file cannot be read safely.")
        let latestPath = try DSPJobConfiguration.configurationPath(inState: latestBytes,
            workingDirectory: workingDirectoryPath.map { URL(fileURLWithPath: $0) })
        guard latestPath == stateConfigurationPath else {
            throw SwitcherError.message("The configured DSP state file changed its YAML reference during validation. Review the profile again.")
        }
    }
}

/// Parses only a known direct CamillaDSP job and the referenced YAML path.
public enum DSPJobConfiguration {
    private static let maximumJobBytes = 1024 * 1024
    private static let maximumStateBytes = 4 * 1024 * 1024

    public static func read(path: String, configuredLabel: String) throws -> DSPJobConfigurationDetails {
        guard path.hasPrefix("/"), !path.contains("\0"),
              configuredLabel.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw SwitcherError.message("The configured DSP job path or service label is invalid.")
        }
        let jobURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let jobBytes = try readBounded(jobURL, limit: maximumJobBytes, error: "The configured DSP job is too large to inspect safely.")
        guard let plist = try PropertyListSerialization.propertyList(from: jobBytes, format: nil) as? [String: Any],
              plist["BundleProgram"] == nil,
              let label = plist["Label"] as? String, label == configuredLabel,
              let arguments = plist["ProgramArguments"] as? [String], let executable = arguments.first,
              executable.hasPrefix("/"), URL(fileURLWithPath: executable).lastPathComponent == "camilladsp",
              plist["Program"] == nil || plist["Program"] as? String == executable else {
            throw SwitcherError.message("The configured DSP job is unsupported or does not match its profile. It must directly run CamillaDSP under the configured service label.")
        }

        let workingDirectory: URL?
        if let rawWorking = plist["WorkingDirectory"] {
            guard let working = rawWorking as? String else {
                throw SwitcherError.message("The configured DSP job has an invalid WorkingDirectory. Review the job before editing this profile.")
            }
            guard working.hasPrefix("/"), !working.contains("\0") else {
                throw SwitcherError.message("The configured DSP job has a relative WorkingDirectory. Review the job and use an absolute directory path.")
            }
            workingDirectory = URL(fileURLWithPath: working).standardizedFileURL
        } else { workingDirectory = nil }

        let parsed = try parse(arguments: Array(arguments.dropFirst()))
        guard let port = parsed.port, (1...65535).contains(port),
              let address = parsed.address, ["127.0.0.1", "localhost", "::1"].contains(address) else {
            throw SwitcherError.message("The configured DSP job must use an explicit loopback address and WebSocket port.")
        }

        let positionalPath: String? = try parsed.configurationPath.map {
            try resolve($0, relativeTo: workingDirectory, role: "YAML path").path
        }

        var stateBytes: Data?
        var stateURL: URL?
        var stateConfig: String?
        if let stateArgument = parsed.statePath {
            let resolved = try resolve(stateArgument, relativeTo: workingDirectory, role: "state file path")
            stateURL = resolved
            if FileManager.default.fileExists(atPath: resolved.path) {
                let bytes = try readBounded(resolved, limit: maximumStateBytes,
                    error: "The configured DSP state file is too large to inspect safely.")
                stateBytes = bytes
                if positionalPath == nil {
                    stateConfig = try configurationPath(inState: bytes, workingDirectory: workingDirectory)
                }
            } else if positionalPath == nil {
                throw SwitcherError.message("The configured DSP state file is missing and the job has no explicit YAML path.")
            }
        }

        // CamillaDSP documents that CONFIGFILE overrides config_path from the
        // state file. The state path remains relevant for mutable fader values,
        // but cannot change startup YAML when CONFIGFILE is present.
        guard let yamlPath = positionalPath ?? stateConfig,
              isRegularFile(URL(fileURLWithPath: yamlPath)) else {
            throw SwitcherError.message("The configured DSP job does not reference an existing YAML configuration.")
        }
        guard try Data(contentsOf: jobURL) == jobBytes else {
            throw SwitcherError.message("The configured DSP job changed while it was being read. Reopen Interfaces settings.")
        }

        let details = DSPJobConfigurationDetails(label: label, executablePath: executable, configurationPath: yamlPath,
            port: port, jobBytes: jobBytes, stateFilePath: stateURL?.path,
            stateFileBytes: stateBytes, stateConfigurationPath: positionalPath == nil ? stateConfig : nil,
            stateFileExisted: stateBytes != nil,
            workingDirectoryPath: workingDirectory?.path)
        try details.verifyStateConfigurationReference()
        return details
    }

    fileprivate static func configurationPath(inState bytes: Data, workingDirectory: URL?) throws -> String {
        guard let text = String(data: bytes, encoding: .utf8),
              let state = try Yams.load(yaml: text) as? [String: Any],
              let path = state["config_path"] as? String, !path.isEmpty, !path.contains("\0") else {
            throw SwitcherError.message("The configured DSP state file has no valid config_path.")
        }
        let resolved = try resolve(path, relativeTo: workingDirectory, role: "state file config_path")
        guard isRegularFile(resolved) else {
            throw SwitcherError.message("The YAML referenced by the configured DSP state file is missing.")
        }
        return resolved.path
    }

    fileprivate static func readBounded(_ url: URL, limit: Int, error: String) throws -> Data {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard isRegularFile(url), let size = attributes?[.size] as? NSNumber,
              size.intValue >= 0, size.intValue <= limit else { throw SwitcherError.message(error) }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw SwitcherError.message(error) }
        return data
    }

    private struct ParsedArguments {
        var statePath: String?
        var configurationPath: String?
        var port: Int?
        var address: String?
    }

    private static func parse(arguments: [String]) throws -> ParsedArguments {
        var parsed = ParsedArguments()
        var seen = Set<String>()
        var positionals = 0
        var index = 0
        while index < arguments.count {
            let raw = arguments[index]
            var flag = raw
            var inlineValue: String?
            if raw.hasPrefix("--"), let equal = raw.firstIndex(of: "=") {
                flag = String(raw[..<equal]); inlineValue = String(raw[raw.index(after: equal)...])
            } else if raw.count > 2, ["-s", "-p", "-a", "-o"].contains(String(raw.prefix(2))) {
                flag = String(raw.prefix(2)); inlineValue = String(raw.dropFirst(2))
            }

            let key: String?
            switch flag {
            case "-s", "--statefile", "--state-file": key = "state"
            case "-p", "--port": key = "port"
            case "-a", "--address": key = "address"
            case "-o", "--logfile", "--log-file", "--log_rotate_size", "--log_keep_nbr": key = "log"
            default: key = nil
            }
            if let key {
                guard key == "log" || seen.insert(key).inserted else {
                    throw SwitcherError.message("The configured DSP job repeats its \(key) argument.")
                }
                var value = inlineValue
                if value == nil {
                    index += 1
                    guard index < arguments.count else { throw SwitcherError.message("The configured DSP job has an incomplete \(flag) argument.") }
                    value = arguments[index]
                }
                guard let value, !value.isEmpty, !value.contains("\0") else {
                    throw SwitcherError.message("The configured DSP job has an invalid \(flag) argument.")
                }
                switch key {
                case "state": parsed.statePath = value
                case "port": parsed.port = Int(value)
                case "address": parsed.address = value
                default:
                    if ["--log_rotate_size", "--log_keep_nbr"].contains(flag), Int(value).map({ $0 >= 0 }) != true {
                        throw SwitcherError.message("The configured DSP job has an invalid logging rotation argument.")
                    }
                }
            } else if raw.hasPrefix("-") {
                throw SwitcherError.message("The configured DSP job contains an unsupported argument: \(raw)")
            } else {
                positionals += 1
                guard positionals == 1 else { throw SwitcherError.message("The configured DSP job has multiple YAML arguments.") }
                parsed.configurationPath = raw
            }
            index += 1
        }
        return parsed
    }

    private static func resolve(_ path: String, relativeTo base: URL?, role: String = "file path") throws -> URL {
        guard !path.isEmpty, !path.contains("\0") else { throw SwitcherError.message("The configured DSP job contains an invalid file path.") }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let base else {
            throw SwitcherError.message("The configured DSP job uses a relative \(role) without an absolute WorkingDirectory. Review the exact path before editing this profile.")
        }
        return base.appendingPathComponent(path).standardizedFileURL
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

}
