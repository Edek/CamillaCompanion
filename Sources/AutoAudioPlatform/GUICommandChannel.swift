import Foundation
import Darwin
import AutoAudioCore

public struct GUIRequest: Codable, Sendable {
    public let command: GUICommand
    public let profileID: String
    public init(command: GUICommand, profileID: String) { self.command = command; self.profileID = profileID }
}
public struct GUIReply: Codable, Sendable {
    public let status: GUIStatus?
    public let error: String?
    public init(status: GUIStatus? = nil, error: String? = nil) { self.status = status; self.error = error }
}

/// Narrow newline-delimited JSON channel. Private directory, same-user peers, bounded frames/deadlines.
@MainActor public final class GUICommandServer {
    nonisolated public static func socketURL(stateURL: URL) -> URL {
        let digest = stateURL.standardizedFileURL.path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return URL(fileURLWithPath: "/tmp/camillacompanion-\(getuid())-\(String(digest, radix: 16))/gui.sock")
    }
    private let url: URL
    private var source: DispatchSourceRead?
    private var clients: [UUID: Int32] = [:]
    private var deadlines: [UUID: DispatchWorkItem] = [:]
    private let handler: @MainActor (GUIRequest) async -> GUIReply
    private let controllerHandler: (@MainActor (ControllerRequest) async -> ControllerReply)?
    public init(stateURL: URL, controllerHandler: (@MainActor (ControllerRequest) async -> ControllerReply)? = nil, handler: @escaping @MainActor (GUIRequest) async -> GUIReply) {
        url = Self.socketURL(stateURL: stateURL); self.handler = handler
        self.controllerHandler = controllerHandler
    }
    public func start() throws {
        let root = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try SocketIO.validatePrivate(root.path, directory: true)
        // Caller holds the controller lock before stale socket replacement.
        if FileManager.default.fileExists(atPath: url.path) {
            try SocketIO.validatePrivate(url.path, directory: false)
            guard unlink(url.path) == 0 else { throw SwitcherError.message("Cannot replace stale command socket") }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SwitcherError.message("Cannot create GUI command socket") }
        do {
            try SocketIO.address(url.path) { guard Darwin.bind(fd, $0, $1) == 0 else { throw SwitcherError.message("Cannot bind GUI command socket") } }
            guard chmod(url.path, 0o600) == 0, listen(fd, 8) == 0 else { throw SwitcherError.message("Cannot listen on private GUI command socket") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in self?.acceptClient(fd) }
            self.source = source; source.resume()
        } catch { Darwin.close(fd); throw error }
    }
    private func acceptClient(_ server: Int32) {
        let fd = Darwin.accept(server, nil, nil)
        guard fd >= 0 else { return }
        guard clients.count < 8, SocketIO.sameUser(fd) else { Darwin.close(fd); return }
        _ = fcntl(fd, F_SETFL, 0)
        SocketIO.setTimeout(fd, seconds: 2)
        let token = UUID(); clients[token] = fd
        let deadline = DispatchWorkItem { [weak self] in
            if self?.clients[token] != nil { Darwin.shutdown(fd, SHUT_RDWR) }
        }
        deadlines[token] = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: deadline)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let request = Result { try SocketIO.readFrame(fd) }
            Task { @MainActor in
                let data: Data
                if let self, self.source != nil {
                    do {
                        let frame = try request.get()
                        if let value = try? JSONDecoder().decode(ControllerRequest.self, from: frame) {
                            guard value.scope == "controller", let handler = self.controllerHandler else {
                                throw SwitcherError.message("Unsupported controller command scope")
                            }
                            if value.command == .preset {
                                // Classification precedes the separately bounded
                                // mutation/rollback lease. Retain a finite IPC
                                // window long enough to deliver either result.
                                self.deadlines[token]?.cancel()
                                let presetDeadline = DispatchWorkItem { [weak self] in
                                    if self?.clients[token] != nil { Darwin.shutdown(fd, SHUT_RDWR) }
                                }
                                self.deadlines[token] = presetDeadline
                                DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: presetDeadline)
                            }
                            data = try JSONEncoder().encode(await handler(value))
                        } else {
                            let value = try JSONDecoder().decode(GUIRequest.self, from: frame)
                            data = try JSONEncoder().encode(await self.handler(value))
                        }
                    } catch {
                        data = (try? JSONEncoder().encode(GUIReply(error: "Invalid command request: \(error.localizedDescription)"))) ?? Data()
                    }
                } else { data = (try? JSONEncoder().encode(GUIReply(error: "Controller shutting down"))) ?? Data() }
                let owner = self
                DispatchQueue.global(qos: .utility).async {
                    try? SocketIO.writeFrame(data, fd: fd)
                    Task { @MainActor in
                        owner?.clients.removeValue(forKey: token); owner?.deadlines.removeValue(forKey: token)?.cancel(); Darwin.close(fd)
                    }
                }
            }
        }
    }
    public func stop() {
        source?.cancel(); source = nil
        for fd in clients.values { Darwin.shutdown(fd, SHUT_RDWR) }
        unlink(url.path)
    }
}

public enum ControllerCommandClient {
    public static func send(_ request: ControllerRequest, stateURL: URL, timeout: Int? = nil) throws -> ControllerReply {
        try CommandSocketClient.send(request, stateURL: stateURL, timeout: timeout)
    }
}

public enum GUICommandClient {
    public static func send(_ request: GUIRequest, stateURL: URL) throws -> GUIReply {
        try CommandSocketClient.send(request, stateURL: stateURL)
    }
}

private enum CommandSocketClient {
    static func send<Request: Encodable, Reply: Decodable>(_ request: Request, stateURL: URL, timeout: Int? = nil) throws -> Reply {
        let url = GUICommandServer.socketURL(stateURL: stateURL)
        do {
            try SocketIO.validatePrivate(url.deletingLastPathComponent().path, directory: true)
            try SocketIO.validatePrivate(url.path, directory: false)
        } catch { throw SwitcherError.message("Controller unavailable. Start camillacompanion run with this --state path or load its login LaunchAgent. \(error.localizedDescription)") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SwitcherError.message("Cannot create GUI command client") }
        defer { Darwin.close(fd) }
        let timeout = max(1, timeout ?? ((request as? ControllerRequest)?.command == .preset ? 60 : 30))
        SocketIO.setTimeout(fd, seconds: timeout)
        try SocketIO.address(url.path) {
            guard Darwin.connect(fd, $0, $1) == 0 else { throw SwitcherError.message("Controller unavailable. Start camillacompanion run or load its login LaunchAgent; check --state path.") }
        }
        guard SocketIO.sameUser(fd) else { throw SwitcherError.message("Refusing command socket owned by another user") }
        try SocketIO.writeFrame(try JSONEncoder().encode(request), fd: fd)
        return try JSONDecoder().decode(Reply.self, from: SocketIO.readFrame(fd, timeout: TimeInterval(timeout), maximumBytes: 524288))
    }
}

private enum SocketIO {
    static func address<T>(_ path: String, operation: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SwitcherError.message("Command socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    static func validatePrivate(_ path: String, directory: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFSOCK) else {
            throw SwitcherError.message("Missing or unsafe private command \(directory ? "directory" : "socket")")
        }
    }
    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
    static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var value: Int32 = 1
        withUnsafePointer(to: &value) { _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
    }
    static func readFrame(_ fd: Int32, timeout: TimeInterval = 2, maximumBytes: Int = 8192) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count <= maximumBytes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SwitcherError.message("Command frame deadline exceeded") }
            setTimeout(fd, seconds: max(1, Int(ceil(remaining))))
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw SwitcherError.message("Command channel closed or timed out") }
            data.append(contentsOf: buffer.prefix(count))
            if let end = data.firstIndex(of: 10) {
                guard end == data.count - 1, end <= maximumBytes else { throw SwitcherError.message("Expected one bounded JSON frame") }
                return data.prefix(upTo: end)
            }
        }
        throw SwitcherError.message("Command frame exceeds \(maximumBytes) bytes")
    }
    static func writeFrame(_ data: Data, fd: Int32) throws {
        var bytes = data; bytes.append(10)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw SwitcherError.message("Command channel write failed or timed out") }
                offset += count
            }
        }
    }
}
