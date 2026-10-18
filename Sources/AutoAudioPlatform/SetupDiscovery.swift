// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import AutoAudioCore
import Yams

public struct SetupDSPCandidate: Sendable, Equatable {
    public let executablePath: String
    public let configurationPath: String?
    public let launchAgentPath: String?
    public let websocketPort: Int?
    public init(executablePath: String, configurationPath: String? = nil, launchAgentPath: String? = nil,
                websocketPort: Int? = nil) {
        self.executablePath = executablePath; self.configurationPath = configurationPath
        self.launchAgentPath = launchAgentPath; self.websocketPort = websocketPort
    }
}

public struct SetupGUICandidate: Sendable, Equatable {
    public let executablePath: String
    public let configurationPath: String?
    public let url: String?
    public init(executablePath: String, configurationPath: String? = nil, url: String? = nil) {
        self.executablePath = executablePath; self.configurationPath = configurationPath; self.url = url
    }
}

public struct SetupDiscoveryResult: Sendable, Equatable {
    public let dsp: [SetupDSPCandidate]
    public let gui: [SetupGUICandidate]
    public let summary: String
    public let searchTruncated: Bool
    public init(dsp: [SetupDSPCandidate] = [], gui: [SetupGUICandidate] = [], summary: String = "",
                searchTruncated: Bool = false) {
        self.dsp = dsp; self.gui = gui; self.summary = summary; self.searchTruncated = searchTruncated
    }
}

public struct SetupDiscoveryLimits: Sendable {
    public let maxDepth: Int
    public let maxEntries: Int
    public let maxConfigReads: Int
    public let maxConfigBytes: Int
    public init(maxDepth: Int = 4, maxEntries: Int = 2048, maxConfigReads: Int = 96, maxConfigBytes: Int = 262144) {
        self.maxDepth = min(6, max(0, maxDepth)); self.maxEntries = min(8192, max(1, maxEntries))
        self.maxConfigReads = min(128, max(1, maxConfigReads)); self.maxConfigBytes = min(1048576, max(1, maxConfigBytes))
    }
}

/// A synchronous, one-shot filesystem search, suitable for a detached task.
/// It never executes discovered files or reads launchd, devices or network state.
public enum SetupDiscovery {
    public static func find(homeDirectory: URL,
                            installationRoots: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")],
                            limits: SetupDiscoveryLimits = .init()) -> SetupDiscoveryResult {
        Search(home: homeDirectory, roots: installationRoots, limits: limits).run()
    }
}

private final class Search {
    private let home: URL
    private let roots: [URL]
    private let limits: SetupDiscoveryLimits
    private let fm = FileManager.default
    private var entries = Set<String>()
    private var readCount = 0
    private var bytes: [String: Data] = [:]
    private var unreadable = Set<String>()
    private var metadata: [String: [FileAttributeKey: Any]] = [:]
    private var documents: [String: Node] = [:]
    private var canonicalPaths: [String: String] = [:]
    private var walked = Set<String>()
    private var truncated = false
    private var dsp: [SetupDSPCandidate] = []
    private var gui: [SetupGUICandidate] = []
    private let guiNames = ["camillagui", "camillagui_backend", "camillagui-backend", "camillagui.py", "camillagui_backend.py", "camillagui-backend.py"]
    private let excludedDirectories: Set<String> = ["backups", "loginitembackups", "caches", "cache", "logs", "node_modules", "__pycache__", "venv", ".venv", ".git", "build", "dist", "vendor", "dependencies", "deriveddata", "carthage", "pods", "site-packages"]

    init(home: URL, roots: [URL], limits: SetupDiscoveryLimits) {
        self.home = home.standardizedFileURL; self.roots = roots; self.limits = limits
    }

    private var cancelled: Bool {
        if Task.isCancelled { truncated = true; return true }
        return false
    }

    func run() -> SetupDiscoveryResult {
        let support = home.appendingPathComponent("Library/Application Support")
        seedAppConfiguration(ApplicationSupportPaths.select(homeDirectory: home).configurationURL)
        for root in roots.sorted(by: { $0.path < $1.path }) where !cancelled {
            let bin = root.lastPathComponent == "bin" ? root : root.appendingPathComponent("bin")
            for name in ["camilladsp"] + guiNames where !cancelled { executableCandidate(bin.appendingPathComponent(name)) }
        }
        for file in children(home.appendingPathComponent("Library/LaunchAgents")) where !cancelled {
            if file.pathExtension == "plist" { inspectJob(file) }
        }
        // Probe known layouts before unrelated applications can consume the
        // bounded broad-search budget, even in a very large support directory.
        for name in ["Bedroom EQ", "CamillaDSP", "camilladsp", "CamillaGUI", "camillagui", "CamillaCompanion"] where !cancelled {
            walk(support.appendingPathComponent(name), depth: 1)
        }
        walk(support, depth: 0)
        let normalizedDSP = normalizeDSP()
        let normalizedGUI = normalizeGUI()
        let count = normalizedDSP.isEmpty && normalizedGUI.isEmpty ? "No installations found. Choose their locations manually." :
            "Found \(normalizedDSP.count) DSP and \(normalizedGUI.count) GUI candidates."
        return .init(dsp: normalizedDSP, gui: normalizedGUI,
            summary: count + (truncated ? " Search was limited; Choose remains available." : " Review a selection before using it."),
            searchTruncated: truncated)
    }

    private func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        if cancelled { return nil }
        let key = url.standardizedFileURL.path
        if let cached = metadata[key] { return cached }
        if !entries.contains(key) {
            guard entries.count < limits.maxEntries else { truncated = true; return nil }
            entries.insert(key)
        }
        guard let result = try? fm.attributesOfItem(atPath: key) else { return nil }
        metadata[key] = result
        return result
    }

    /// readdir stops at the entry budget rather than materializing an unbounded
    /// directory listing. Symlink directories are never entered.
    private func children(_ url: URL) -> [URL] {
        guard !cancelled, attributes(url)?[.type] as? FileAttributeType == .typeDirectory,
              let directory = opendir(url.path) else { return [] }
        defer { closedir(directory) }
        var result: [URL] = []
        while !cancelled, let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard entries.count < limits.maxEntries else { truncated = true; break }
            let child = url.appendingPathComponent(name)
            _ = attributes(child)
            result.append(child)
        }
        return result.sorted {
            func priority(_ item: URL) -> Int {
                let name = item.lastPathComponent.lowercased()
                return name.contains("camilla") || name == "bedroom eq" ? 0 : 1
            }
            return priority($0) == priority($1) ? $0.path < $1.path : priority($0) < priority($1)
        }
    }

    private func walk(_ directory: URL, depth: Int) {
        guard !cancelled, walked.insert(directory.standardizedFileURL.path).inserted else { return }
        for file in children(directory) where !cancelled {
            guard !file.lastPathComponent.hasPrefix(".") else { continue }
            let type = attributes(file)?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if excludedDirectories.contains(file.lastPathComponent.lowercased()) { continue }
                if depth + 1 < limits.maxDepth { walk(file, depth: depth + 1) }
                else { truncated = true }
            } else {
                executableCandidate(file)
                if ["yml", "yaml", "json"].contains(file.pathExtension.lowercased()), type == .typeRegular { inspectAdjacentDSP(file) }
                if file.pathExtension == "plist", type == .typeRegular { inspectJob(file) }
            }
        }
    }

    private func inspectAdjacentDSP(_ file: URL) {
        let parent = file.deletingLastPathComponent()
        guard let executable = trustedExecutable(parent.appendingPathComponent("camilladsp"), kind: .dsp) else { return }
        if let config = dspConfiguration(file) { dsp.append(.init(executablePath: executable.path, configurationPath: config.path)) }
        if let state = document(file), let path = state["config_path"]?.string,
           let config = resolve(path, relativeTo: parent).flatMap(dspConfiguration) {
            dsp.append(.init(executablePath: executable.path, configurationPath: config.path))
        }
    }

    private enum ExecutableKind { case dsp, gui }
    private func trustedExecutable(_ url: URL, kind: ExecutableKind) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              kind == .dsp ? url.lastPathComponent == "camilladsp" : guiNames.contains(url.lastPathComponent) else { return nil }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard let info = attributes(canonical), info[.type] as? FileAttributeType == .typeRegular,
              let owner = info[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() || owner.uint32Value == 0,
              let mode = info[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0,
              fm.isExecutableFile(atPath: canonical.path) else { return nil }
        // Keep the named entry point for Setup's executable-name validation.
        return url.standardizedFileURL
    }

    private func executableCandidate(_ url: URL) {
        if url.lastPathComponent == "camilladsp", let executable = trustedExecutable(url, kind: .dsp) {
            dsp.append(.init(executablePath: executable.path))
        } else if guiNames.contains(url.lastPathComponent), let executable = trustedExecutable(url, kind: .gui) {
            gui.append(.init(executablePath: executable.path))
            let parent = executable.deletingLastPathComponent()
            for relative in ["_internal/config/camillagui.yml", "_internal/config/camillagui.yaml", "config/camillagui.yml", "config/camillagui.yaml", "camillagui.yml", "camillagui.yaml"] where !cancelled {
                if let candidate = guiCandidate(executable: executable, config: parent.appendingPathComponent(relative)) { gui.append(candidate) }
            }
        }
    }

    private func read(_ url: URL) -> Data? {
        let key = url.standardizedFileURL.path
        if let cached = bytes[key] { return cached }
        guard !cancelled, !unreadable.contains(key) else { return nil }
        unreadable.insert(key)
        guard attributes(url)?[.type] as? FileAttributeType == .typeRegular else { return nil }
        guard readCount < limits.maxConfigReads else { truncated = true; return nil }
        readCount += 1
        let fd = Darwin.open(key, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        guard info.st_size <= limits.maxConfigBytes else { truncated = true; return nil }
        var buffer = [UInt8](repeating: 0, count: limits.maxConfigBytes + 1)
        var count = 0
        while count < buffer.count, !cancelled {
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if amount == 0 { break }
            guard amount > 0 else { return nil }
            count += amount
        }
        guard !cancelled, count <= limits.maxConfigBytes else { truncated = true; return nil }
        let data = Data(buffer.prefix(count)); bytes[key] = data
        return data
    }

    private func document(_ url: URL) -> Node? {
        let key = url.standardizedFileURL.path
        if let cached = documents[key] { return cached }
        guard let data = read(url), let text = String(data: data, encoding: .utf8), !cancelled else { return nil }
        // Inspect only required scalar nodes, avoiding whole-document conversion
        // or alias expansion into arbitrary Swift object graphs.
        guard let node = try? Yams.compose(yaml: text) else { return nil }
        documents[key] = node
        return node
    }

    private func resolve(_ path: String, relativeTo base: URL? = nil) -> URL? {
        guard !path.isEmpty, !path.utf8.contains(0) else { return nil }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return base?.appendingPathComponent(path).standardizedFileURL
    }

    private func dspConfiguration(_ url: URL) -> URL? {
        guard let config = document(url),
              config["devices"]?["capture"]?["type"]?.string == "CoreAudio",
              config["devices"]?["playback"]?["type"]?.string == "CoreAudio",
              let capture = config["devices"]?["capture"]?["device"]?.string, !capture.isEmpty,
              let playback = config["devices"]?["playback"]?["device"]?.string, !playback.isEmpty else { return nil }
        return url.standardizedFileURL
    }

    private func guiCandidate(executable: URL, config: URL) -> SetupGUICandidate? {
        guard let node = document(config), let backend = try? GUIBackendConfiguration(node: node),
              backend.hasBackendFields else { return nil }
        return .init(executablePath: executable.path, configurationPath: config.standardizedFileURL.path, url: backend.loopbackURL)
    }

    private func inspectJob(_ url: URL) {
        guard let data = read(url), let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              job["BundleProgram"] == nil, let args = job["ProgramArguments"] as? [String], let first = args.first,
              let executableURL = resolve(first), job["Program"] == nil || job["Program"] as? String == first else { return }
        let working = (job["WorkingDirectory"] as? String).flatMap { resolve($0) }
        if let executable = trustedExecutable(executableURL, kind: .gui) {
            guard args.count == 3, args[1] == "-c", let config = resolve(args[2], relativeTo: working) else { executableCandidate(executable); return }
            if let candidate = guiCandidate(executable: executable, config: config) { gui.append(candidate) }
            else { executableCandidate(executable) }
            return
        }
        guard let executable = trustedExecutable(executableURL, kind: .dsp) else { return }
        var config: URL?; var state: URL?; var port: Int?; var address: String?
        var valid = true; var unknown = false; var index = 1; var seenFlags = Set<String>(); var positionals = 0
        while index < args.count, !cancelled {
            let argument = args[index]
            var flag = argument; var value: String?
            if let separator = argument.firstIndex(of: "="), argument.hasPrefix("--") {
                flag = String(argument[..<separator]); value = String(argument[argument.index(after: separator)...])
            } else if argument.hasPrefix("-p"), argument.count > 2 { flag = "-p"; value = String(argument.dropFirst(2)) }
            else if argument.hasPrefix("-a"), argument.count > 2 { flag = "-a"; value = String(argument.dropFirst(2)) }
            else if argument.hasPrefix("-s"), argument.count > 2 { flag = "-s"; value = String(argument.dropFirst(2)) }
            if ["-s", "--statefile", "--state-file", "-p", "--port", "-a", "--address"].contains(flag) {
                let key = ["-s", "--statefile", "--state-file"].contains(flag) ? "state" : (["-p", "--port"].contains(flag) ? "port" : "address")
                if !seenFlags.insert(key).inserted { valid = false }
                if value == nil { index += 1; if index < args.count { value = args[index] } }
                guard let value, !value.isEmpty else { valid = false; break }
                switch flag {
                case "-s", "--statefile", "--state-file": if state != nil { valid = false }; state = resolve(value, relativeTo: working)
                case "-p", "--port": if port != nil { valid = false }; port = Int(value); if port == nil { valid = false }
                default: if address != nil { valid = false }; address = value
                }
            } else if ["-o", "--logfile", "--log-file", "--log_rotate_size", "--log_keep_nbr"].contains(flag) {
                if value == nil { index += 1; if index < args.count { value = args[index] } }
                guard let value, !value.isEmpty, !value.hasPrefix("-") else { valid = false; break }
                if ["--log_rotate_size", "--log_keep_nbr"].contains(flag), Int(value).map({ $0 >= 0 }) != true { valid = false }
            } else if argument.hasPrefix("-") { unknown = true }
            else {
                positionals += 1
                if positionals == 1 { config = resolve(argument, relativeTo: working) }
                else { valid = false }
            }
            index += 1
        }
        guard valid else { dsp.append(.init(executablePath: executable.path)); return }
        var selected: URL?
        if let state, let saved = document(state)?["config_path"]?.string,
           let reference = resolve(saved, relativeTo: working), let current = dspConfiguration(reference) { selected = current }
        if selected == nil, !unknown, let config { selected = dspConfiguration(config) }
        let validPort = port.flatMap { (1...65535).contains($0) ? $0 : nil }
        let importable = !unknown && args.first == executable.path && selected.map { args.contains($0.path) } == true && validPort != nil &&
            ["127.0.0.1", "localhost", "::1"].contains(address ?? "") &&
            (job["KeepAlive"] == nil || job["KeepAlive"] as? Bool == false) &&
            (job["RunAtLoad"] == nil || job["RunAtLoad"] as? Bool == false) &&
            (job["Label"] as? String)?.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
        dsp.append(.init(executablePath: executable.path, configurationPath: selected?.path,
                         launchAgentPath: importable ? url.standardizedFileURL.path : nil, websocketPort: selected == nil ? nil : validPort))
    }

    private func seedAppConfiguration(_ url: URL) {
        guard let data = read(url), var configuration = try? JSONDecoder().decode(Configuration.self, from: data) else { return }
        for index in configuration.profiles.indices {
            guard let job = resolve(configuration.profiles[index].launchAgentPath) else { return }
            configuration.profiles[index].launchAgentPath = job.path
            if var gui = configuration.profiles[index].gui {
                guard let binary = resolve(gui.executablePath), let config = resolve(gui.configPath) else { return }
                gui.executablePath = binary.path; gui.configPath = config.path; configuration.profiles[index].gui = gui
            }
        }
        guard (try? ConfigurationLoader.validate(configuration)) != nil else { return }
        for profile in configuration.profiles where !cancelled {
            inspectJob(URL(fileURLWithPath: profile.launchAgentPath))
            if let item = profile.gui, let binary = trustedExecutable(URL(fileURLWithPath: item.executablePath), kind: .gui),
               let candidate = guiCandidate(executable: binary, config: URL(fileURLWithPath: item.configPath)) { gui.append(candidate) }
        }
    }

    private func canonical(_ path: String) -> String {
        if let cached = canonicalPaths[path] { return cached }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        canonicalPaths[path] = resolved
        return resolved
    }
    private func normalizeDSP() -> [SetupDSPCandidate] {
        let ordered = dsp.sorted { [$0.executablePath, $0.configurationPath ?? "", $0.launchAgentPath ?? ""] .lexicographicallyPrecedes([$1.executablePath, $1.configurationPath ?? "", $1.launchAgentPath ?? ""]) }
        let configured = Set(dsp.filter { $0.configurationPath != nil }.map { canonical($0.executablePath) })
        func group(_ item: SetupDSPCandidate) -> String {
            [canonical(item.executablePath), item.configurationPath.map(canonical) ?? "", item.launchAgentPath ?? ""].joined(separator: "\u{0}")
        }
        let portKnown = Set(dsp.filter { $0.websocketPort != nil }.map(group))
        var seen = Set<String>()
        return ordered.filter { item in
            if item.configurationPath == nil, configured.contains(canonical(item.executablePath)) { return false }
            if item.websocketPort == nil, portKnown.contains(group(item)) { return false }
            let key = group(item) + "\u{0}" + (item.websocketPort.map(String.init) ?? "")
            return seen.insert(key).inserted
        }
    }
    private func normalizeGUI() -> [SetupGUICandidate] {
        let ordered = gui.sorted { [$0.executablePath, $0.configurationPath ?? "", $0.url ?? ""].lexicographicallyPrecedes([$1.executablePath, $1.configurationPath ?? "", $1.url ?? ""]) }
        let configured = Set(gui.filter { $0.configurationPath != nil }.map { canonical($0.executablePath) })
        var seen = Set<String>()
        return ordered.filter { item in
            if item.configurationPath == nil, configured.contains(canonical(item.executablePath)) { return false }
            return seen.insert([canonical(item.executablePath), item.configurationPath.map(canonical) ?? "", item.url ?? ""].joined(separator: "\u{0}")).inserted
        }
    }
}
