import Foundation
import Darwin
import AutoAudioCore

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

/// Finite asynchronous commands. Regular files avoid pipe-buffer deadlocks.
@MainActor public enum ProcessRunner {
    public static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 5,
                           workingDirectory: URL? = nil) async throws -> ProcessResult {
        let invocation = Invocation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                invocation.begin(executable, arguments: arguments, timeout: timeout,
                                 workingDirectory: workingDirectory, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in invocation.finish(error: CancellationError()) }
        }
    }

    @MainActor private final class Invocation {
        let process = Process()
        var continuation: CheckedContinuation<ProcessResult, Error>?
        var deadline: DispatchWorkItem?
        var directory: URL?
        var output: FileHandle?
        var errors: FileHandle?
        func begin(_ executable: String, arguments: [String], timeout: TimeInterval, workingDirectory: URL?,
                   continuation: CheckedContinuation<ProcessResult, Error>) {
            self.continuation = continuation
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("camillacompanion-command-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                directory = root
                for name in ["stdout", "stderr"] {
                    guard FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil) else {
                        throw SwitcherError.message("Cannot create command output file")
                    }
                }
                output = try FileHandle(forWritingTo: root.appendingPathComponent("stdout"))
                errors = try FileHandle(forWritingTo: root.appendingPathComponent("stderr"))
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output; process.standardError = errors
                process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.finish(error: nil) } }
                try process.run()
                let work = DispatchWorkItem { [weak self] in
                    self?.finish(error: SwitcherError.message("Command timed out: \(URL(fileURLWithPath: executable).lastPathComponent)"))
                }
                deadline = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, timeout), execute: work)
            } catch { finish(error: error) }
        }
        func finish(error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel(); deadline = nil
            if error != nil, process.isRunning {
                // This runner owns this short-lived command, never the DSP service.
                kill(process.processIdentifier, SIGKILL)
            }
            process.terminationHandler = nil
            try? output?.close(); try? errors?.close()
            func read(_ name: String) -> String {
                guard let directory, let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(name)) else { return "" }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 128 * 1024)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
            let stdout = read("stdout"), stderr = read("stderr")
            if let directory { try? FileManager.default.removeItem(at: directory) }
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)) }
        }
    }
}
