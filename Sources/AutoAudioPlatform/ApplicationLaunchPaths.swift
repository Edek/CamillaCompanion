// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import AutoAudioCore

public struct ApplicationLaunchPaths: Equatable {
    public let configurationURL: URL
    public let runtimeStateURL: URL
    public let adoptedLaunchAgentURL: URL?
    public let sessionArguments: [String]
}

/// Reads per-user LaunchAgents and inspects the app's launchd label once.
/// A reserved label alone never authorizes an arbitrary executable or wrapper.
@MainActor public struct ApplicationLaunchPathResolver {
    public typealias ListFiles = (URL) throws -> [URL]
    public typealias ReadFile = (URL) throws -> Data?
    public typealias InspectLoadedJob = (String) async throws -> ProcessResult
    private let homeDirectory: URL
    private let executableOrigins: Set<String>
    private let listFiles: ListFiles
    private let readFile: ReadFile
    private let inspectLoadedJob: InspectLoadedJob
    private static let labels: Set<String> = ["org.camillacompanion.login"]

    public init(homeDirectory: URL, bundleURL: URL? = nil, bundleExecutableURL: URL? = nil,
                listFiles: ListFiles? = nil, readFile: ReadFile? = nil,
                inspectLoadedJob: InspectLoadedJob? = nil) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        var origins = Set<String>()
        // Only the actual running bundle's declared executable is a trusted
        // origin. A development executable or a similarly named wrapper is not.
        if let bundleURL, let bundleExecutableURL, bundleURL.isFileURL, bundleExecutableURL.isFileURL,
           bundleURL.pathExtension.lowercased() == "app",
           bundleExecutableURL.standardizedFileURL == bundleURL.appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(bundleExecutableURL.lastPathComponent).standardizedFileURL {
            origins.insert(bundleExecutableURL.standardizedFileURL.path)
        }
        executableOrigins = origins
        self.listFiles = listFiles ?? Self.systemListFiles
        self.readFile = readFile ?? Self.systemReadFile
        self.inspectLoadedJob = inspectLoadedJob ?? { label in
            try await ProcessRunner.run("/bin/launchctl", arguments: ["print", "gui/\(getuid())/" + label], timeout: 3)
        }
    }

    /// Explicit launch paths and Setup retain their CLI validation without any
    /// discovery. A nil result means implicit entry requires resolve().
    public func resolveExplicitPaths(arguments: [String], setupOnly: Bool) throws -> ApplicationLaunchPaths? {
        guard setupOnly || !arguments.isEmpty else { return nil }
        return try parseArguments(arguments)
    }

    private func parseArguments(_ arguments: [String]) throws -> ApplicationLaunchPaths {
        var configurationURL: URL?
        var runtimeStateURL: URL?
        var iterator = arguments.makeIterator()
        var seen = Set<String>()
        while let flag = iterator.next() {
            guard seen.insert(flag).inserted, let value = iterator.next(), !value.isEmpty else {
                throw SwitcherError.message("Missing value or repeated option: " + flag)
            }
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            switch flag {
            case "--config": configurationURL = url
            case "--state": runtimeStateURL = url
            default: throw SwitcherError.message("Unknown setup option: " + flag)
            }
        }
        if let configurationURL, let runtimeStateURL {
            return ApplicationLaunchPaths(configurationURL: configurationURL, runtimeStateURL: runtimeStateURL,
                                          adoptedLaunchAgentURL: nil, sessionArguments: [])
        }
        let defaults = ApplicationSupportPaths.select(homeDirectory: homeDirectory)
        return ApplicationLaunchPaths(configurationURL: configurationURL ?? defaults.configurationURL,
            runtimeStateURL: runtimeStateURL ?? defaults.runtimeStateURL, adoptedLaunchAgentURL: nil, sessionArguments: [])
    }

    /// One finite read-only inspection of saved and loaded known jobs. A loaded
    /// job cannot authorize paths that differ from its saved launch arguments.
    public func resolve(arguments: [String] = [], setupOnly: Bool = false) async throws -> ApplicationLaunchPaths {
        if let explicit = try resolveExplicitPaths(arguments: arguments, setupOnly: setupOnly) { return explicit }
        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents")
        var matches: [KnownJob] = []
        let files: [URL]
        do { files = try listFiles(launchAgents).filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path } }
        catch {
            throw SwitcherError.message("Cannot inspect app login configurations in \(launchAgents.path): \(error.localizedDescription)")
        }
        for url in files {
            let reservedFilename = Self.labels.contains(url.deletingPathExtension().lastPathComponent)
            let plist: [String: Any]
            do {
                guard let data = try readFile(url) else {
                    if reservedFilename { throw SwitcherError.message("The file disappeared while it was being inspected") }
                    continue
                }
                guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw SwitcherError.message("Expected a property-list dictionary")
                }
                plist = dictionary
            } catch {
                if reservedFilename { throw invalidJob(url, reason: error.localizedDescription) }
                continue
            }
            let label = plist["Label"] as? String ?? ""
            guard reservedFilename || Self.labels.contains(label) else { continue }
            guard Self.labels.contains(label), url.lastPathComponent == label + ".plist" else {
                throw invalidJob(url, reason: "The reserved app label and filename do not match")
            }
            matches.append(KnownJob(label: label, url: url, arguments: plist["ProgramArguments"] as? [String] ?? [],
                                    paths: try paths(in: plist, url: url)))
        }
        guard matches.count <= 1 else {
            throw SwitcherError.message("Multiple app login configurations exist. Keep one matching app job, or launch with explicit --config and --state paths.")
        }
        let job = matches.first
        for label in Self.labels.sorted() {
            let loaded: ProcessResult
            do { loaded = try await inspectLoadedJob(label) }
            catch {
                throw SwitcherError.message("Cannot inspect loaded app login configuration \(label): \(error.localizedDescription)")
            }
            if loaded.status == 0 {
                guard let job, job.label == label, loadedMatches(loaded.stdout, job: job) else {
                    throw SwitcherError.message("Loaded app login configuration \(label) does not match one saved app job. Review its executable and paths before opening the app, or launch with explicit --config and --state paths.")
                }
            } else if !LaunchdDSPManager.serviceIsMissing(loaded) {
                throw SwitcherError.message("Cannot inspect loaded app login configuration \(label): " + loaded.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let job { return job.paths }
        return try parseArguments([])
    }

    private struct KnownJob {
        let label: String
        let url: URL
        let arguments: [String]
        let paths: ApplicationLaunchPaths
    }

    private func loadedMatches(_ output: String, job: KnownJob) -> Bool {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.filter({ $0.hasPrefix("path = ") }) == ["path = " + job.url.path],
              lines.filter({ $0.hasPrefix("program = ") }) == ["program = " + job.arguments[0]],
              lines.filter({ $0 == "arguments = {" }).count == 1,
              let start = lines.firstIndex(of: "arguments = {"),
              let end = lines[(start + 1)...].firstIndex(of: "}") else { return false }
        return Array(lines[(start + 1)..<end]) == job.arguments
    }

    private func paths(in plist: [String: Any], url: URL) throws -> ApplicationLaunchPaths {
        guard plist["Program"] == nil, plist["BundleProgram"] == nil,
              plist["RunAtLoad"] as? Bool == true, plist["ProcessType"] as? String == "Interactive",
              let arguments = plist["ProgramArguments"] as? [String], arguments.count >= 8,
              absolute(arguments[0]), executableOrigins.contains(URL(fileURLWithPath: arguments[0]).standardizedFileURL.path),
              arguments[1] == "run" else {
            throw invalidJob(url, reason: "Expected the installed app executable with a direct run command and Interactive startup")
        }
        var values: [String: String] = [:]
        var argumentsIterator = arguments.dropFirst(2).makeIterator()
        while let flag = argumentsIterator.next() {
            guard ["--config", "--state", "--menu-bar", "--profile", "--mode"].contains(flag),
                  values[flag] == nil, let value = argumentsIterator.next(), !value.isEmpty else {
                throw invalidJob(url, reason: "Startup arguments contain an unknown, repeated or incomplete option")
            }
            values[flag] = value
        }
        guard let configuration = values["--config"], let state = values["--state"],
              absolute(configuration), absolute(state), values["--menu-bar"] == "true" else {
            throw invalidJob(url, reason: "Startup must specify absolute --config and --state paths and --menu-bar true")
        }
        if let mode = values["--mode"] {
            guard ["auto", "force-on", "force-off"].contains(mode), mode != "force-on" || values["--profile"] != nil else {
                throw invalidJob(url, reason: "Startup has an invalid DSP mode or a force-on mode without a profile")
            }
        }
        let sessionArguments = ["--profile", "--mode"].flatMap { flag in values[flag].map { [flag, $0] } ?? [] }
        return ApplicationLaunchPaths(configurationURL: URL(fileURLWithPath: configuration),
            runtimeStateURL: URL(fileURLWithPath: state), adoptedLaunchAgentURL: url, sessionArguments: sessionArguments)
    }

    private func absolute(_ path: String) -> Bool { path.hasPrefix("/") && !path.utf8.contains(0) }

    private func invalidJob(_ url: URL, reason: String) -> SwitcherError {
        .message("Cannot use app login configuration \(url.lastPathComponent): \(reason). Review this file, or launch with explicit --config and --state paths.")
    }

    private static func systemListFiles(_ directory: URL) throws -> [URL] {
        do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return [] }
    }

    private static func systemReadFile(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SwitcherError.message("Login configuration must be a regular file")
        }
        return try Data(contentsOf: url)
    }
}
