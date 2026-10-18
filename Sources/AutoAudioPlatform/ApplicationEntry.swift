// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import AutoAudioCore

/// Finder's normal bundle entry is distinct from the development CLI's help entry.
public enum ApplicationEntry {
    public static func usesNativeLaunch(arguments: [String], bundleURL: URL, packageType: String?) -> Bool {
        bundleURL.pathExtension.lowercased() == "app" && packageType == "APPL" &&
            (arguments.isEmpty || arguments.allSatisfy { $0.hasPrefix("-psn_") })
    }
}

/// A retained descriptor is the sole controller ownership authority, including
/// the interval before its private command socket becomes ready.
public final class ControllerInstanceLock {
    public enum AcquisitionError: LocalizedError {
        case inUse
        public var errorDescription: String? { "Another controller is using this state file." }
    }
    private var descriptor: Int32

    public init(stateURL: URL) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = stateURL.path + ".lock"
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SwitcherError.message("Cannot open controller lock: \(path)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(descriptor); descriptor = -1
            if failure == EWOULDBLOCK { throw AcquisitionError.inUse }
            throw SwitcherError.message("Cannot acquire controller lock: \(path)")
        }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

public enum ApplicationLaunchHandoff {
    /// A finite startup handoff, never an idle watcher. The caller's short IPC
    /// timeout bounds each request even if an existing controller is unresponsive.
    public static func showExisting(
        attempts: Int = 4,
        show: () async -> Bool,
        pause: () async -> Void = { try? await Task.sleep(nanoseconds: 750_000_000) }
    ) async -> Bool {
        for attempt in 0..<max(0, attempts) {
            if await show() { return true }
            if attempt + 1 < attempts { await pause() }
        }
        return false
    }
}
